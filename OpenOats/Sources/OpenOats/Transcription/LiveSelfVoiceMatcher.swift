import Foundation

/// Live counterpart of the batch self-voice relabeling: accumulates per-speaker
/// mic audio as diarized utterances finalize, and once a lettered speaker has
/// enough speech, scores their voice against the enrolled voiceprint so the
/// user's own bubbles say "You" during the meeting instead of "Speaker A".
///
/// Live matching sees one candidate at a time (no runner-up margin like the
/// batch pass), so it accepts at a stricter distance and gives borderline
/// voices a second scoring once more audio arrives.
actor LiveSelfVoiceMatcher {
    /// Stricter than SelfVoiceIdentifier.maxMatchDistance (0.65) because the
    /// batch runner-up-margin safeguard is unavailable live.
    static let liveMatchDistance: Float = 0.55
    /// Seconds of accumulated speech before the first scoring attempt.
    static let firstScoreSeconds: Double = 3.0
    /// Borderline voices (between liveMatchDistance and the batch ceiling) are
    /// rescored once they reach this much audio, then decided for good.
    static let rescoreSeconds: Double = 8.0

    private static let sampleRate = 16_000.0
    /// Rolling mic audio kept for slicing utterance ranges (~11.5 MB at 180 s).
    private static let rollingCapacitySeconds = 180.0

    private let voiceprint: [Float]

    private var rollingSamples: [Float] = []
    /// Absolute sample index (diarizer/ASR timeline) of rollingSamples[0].
    private var rollingStart = 0

    private var clips: [Int: [Float]] = [:]
    private var scoredOnce: Set<Int> = []
    private var decided: Set<Int> = []
    private var selfIndices: Set<Int> = []
    /// Clip length a speaker must reach before the next scoring attempt, set
    /// when an attempt finds too little clean speech in the clip.
    private var minNextScoreSeconds: [Int: Double] = [:]

    init(voiceprint: [Float]) {
        self.voiceprint = voiceprint
    }

    /// Feed the same 16 kHz mono stream the diarizer receives.
    func appendAudio(_ samples: [Float]) {
        rollingSamples.append(contentsOf: samples)
        let capacity = Int(Self.rollingCapacitySeconds * Self.sampleRate)
        if rollingSamples.count > capacity {
            let drop = rollingSamples.count - capacity
            rollingSamples.removeFirst(drop)
            rollingStart += drop
        }
    }

    /// Whether a diarizer-lettered local speaker has been identified as the user.
    func isSelf(localSpeakerNumber: Int) -> Bool {
        selfIndices.contains(localSpeakerNumber)
    }

    /// Record a finalized utterance attributed to .local(n) and score the
    /// speaker's voice once enough audio has accumulated. Returns true when
    /// this call identified the speaker as the user (caller may relabel).
    func noteUtterance(localSpeakerNumber n: Int, startTime: TimeInterval, endTime: TimeInterval) async -> Bool {
        guard !decided.contains(n) else { return false }

        appendClip(for: n, startTime: startTime, endTime: endTime)
        let clipSeconds = Double(clips[n]?.count ?? 0) / Self.sampleRate

        let readyForFirstScore = clipSeconds >= Self.firstScoreSeconds && !scoredOnce.contains(n)
        let readyForRescore = clipSeconds >= Self.rescoreSeconds && scoredOnce.contains(n)
        guard readyForFirstScore || readyForRescore,
              clipSeconds >= minNextScoreSeconds[n] ?? 0,
              let clip = clips[n] else { return false }

        do {
            let embedding = try await SelfVoiceIdentifier.extractEmbedding(from: clip)
            let distance = SelfVoiceIdentifier.distance(embedding, voiceprint)
            Log.diarization.info("Live self-voice: speaker \(n, privacy: .public) distance \(distance, privacy: .public) at \(clipSeconds, privacy: .public)s")

            if distance <= Self.liveMatchDistance {
                decided.insert(n)
                selfIndices.insert(n)
                clips[n] = nil
                return true
            }
            if distance > SelfVoiceIdentifier.maxMatchDistance || readyForRescore {
                // Clearly another voice, or borderline twice — stop scoring.
                decided.insert(n)
                clips[n] = nil
                return false
            }
            scoredOnce.insert(n)
        } catch SelfVoiceIdentifier.EnrollmentError.notEnoughSpeech {
            // Expected while a speaker's clip is mostly non-speech; wait for
            // more audio without burning the single rescore attempt.
            minNextScoreSeconds[n] = clipSeconds + 2.0
        } catch {
            Log.diarization.error("Live self-voice scoring failed: \(error, privacy: .public)")
            scoredOnce.insert(n)
        }
        return false
    }

    private func appendClip(for n: Int, startTime: TimeInterval, endTime: TimeInterval) {
        let maxSamples = Int(SelfVoiceIdentifier.maxClipSeconds * Self.sampleRate)
        let existing = clips[n]?.count ?? 0
        guard existing < maxSamples else { return }

        let lower = max(Int(startTime * Self.sampleRate), rollingStart)
        let upper = min(Int(endTime * Self.sampleRate), rollingStart + rollingSamples.count)
        guard upper > lower else { return }

        let range = (lower - rollingStart)..<(upper - rollingStart)
        let take = min(range.count, maxSamples - existing)
        clips[n, default: []].append(contentsOf: rollingSamples[range.lowerBound..<(range.lowerBound + take)])
    }
}
