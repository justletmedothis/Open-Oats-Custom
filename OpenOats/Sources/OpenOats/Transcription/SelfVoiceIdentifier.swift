import FluidAudio
import Foundation

/// Matches diarized microphone voices against the user's enrolled voiceprint so
/// their own speech can be labeled .you instead of a lettered in-person speaker.
enum SelfVoiceIdentifier {
    /// Cosine-distance ceiling for accepting a diarized voice as the enrolled
    /// user. WeSpeaker distances for the same voice on the same mic typically
    /// land well below this; unrelated voices land near or above 0.8.
    static let maxMatchDistance: Float = 0.65
    /// The best candidate must beat the runner-up by this margin, so two in-room
    /// voices that both hover near the threshold never get a coin-flip match.
    static let minRunnerUpGap: Float = 0.05
    /// Ceiling for accepting a lone diarized mic voice as the enrolled user when
    /// there is no runner-up to compare against. Stricter than maxMatchDistance
    /// (same reason LiveSelfVoiceMatcher is): with a single candidate the
    /// runner-up-margin safeguard is unavailable, so a guest talking alone near
    /// the Mac must clear a tighter bar before being labeled "You".
    static let loneVoiceMatchDistance: Float = 0.55
    /// The embedding model reads at most 10 s of audio per inference.
    static let maxClipSeconds: Double = 10.0
    /// Speakers with less diarized audio than this are not scored.
    static let minClipSeconds: Double = 3.0

    private static let sampleRate = 16_000.0

    enum EnrollmentError: LocalizedError {
        case notEnoughSpeech

        var errorDescription: String? {
            switch self {
            case .notEnoughSpeech:
                "The recording did not contain enough clear speech. Try again closer to the microphone."
            }
        }
    }

    /// Cosine distance between two speaker embeddings (FluidAudio's metric).
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        SpeakerUtilities.cosineDistance(a, b)
    }

    /// Extract an L2-normalized speaker embedding from a 16 kHz mono clip, for
    /// enrolling the user's voice profile. Downloads the segmentation and
    /// embedding models on first use.
    static func extractEmbedding(from samples: [Float]) async throws -> [Float] {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        defer { manager.cleanup() }

        let clip = Array(samples.prefix(Int(maxClipSeconds * sampleRate)))
        guard manager.validateAudio(clip).isValid else {
            throw EnrollmentError.notEnoughSpeech
        }
        let embedding = try manager.extractSpeakerEmbedding(from: clip)
        guard manager.validateEmbedding(embedding) else {
            throw EnrollmentError.notEnoughSpeech
        }
        return embedding
    }

    /// Returns the diarizer speaker index whose voice matches the enrolled
    /// voiceprint, or nil when no speaker is a confident match.
    static func matchSelf(
        samples: [Float],
        speakerSegments: [Int: [DiarizationManager.SpeakerSegment]],
        voiceprint: [Float]
    ) async throws -> Int? {
        guard speakerSegments.count >= 2 else { return nil }

        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        defer { manager.cleanup() }

        var scored: [(index: Int, distance: Float)] = []
        for (index, segments) in speakerSegments.sorted(by: { $0.key < $1.key }) {
            let clip = clip(from: samples, segments: segments)
            guard Double(clip.count) / sampleRate >= minClipSeconds else {
                Log.diarization.info("Self-voice match: speaker \(index, privacy: .public) has too little audio, skipping")
                continue
            }
            let embedding = try manager.extractSpeakerEmbedding(from: clip)
            let distance = SpeakerUtilities.cosineDistance(embedding, voiceprint)
            guard distance.isFinite else { continue }
            scored.append((index: index, distance: distance))
            Log.diarization.info("Self-voice match: speaker \(index, privacy: .public) distance \(distance, privacy: .public)")
        }

        guard let best = scored.min(by: { $0.distance < $1.distance }),
              best.distance <= maxMatchDistance
        else { return nil }

        let runnerUp = scored.filter { $0.index != best.index }.map(\.distance).min() ?? .infinity
        guard runnerUp - best.distance >= minRunnerUpGap else {
            Log.diarization.info("Self-voice match: runner-up too close (\(runnerUp - best.distance, privacy: .public)), not matching")
            return nil
        }
        return best.index
    }

    /// Verify whether the single diarized mic voice (the "lone voice = you"
    /// collapse) is actually the enrolled user. There is no runner-up to compare
    /// against, so it accepts only at loneVoiceMatchDistance. Returns true when
    /// the voice confidently matches the voiceprint OR there is too little clean
    /// speech to judge (falling back to the historical "lone mic voice is the
    /// user" assumption rather than mislabeling); false means it is a guest who
    /// should be lettered instead of labeled "You".
    static func loneVoiceIsSelf(
        samples: [Float],
        segments: [DiarizationManager.SpeakerSegment],
        voiceprint: [Float]
    ) async -> Bool {
        let clip = clip(from: samples, segments: segments)
        guard Double(clip.count) / sampleRate >= minClipSeconds else { return true }
        guard let models = try? await DiarizerModels.downloadIfNeeded() else { return true }
        let manager = DiarizerManager()
        manager.initialize(models: models)
        defer { manager.cleanup() }

        guard let embedding = try? manager.extractSpeakerEmbedding(from: clip),
              manager.validateEmbedding(embedding) else { return true }
        let distance = SpeakerUtilities.cosineDistance(embedding, voiceprint)
        Log.diarization.info("Lone mic voice self-check: distance \(distance, privacy: .public)")
        guard distance.isFinite else { return true }
        return distance <= loneVoiceMatchDistance
    }

    /// Extract one embedding per diarized speaker with enough audio, keyed by
    /// diarizer index. Feeds the persistent speaker library (auto-naming and
    /// "Remember this voice" enrollment). Best-effort: speakers whose audio
    /// fails validation are simply omitted.
    static func speakerEmbeddings(
        samples: [Float],
        speakerSegments: [Int: [DiarizationManager.SpeakerSegment]],
        excluding excludedIndex: Int? = nil
    ) async -> [Int: [Float]] {
        guard !speakerSegments.isEmpty else { return [:] }
        guard let models = try? await DiarizerModels.downloadIfNeeded() else { return [:] }
        let manager = DiarizerManager()
        manager.initialize(models: models)
        defer { manager.cleanup() }

        var result: [Int: [Float]] = [:]
        for (index, segments) in speakerSegments where index != excludedIndex {
            let clip = clip(from: samples, segments: segments)
            guard Double(clip.count) / sampleRate >= minClipSeconds else { continue }
            guard let embedding = try? manager.extractSpeakerEmbedding(from: clip),
                  manager.validateEmbedding(embedding) else { continue }
            result[index] = embedding
        }
        return result
    }

    /// Concatenate a speaker's longest diarized segments into a single clip,
    /// capped at what the embedding model can read in one pass.
    private static func clip(
        from samples: [Float],
        segments: [DiarizationManager.SpeakerSegment]
    ) -> [Float] {
        let maxSamples = Int(maxClipSeconds * sampleRate)
        var clip: [Float] = []
        clip.reserveCapacity(maxSamples)
        for segment in segments.sorted(by: { ($0.end - $0.start) > ($1.end - $1.start) }) {
            guard clip.count < maxSamples else { break }
            let lower = max(0, Int(Double(segment.start) * sampleRate))
            let upper = min(samples.count, Int(Double(segment.end) * sampleRate))
            guard upper > lower else { continue }
            let take = min(upper, lower + (maxSamples - clip.count))
            clip.append(contentsOf: samples[lower..<take])
        }
        return clip
    }
}
