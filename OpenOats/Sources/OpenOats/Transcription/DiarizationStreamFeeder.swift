@preconcurrency import AVFoundation
import Foundation

/// Resamples capture buffers to the 16 kHz mono Float32 that LS-EEND expects
/// and feeds a DiarizationManager in ~1 s batches. One instance per channel
/// tee. Previously the system tee fed raw native-rate audio (44.1/48 kHz)
/// straight into the diarizer, compressing its timeline ~3x and degrading
/// live speaker attribution.
///
/// `onSamples` receives the same 16 kHz stream (used to keep a rolling buffer
/// aligned with the diarizer timeline for live voiceprint matching).
final class DiarizationStreamFeeder: @unchecked Sendable {
    private let dm: DiarizationManager
    private let channelName: String
    private let onSamples: (@Sendable ([Float]) async -> Void)?

    private var converter: AVAudioConverter?
    private var pending: [Float] = []
    private var relay = DiarizationFeedRelay()

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!
    private static let flushSize = 16_000

    init(
        dm: DiarizationManager,
        channelName: String,
        onSamples: (@Sendable ([Float]) async -> Void)? = nil
    ) {
        self.dm = dm
        self.channelName = channelName
        self.onSamples = onSamples
    }

    func ingest(_ buffer: AVAudioPCMBuffer) async {
        guard let samples = resampled(buffer), !samples.isEmpty else { return }
        await onSamples?(samples)
        pending.append(contentsOf: samples)
        while pending.count >= Self.flushSize {
            let batch = Array(pending.prefix(Self.flushSize))
            pending.removeFirst(Self.flushSize)
            await feed(batch)
        }
    }

    func flush() async {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        await feed(batch)
    }

    private func feed(_ batch: [Float]) async {
        let dm = self.dm
        let name = self.channelName
        await relay.feedAudio(
            batch,
            into: { samples in try await dm.feedAudio(samples) },
            onFailure: { error in
                Log.transcription.error("[\(name, privacy: .public)] diarization feed failed: \(error, privacy: .public)")
            }
        )
    }

    /// Mono-downmix + resample to 16 kHz. Mirrors StreamingTranscriber's
    /// extractSamples without the effective-rate correction (diarization
    /// tolerates small rate drift; the batch pass is the accuracy anchor).
    private func resampled(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        if sourceFormat.commonFormat == .pcmFormatFloat32,
           sourceFormat.sampleRate == 16000,
           sourceFormat.channelCount == 1,
           let channelData = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        var inputBuffer = buffer
        if sourceFormat.channelCount > 1, let src = buffer.floatChannelData {
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!
            guard let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
                  let dst = monoBuf.floatChannelData?[0] else { return nil }
            monoBuf.frameLength = buffer.frameLength
            let channels = Int(sourceFormat.channelCount)
            let scale = 1.0 / Float(channels)
            for i in 0..<frameLength {
                var sum: Float = 0
                for ch in 0..<channels { sum += src[ch][i] }
                dst[i] = sum * scale
            }
            inputBuffer = monoBuf
        }

        let inputFormat = inputBuffer.format
        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        guard outputFrames > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else {
            return nil
        }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if error != nil { return nil }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
