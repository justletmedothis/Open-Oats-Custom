import Foundation

/// Live counterpart of the batch pass's voice identification: accumulates
/// per-speaker mic audio as diarized utterances finalize and, once a lettered
/// speaker has enough speech, scores that voice against the enrolled self
/// voiceprint and the named speaker library. The user's own bubbles say "You"
/// during the meeting, and people remembered from earlier meetings get their
/// names live instead of waiting for the batch pass.
///
/// Live matching sees one candidate voice at a time (no cross-cluster
/// runner-up margin like the batch pass), so identification uses a stricter
/// distance and borderline voices get a second scoring once more audio arrives.
actor LiveVoiceMatcher {
    /// Stricter than SelfVoiceIdentifier.maxMatchDistance (0.65) because the
    /// batch runner-up-margin safeguard is unavailable live.
    static let liveMatchDistance: Float = 0.55
    /// Seconds of accumulated speech before the first scoring attempt.
    static let firstScoreSeconds: Double = 3.0
    /// Voices not identified on the first attempt are rescored once they reach
    /// this much audio, then decided for good.
    static let rescoreSeconds: Double = 8.0
    /// Fresh speech per drift-verification window for self-decided speakers.
    /// Live LS-EEND clusters are unstable early: a cluster can be born during
    /// the user's speech (matching the voiceprint) and later absorb a guest's
    /// voice, so "self" is re-verified on every window of new audio.
    static let selfVerifySeconds: Double = 6.0

    private static let sampleRate = 16_000.0
    /// Rolling mic audio kept for slicing utterance ranges (~11.5 MB at 180 s).
    private static let rollingCapacitySeconds = 180.0

    private let voiceprint: [Float]?
    private let profiles: [SpeakerProfile]
    /// Whether a self voiceprint is enrolled. Callers use this to choose
    /// between "You is earned by matching" and the mic-defaults-to-you policy.
    nonisolated let hasVoiceprint: Bool

    private var rollingSamples: [Float] = []
    /// Absolute sample index (diarizer/ASR timeline) of rollingSamples[0].
    private var rollingStart = 0

    private var clips: [Int: [Float]] = [:]
    private var scoredOnce: Set<Int> = []
    private var decided: Set<Int> = []
    private var selfIndices: Set<Int> = []
    private var matchedNames: [Int: String] = [:]
    /// Clip length a speaker must reach before the next scoring attempt, set
    /// when an attempt finds too little clean speech in the clip.
    private var minNextScoreSeconds: [Int: Double] = [:]

    init(voiceprint: [Float]?, profiles: [SpeakerProfile]) {
        self.voiceprint = voiceprint
        self.profiles = profiles
        self.hasVoiceprint = voiceprint != nil
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

    /// Outcome of scoring a diarized voice.
    enum Verdict: Sendable, Equatable {
        /// Not enough evidence yet to say either way.
        case pending
        /// The voice matches the enrolled voiceprint.
        case isSelf
        /// The voice matches a named profile in the speaker library.
        case matchedLibrary(name: String)
        /// The voice was scored decisively: not the user, not in the library.
        case notSelf
    }

    /// Force-mark a speaker as not the user (live "Not me" correction).
    func markNotSelf(localSpeakerNumber n: Int) {
        decided.insert(n)
        selfIndices.remove(n)
        clips[n] = nil
    }

    /// Record a finalized utterance attributed to a diarized speaker and score
    /// that voice once enough audio has accumulated. `.isSelf` and
    /// `.matchedLibrary` are returned on the call that identifies the voice
    /// (callers may relabel / publish the name).
    func classifyUtterance(
        localSpeakerNumber n: Int, startTime: TimeInterval, endTime: TimeInterval
    ) async -> Verdict {
        guard !decided.contains(n) else {
            if selfIndices.contains(n) {
                return await verifySelf(n, startTime: startTime, endTime: endTime)
            }
            if let name = matchedNames[n] { return .matchedLibrary(name: name) }
            return .notSelf
        }

        appendClip(for: n, startTime: startTime, endTime: endTime)
        let clipSeconds = Double(clips[n]?.count ?? 0) / Self.sampleRate

        let readyForFirstScore = clipSeconds >= Self.firstScoreSeconds && !scoredOnce.contains(n)
        let readyForRescore = clipSeconds >= Self.rescoreSeconds && scoredOnce.contains(n)
        guard readyForFirstScore || readyForRescore,
              clipSeconds >= minNextScoreSeconds[n] ?? 0,
              let clip = clips[n] else { return .pending }

        do {
            let embedding = try await SelfVoiceIdentifier.extractEmbedding(from: clip)
            if let voiceprint {
                let distance = SelfVoiceIdentifier.distance(embedding, voiceprint)
                Log.diarization.info("Live self-voice: speaker \(n, privacy: .public) distance \(distance, privacy: .public) at \(clipSeconds, privacy: .public)s")
            }
            let verdict = Self.evaluate(
                embedding: embedding,
                voiceprint: voiceprint,
                profiles: profiles,
                isFinalAttempt: readyForRescore
            )
            switch verdict {
            case .isSelf:
                decided.insert(n)
                selfIndices.insert(n)
                clips[n] = nil
            case .matchedLibrary(let name):
                decided.insert(n)
                matchedNames[n] = name
                clips[n] = nil
                Log.diarization.info("Live voice library match for speaker \(n, privacy: .public) at \(clipSeconds, privacy: .public)s")
            case .notSelf:
                decided.insert(n)
                clips[n] = nil
            case .pending:
                scoredOnce.insert(n)
            }
            return verdict
        } catch SelfVoiceIdentifier.EnrollmentError.notEnoughSpeech {
            // Expected while a speaker's clip is mostly non-speech; wait for
            // more audio without burning the single rescore attempt.
            minNextScoreSeconds[n] = clipSeconds + 2.0
        } catch {
            Log.diarization.error("Live voice scoring failed: \(error, privacy: .public)")
            scoredOnce.insert(n)
        }
        return .pending
    }

    /// Keep verifying a speaker already decided as the user. Each window of
    /// selfVerifySeconds of fresh speech is rescored against the voiceprint;
    /// a window clearly unlike it means the live cluster has drifted to a
    /// different voice, so the speaker is demoted (and given one library
    /// lookup) rather than keeping the "You" label forever. Past bubbles are
    /// left alone — they are a mix the batch pass will relabel correctly.
    private func verifySelf(
        _ n: Int, startTime: TimeInterval, endTime: TimeInterval
    ) async -> Verdict {
        appendClip(for: n, startTime: startTime, endTime: endTime)
        let clipSeconds = Double(clips[n]?.count ?? 0) / Self.sampleRate
        guard clipSeconds >= Self.selfVerifySeconds, let clip = clips[n] else { return .isSelf }
        clips[n] = nil
        do {
            let embedding = try await SelfVoiceIdentifier.extractEmbedding(from: clip)
            guard let voiceprint else { return .isSelf }
            let verdict = Self.verifyVerdict(
                embedding: embedding, voiceprint: voiceprint, profiles: profiles
            )
            if verdict != .isSelf {
                selfIndices.remove(n)
                if case .matchedLibrary(let name) = verdict { matchedNames[n] = name }
                let distance = SelfVoiceIdentifier.distance(embedding, voiceprint)
                Log.diarization.info("Live self-voice demoted: speaker \(n, privacy: .public) drifted to distance \(distance, privacy: .public)")
            }
            return verdict
        } catch SelfVoiceIdentifier.EnrollmentError.notEnoughSpeech {
            // Window was mostly non-speech; start a fresh one.
        } catch {
            Log.diarization.error("Live self-voice verification failed: \(error, privacy: .public)")
        }
        return .isSelf
    }

    /// Pure drift-verification policy: a fresh window still within the batch
    /// self ceiling keeps the speaker as the user (the strict live distance
    /// only gates the initial promotion); a clearly different voice is scored
    /// once against the library and otherwise becomes a lettered speaker.
    nonisolated static func verifyVerdict(
        embedding: [Float], voiceprint: [Float], profiles: [SpeakerProfile]
    ) -> Verdict {
        let distance = SelfVoiceIdentifier.distance(embedding, voiceprint)
        guard distance > SelfVoiceIdentifier.maxMatchDistance else { return .isSelf }
        return evaluate(
            embedding: embedding, voiceprint: voiceprint,
            profiles: profiles, isFinalAttempt: true
        )
    }

    /// Pure scoring policy for one attempt: the enrolled voiceprint is checked
    /// first (strict live distance), then the library (its own ceiling plus
    /// runner-up margin). When neither is confident, an early attempt stays
    /// pending so the voice is rescored with more audio; the final attempt
    /// decides `.notSelf` for good. A voice clearly unlike the voiceprint with
    /// no library to consult is decided immediately (nothing left to wait for).
    nonisolated static func evaluate(
        embedding: [Float],
        voiceprint: [Float]?,
        profiles: [SpeakerProfile],
        isFinalAttempt: Bool
    ) -> Verdict {
        var selfDistance: Float = .infinity
        if let voiceprint {
            selfDistance = SelfVoiceIdentifier.distance(embedding, voiceprint)
            if selfDistance <= liveMatchDistance { return .isSelf }
        }
        if let profile = SpeakerLibraryStore.match(embedding: embedding, in: profiles) {
            return .matchedLibrary(name: profile.name)
        }
        if isFinalAttempt { return .notSelf }
        if profiles.isEmpty, selfDistance > SelfVoiceIdentifier.maxMatchDistance {
            return .notSelf
        }
        return .pending
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
