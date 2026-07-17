@preconcurrency import AVFoundation
import Foundation
import Speech

/// A live transcription loop that consumes a capture channel's buffer stream.
/// StreamingTranscriber (VAD + segment ASR) and AppleSpeechLiveTranscriber
/// (native streaming) are the two implementations.
protocol LiveTranscribing: Sendable {
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async
}

extension StreamingTranscriber: LiveTranscribing {}

/// Native streaming transcription via macOS 26's SpeechAnalyzer.
///
/// Unlike StreamingTranscriber there is no VAD gating or flush interval: the
/// system model consumes the raw buffer stream and emits volatile hypotheses
/// (→ onPartial, typically well under a second behind the audio) that are
/// replaced by finalized results (→ onFinal). The model runs in a system
/// process, so it adds almost nothing to the app's memory footprint.
@available(macOS 26.0, *)
final class AppleSpeechLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    private let locale: Locale
    private let speakerKey: String
    private let vocabulary: VocabularyRewriter
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (StreamingTranscriber.FinalSegment) -> Void
    private let onError: (@Sendable (String) -> Void)?

    private var converter: AVAudioConverter?
    private var loggedConverterFailure = false

    init(
        locale: Locale,
        speakerKey: String,
        customVocabulary: String,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (StreamingTranscriber.FinalSegment) -> Void,
        onError: (@Sendable (String) -> Void)? = nil
    ) {
        self.locale = locale
        self.speakerKey = speakerKey
        self.vocabulary = VocabularyRewriter(customVocabulary)
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
    }

    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        do {
            try await runAnalyzer(stream: stream)
        } catch is CancellationError {
            // Session stopped.
        } catch {
            Log.transcription.error("[\(self.speakerKey, privacy: .public)] Apple Speech live transcription failed: \(error, privacy: .public)")
            onError?("Apple Speech live transcription failed: \(error.localizedDescription)")
            // The capture tees keep pumping this stream for the rest of the
            // session; leaving it unconsumed would buffer raw audio without
            // bound. Drain and discard until the session ends.
            for await _ in stream {
                if Task.isCancelled { break }
            }
        }
    }

    private func runAnalyzer(stream: AsyncStream<AVAudioPCMBuffer>) async throws {
        let resolvedLocale = try await AppleSpeechAssets.resolveSupportedLocale(for: locale)
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        // Normally a no-op: prepare() already installed the language model.
        // Kept as a guard for locale changes between prepare and start.
        try await AppleSpeechAssets.ensureAssets(for: transcriber)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Bounded: if the analyzer falls behind realtime, drop the oldest
        // backlog instead of buffering audio without limit (the batch pass is
        // the accuracy anchor). ~600 capture buffers is roughly a minute.
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(600)
        )

        let onPartial = self.onPartial
        let onFinal = self.onFinal
        let vocabulary = self.vocabulary
        let speakerKey = self.speakerKey
        let resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let rawText = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rawText.isEmpty else { continue }
                    let text = vocabulary.rewrite(rawText)
                    if result.isFinal {
                        onPartial("")
                        onFinal(
                            StreamingTranscriber.FinalSegment(
                                text: text,
                                startTime: result.range.start.seconds.isFinite ? result.range.start.seconds : 0,
                                endTime: result.range.end.seconds.isFinite ? result.range.end.seconds : 0
                            )
                        )
                    } else {
                        onPartial(text)
                    }
                }
            } catch is CancellationError {
                // Session stopped.
            } catch {
                Log.transcription.error("[\(speakerKey, privacy: .public)] Apple Speech results stream failed: \(error, privacy: .public)")
            }
        }

        // If start() throws (or anything below does), the results task would
        // otherwise stay blocked on transcriber.results forever. On the paths
        // that already awaited or cancelled it this is a no-op.
        defer { resultsTask.cancel() }

        try await analyzer.start(inputSequence: inputSequence)

        for await buffer in stream {
            if Task.isCancelled { break }
            if let converted = convert(buffer, to: analyzerFormat) {
                inputBuilder.yield(AnalyzerInput(buffer: converted))
            }
        }

        inputBuilder.finish()
        onPartial("")
        if Task.isCancelled {
            // The session is stopping. Nothing about the analyzer's teardown can
            // be awaited safely here: finalizeAndFinishThroughEndOfInput drains
            // the whole buffered backlog through the model, and even
            // cancelAndFinishNow has been observed to wedge with the results
            // stream never terminating, which hung Stop until the watchdog and
            // left the engine unable to record again. The batch pass
            // re-transcribes the session anyway, so abandon the analyzer:
            // request the cancel from a detached task and return immediately.
            resultsTask.cancel()
            nonisolated(unsafe) let doomedAnalyzer = analyzer
            Task.detached { await doomedAnalyzer.cancelAndFinishNow() }
            return
        }
        // Natural stream end (device loss, restart): keep the tail.
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask.value
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        // Rebuild on format changes (mic restarts, device switches).
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            if converter == nil, !loggedConverterFailure {
                loggedConverterFailure = true
                Log.transcription.error("[\(self.speakerKey, privacy: .public)] Apple Speech: no converter from \(buffer.format, privacy: .public) to analyzer format; channel audio is being dropped")
            }
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        nonisolated(unsafe) var consumed = false
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if error != nil {
            Log.transcription.error("[\(self.speakerKey, privacy: .public)] Apple Speech buffer conversion failed")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}
