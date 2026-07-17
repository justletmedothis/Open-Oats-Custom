@preconcurrency import AVFoundation
import Foundation
import Speech

enum AppleSpeechError: LocalizedError {
    case osTooOld
    case unsupportedLocale(String)
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .osTooOld:
            "Apple Speech requires macOS 26 or later."
        case .unsupportedLocale(let identifier):
            "Apple Speech doesn't support \(identifier). Pick a supported language in Settings, or switch transcription model."
        case .noAudioFormat:
            "Apple Speech couldn't provide a compatible audio format."
        }
    }
}

/// Shared helpers for Apple's SpeechAnalyzer stack: locale resolution and
/// system asset (language model) installation.
@available(macOS 26.0, *)
enum AppleSpeechAssets {
    /// Maps the user's locale onto one SpeechTranscriber actually supports —
    /// exact BCP-47 match first, then same-language fallback (en-AU → en-US).
    static func resolveSupportedLocale(for locale: Locale) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let target = locale.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == target }) {
            return exact
        }
        if let language = locale.language.languageCode?.identifier,
           let sameLanguage = supported.first(where: { $0.language.languageCode?.identifier == language }) {
            return sameLanguage
        }
        throw AppleSpeechError.unsupportedLocale(locale.identifier)
    }

    /// Downloads and installs the system language model if missing.
    /// The model lives in system storage and is shared across apps.
    static func ensureAssets(
        for transcriber: SpeechTranscriber,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        let progress = request.progress
        let poller: Task<Void, Never>? = onProgress.map { report in
            Task {
                while !Task.isCancelled {
                    report(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        defer { poller?.cancel() }
        try await request.downloadAndInstall()
    }
}

/// TranscriptionBackend adapter for Apple's SpeechAnalyzer (macOS 26+).
///
/// The live path bypasses this and uses AppleSpeechLiveTranscriber (native
/// streaming with volatile results). This backend exists for the shared
/// lifecycle — asset download with progress during prepare() — and one-shot
/// segment transcription for any VAD/segment-based caller.
final class AppleSpeechBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Apple Speech"
    private let localeIdentifier: String
    private let vocabulary: VocabularyRewriter

    init(localeIdentifier: String, customVocabulary: String = "") {
        self.localeIdentifier = localeIdentifier
        self.vocabulary = VocabularyRewriter(customVocabulary)
    }

    func checkStatus() -> BackendStatus {
        if #available(macOS 26.0, *) {
            // Language assets are system-managed and ensured during prepare();
            // there is nothing app-local to download ahead of time.
            return .ready
        }
        return .error(reason: AppleSpeechError.osTooOld.localizedDescription)
    }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26.0, *) else { throw AppleSpeechError.osTooOld }
        onStatus("Checking Apple Speech language model...")
        let locale = try await AppleSpeechAssets.resolveSupportedLocale(for: Locale(identifier: localeIdentifier))
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        onStatus("Downloading Apple Speech language model...")
        try await AppleSpeechAssets.ensureAssets(for: transcriber, onProgress: onProgress)
    }

    func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
        guard #available(macOS 26.0, *) else { throw AppleSpeechError.osTooOld }
        guard !samples.isEmpty else { return "" }

        let resolved = try await AppleSpeechAssets.resolveSupportedLocale(for: locale)
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechError.noAudioFormat
        }
        guard let sourceBuffer = Self.makeBuffer(from: samples),
              let converted = Self.convert(sourceBuffer, to: analyzerFormat) else {
            return ""
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        let resultsTask = Task<String, Error> {
            var collected = ""
            for try await result in transcriber.results where result.isFinal {
                collected += String(result.text.characters)
            }
            return collected
        }

        try await analyzer.start(inputSequence: inputSequence)
        inputBuilder.yield(AnalyzerInput(buffer: converted))
        inputBuilder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = try await resultsTask.value
        return vocabulary.rewrite(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channelData[0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
        if error != nil { return nil }
        return output
    }
}
