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
    /// Speakers the user explicitly claimed or named ("This is me" / a manual
    /// name). Scoring and drift verification leave these alone: user intent
    /// always beats the matcher.
    private var userPinned: Set<Int> = []
    /// Session-local self voice references learned from "This is me" pins:
    /// live clusters are unstable, so the user's voice can respawn as a new
    /// lettered cluster minutes after a pin. Each pinned cluster contributes
    /// one embedding of how the user sounds on THIS mic today, and scoring
    /// matches against the enrolled voiceprint and these references — so the
    /// next respawned cluster folds into "You" on its own. References come
    /// only from explicit user pins, never from auto matches (an auto-decided
    /// self feeding itself back in is how a wrong "You" would snowball).
    private var selfReferences: [Int: [Float]] = [:]
    /// Pinned clusters still waiting to contribute their reference embedding.
    private var referencePending: Set<Int> = []
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
        // Trim in ~30 s hunks, not per append: removeFirst memmoves the whole
        // remaining buffer (~11.5 MB), and mic taps arrive ~12x per second —
        // per-append trimming would copy ~130 MB/s for the rest of the meeting.
        let capacity = Int(Self.rollingCapacitySeconds * Self.sampleRate)
        let trimHunk = Int(30.0 * Self.sampleRate)
        if rollingSamples.count > capacity + trimHunk {
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

    /// Self references learned from "This is me" pins this session, exported
    /// at teardown so the batch pass can match self with the same evidence.
    func exportedSelfReferences() -> [[Float]] {
        Array(selfReferences.values)
    }

    /// Force-mark a speaker as not the user (live "Not me" correction).
    /// Also retracts any self reference this cluster contributed, so a wrong
    /// "This is me" can be fully undone.
    func markNotSelf(localSpeakerNumber n: Int) {
        decided.insert(n)
        selfIndices.remove(n)
        clips[n] = nil
        userPinned.insert(n)
        referencePending.remove(n)
        selfReferences[n] = nil
    }

    /// Force-mark a speaker as the user (live "This is me" correction).
    /// Pinned so drift verification never demotes a user-confirmed self, and
    /// queued to contribute a self reference from its next window of speech.
    func markSelf(localSpeakerNumber n: Int) {
        decided.insert(n)
        selfIndices.insert(n)
        matchedNames[n] = nil
        clips[n] = nil
        userPinned.insert(n)
        referencePending.insert(n)
    }

    /// The user assigned a name to this lettered speaker: stop scoring the
    /// voice and drop any auto match so nothing fights the manual assignment
    /// (in particular, a later self match must not fold it into "You").
    func markAssignedByUser(localSpeakerNumber n: Int) {
        decided.insert(n)
        selfIndices.remove(n)
        matchedNames[n] = nil
        clips[n] = nil
        userPinned.insert(n)
    }

    /// The user merged one lettered voice into another (live "same person"
    /// correction): fold the merged cluster's user-granted evidence into the
    /// survivor and drop its own bookkeeping. The engine routes all future
    /// audio for the merged slot to the survivor, so anything left behind
    /// would be unreachable anyway. The survivor's own verdict and name
    /// stand; the merged voice's auto match is dropped.
    func mergeCluster(from: Int, into: Int) {
        guard from != into else { return }
        if let reference = selfReferences.removeValue(forKey: from), selfReferences[into] == nil {
            selfReferences[into] = reference
        }
        if userPinned.remove(from) != nil {
            userPinned.insert(into)
            decided.insert(into)
        }
        if selfIndices.remove(from) != nil { selfIndices.insert(into) }
        if referencePending.remove(from) != nil { referencePending.insert(into) }
        decided.remove(from)
        scoredOnce.remove(from)
        matchedNames[from] = nil
        clips[from] = nil
        minNextScoreSeconds[from] = nil
    }

    /// The user cleared their assignment: reopen scoring from scratch so the
    /// voice can still be self-matched or library-named. Only reverses user
    /// pins — verdicts the matcher earned on its own stay decided.
    func unpinUserAssignment(localSpeakerNumber n: Int) {
        guard userPinned.contains(n) else { return }
        userPinned.remove(n)
        decided.remove(n)
        selfIndices.remove(n)
        matchedNames[n] = nil
        scoredOnce.remove(n)
        clips[n] = nil
        minNextScoreSeconds[n] = nil
        referencePending.remove(n)
        selfReferences[n] = nil
    }

    /// Record a finalized utterance attributed to a diarized speaker and score
    /// that voice once enough audio has accumulated. `.isSelf` and
    /// `.matchedLibrary` are returned on the call that identifies the voice
    /// (callers may relabel / publish the name).
    func classifyUtterance(
        localSpeakerNumber n: Int, startTime: TimeInterval, endTime: TimeInterval
    ) async -> Verdict {
        // Nothing to score against and no user pin to honor: skip the clip
        // bookkeeping entirely (the matcher may exist purely to carry pins).
        guard hasVoiceprint || !profiles.isEmpty || decided.contains(n) else {
            return .pending
        }
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
                isFinalAttempt: readyForRescore,
                selfReferences: Array(selfReferences.values)
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
                if readyForRescore {
                    // Gray zone on a full clip: keep the voice undecided but
                    // score fresh windows from here on — a frozen clip would
                    // re-yield the same verdict forever.
                    clips[n] = nil
                }
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
        if userPinned.contains(n) {
            await collectSelfReferenceIfPending(n, startTime: startTime, endTime: endTime)
            return .isSelf
        }
        appendClip(for: n, startTime: startTime, endTime: endTime)
        let clipSeconds = Double(clips[n]?.count ?? 0) / Self.sampleRate
        guard clipSeconds >= Self.selfVerifySeconds, let clip = clips[n] else { return .isSelf }
        clips[n] = nil
        do {
            let embedding = try await SelfVoiceIdentifier.extractEmbedding(from: clip)
            guard let voiceprint else { return .isSelf }
            let verdict = Self.verifyVerdict(
                embedding: embedding, voiceprint: voiceprint, profiles: profiles,
                selfReferences: Array(selfReferences.values)
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

    /// Extract one embedding from a freshly pinned cluster's next window of
    /// speech and keep it as a session-local self reference. Retried on the
    /// following window if extraction fails; done at most once per cluster.
    private func collectSelfReferenceIfPending(
        _ n: Int, startTime: TimeInterval, endTime: TimeInterval
    ) async {
        guard referencePending.contains(n) else { return }
        appendClip(for: n, startTime: startTime, endTime: endTime)
        let clipSeconds = Double(clips[n]?.count ?? 0) / Self.sampleRate
        guard clipSeconds >= Self.selfVerifySeconds, let clip = clips[n] else { return }
        clips[n] = nil
        if let embedding = try? await SelfVoiceIdentifier.extractEmbedding(from: clip) {
            referencePending.remove(n)
            selfReferences[n] = embedding
            Log.diarization.info("Learned self reference from pinned speaker \(n, privacy: .public)")
        }
    }

    /// Pure drift-verification policy: a fresh window still within the batch
    /// self ceiling keeps the speaker as the user (the strict live distance
    /// only gates the initial promotion); a clearly different voice is scored
    /// once against the library and otherwise becomes a lettered speaker.
    nonisolated static func verifyVerdict(
        embedding: [Float], voiceprint: [Float], profiles: [SpeakerProfile],
        selfReferences: [[Float]] = []
    ) -> Verdict {
        var distance = SelfVoiceIdentifier.distance(embedding, voiceprint)
        for reference in selfReferences {
            distance = min(distance, SelfVoiceIdentifier.distance(embedding, reference))
        }
        guard distance > SelfVoiceIdentifier.maxMatchDistance else { return .isSelf }
        return evaluate(
            embedding: embedding, voiceprint: voiceprint,
            profiles: profiles, isFinalAttempt: true,
            selfReferences: selfReferences
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
        isFinalAttempt: Bool,
        selfReferences: [[Float]] = []
    ) -> Verdict {
        var selfDistance: Float = .infinity
        if let voiceprint {
            selfDistance = SelfVoiceIdentifier.distance(embedding, voiceprint)
        }
        // "This is me" references capture how the user sounds on this mic
        // today; the nearest self evidence wins.
        for reference in selfReferences {
            selfDistance = min(selfDistance, SelfVoiceIdentifier.distance(embedding, reference))
        }
        if selfDistance <= liveMatchDistance { return .isSelf }
        if let profile = SpeakerLibraryStore.match(embedding: embedding, in: profiles) {
            return .matchedLibrary(name: profile.name)
        }
        if isFinalAttempt {
            // Gray zone: within the batch self ceiling but not a confident
            // live match. Locking notSelf here permanently letters the
            // user's slightly-off voice (observed in the field), so stay
            // pending — the caller keeps rescoring fresh windows.
            if selfDistance <= SelfVoiceIdentifier.maxMatchDistance { return .pending }
            return .notSelf
        }
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
