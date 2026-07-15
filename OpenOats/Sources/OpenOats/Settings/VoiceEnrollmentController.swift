import AVFoundation
import Foundation
import Observation

/// Records a short microphone sample, extracts a speaker embedding from it, and
/// persists it as the user's voice profile for self-voice identification.
@MainActor
@Observable
final class VoiceEnrollmentController {
    enum Phase: Equatable {
        case idle
        case recording(secondsRemaining: Int)
        case processing
        case failed(String)
    }

    static let recordingSeconds = 10
    private static let targetRate = 16_000.0

    private(set) var phase: Phase = .idle
    private(set) var profile: VoiceprintProfile?

    private var recordTask: Task<Void, Never>?

    init() {
        profile = VoiceprintStore.load()
    }

    func startRecording(inputDeviceID: AudioDeviceID?) {
        guard recordTask == nil else { return }
        phase = .recording(secondsRemaining: Self.recordingSeconds)
        recordTask = Task { [weak self] in
            await self?.record(inputDeviceID: inputDeviceID)
            self?.recordTask = nil
        }
    }

    func cancelRecording() {
        recordTask?.cancel()
    }

    func deleteProfile() {
        VoiceprintStore.delete()
        profile = nil
        phase = .idle
    }

    private func record(inputDeviceID: AudioDeviceID?) async {
        let capture = MicCapture()
        let stream = capture.bufferStream(deviceID: inputDeviceID)
        let targetSamples = Int(Double(Self.recordingSeconds) * Self.targetRate)
        var samples: [Float] = []
        samples.reserveCapacity(targetSamples)

        // If the device disappears mid-capture and the engine restart fails,
        // MicCapture records the error but buffers just stop arriving, which
        // would leave the loop below awaiting forever. Force the stream shut
        // after a hard deadline so every capture ends in a user-visible state.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(Self.recordingSeconds + 5))
            guard !Task.isCancelled else { return }
            capture.stop()
        }

        for await buffer in stream {
            if Task.isCancelled { break }
            if capture.captureError != nil { break }
            samples.append(contentsOf: BatchAudioSampleReader.resample(buffer, targetRate: Self.targetRate))
            let remaining = max(0, Self.recordingSeconds - samples.count / Int(Self.targetRate))
            phase = .recording(secondsRemaining: remaining)
            if samples.count >= targetSamples { break }
        }
        watchdog.cancel()
        capture.stop()

        if Task.isCancelled {
            phase = .idle
            return
        }
        if let error = capture.captureError {
            phase = .failed(error)
            return
        }
        guard samples.count >= Int(SelfVoiceIdentifier.minClipSeconds * Self.targetRate) else {
            phase = .failed("Not enough audio was captured. Check the microphone and try again.")
            return
        }

        phase = .processing
        do {
            let clip = samples
            let embedding = try await Task.detached(priority: .userInitiated) {
                try await SelfVoiceIdentifier.extractEmbedding(from: clip)
            }.value
            // The detached task doesn't inherit cancellation; if the user
            // cancelled while the embedding was computing, don't overwrite
            // the stored profile behind their back.
            guard !Task.isCancelled else {
                phase = .idle
                return
            }
            let newProfile = VoiceprintProfile(
                embedding: embedding,
                createdAt: Date(),
                sampleDuration: Double(samples.count) / Self.targetRate
            )
            try VoiceprintStore.save(newProfile)
            profile = newProfile
            phase = .idle
        } catch {
            phase = .failed("Could not create the voice profile: \(error.localizedDescription)")
        }
    }
}
