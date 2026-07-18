import FluidAudio
import Foundation

extension DiarizationVariant {
    /// FluidAudio's LS-EEND variant enum lost its String raw values in 0.15.x,
    /// so the settings value maps by explicit case instead of rawValue.
    var lseendVariant: LSEENDVariant {
        switch self {
        case .ami: .ami
        case .callhome: .callhome
        case .dihard3: .dihard3
        }
    }
}

/// Manages speaker diarization for a single audio channel.
/// Live sessions stream through the FluidAudio LSEENDDiarizer; the batch pass
/// can instead run the offline VBx pipeline (processOffline), which reclusters
/// the whole file at once and is substantially more accurate than streaming.
/// Either way, speaker attribution queries read the same normalized state.
actor DiarizationManager {
    /// Which capture channel the audio being diarized came from. Controls how
    /// diarizer speaker indices map onto Speaker labels and what the
    /// single-speaker fallback is.
    enum Channel: Sendable {
        /// System audio: remote call participants. Index n → .remote(n+1), fallback .them.
        case system
        /// Microphone: in-person participants. Index n → .local(n+1), fallback .you.
        case microphone

        var fallbackSpeaker: Speaker {
            switch self {
            case .system: .them
            case .microphone: .you
            }
        }

        func speaker(forDiarizerIndex index: Int) -> Speaker {
            switch self {
            case .system: .remote(index + 1)
            case .microphone: .local(index + 1)
            }
        }
    }

    /// A diarized time range for one speaker, in seconds from the start of the audio.
    struct SpeakerSegment: Sendable {
        let start: Float
        let end: Float
    }

    /// Meeting-tuned timeline post-processing (frames are ~100 ms): drop
    /// speaker turns under 0.3 s, bridge same-speaker gaps under 0.6 s, and pad
    /// onsets 0.1 s so word starts aren't clipped. Mirrors the NeMo meeting
    /// recipe (min_duration_off 0.6) and the production 250-400 ms turn floor.
    private nonisolated(unsafe) let diarizer: LSEENDDiarizer = {
        var config = DiarizerTimelineConfig.default(numSpeakers: 1, frameDurationSeconds: 0.1)
        config.onsetPadFrames = 1
        config.minFramesOn = 3
        config.minFramesOff = 6
        // We only ever read timeline.speakers segments; raw finalized
        // prediction frames would otherwise accumulate for the whole session.
        config.maxStoredFrames = 0
        return LSEENDDiarizer(timelineConfig: config)
    }()
    private var isInitialized = false
    /// Non-nil after processOffline succeeds: per-speaker segments from the
    /// offline VBx pass. When set, all attribution queries read this instead
    /// of the streaming LS-EEND timeline.
    private var offlineSegments: [Int: [SpeakerSegment]]?
    /// Diarizer index most recently returned by dominantSpeaker, for
    /// sticky-speaker hysteresis on borderline overlap calls.
    private var lastDominantIndex: Int?

    /// Offline VBx models, loaded once and shared across channels (and across
    /// capped/uncapped managers) so mic and system don't each reload CoreML.
    private nonisolated(unsafe) var offlineModels: OfflineDiarizerModels?

    /// Whether the streaming LS-EEND model has been loaded via load(variant:).
    var isStreamingModelLoaded: Bool { isInitialized }

    /// Load the LS-EEND model for the given variant. Must be called before feedAudio/dominantSpeaker.
    func load(variant: LSEENDVariant = .dihard3) async throws {
        Log.diarization.info("Loading LS-EEND model (variant: \(String(describing: variant), privacy: .public))")
        try await diarizer.initialize(variant: variant)
        isInitialized = true
        Log.diarization.info("LS-EEND model loaded")
    }

    /// Run the offline VBx diarization pipeline over a complete recording and
    /// serve all subsequent attribution queries from its result (until reset).
    /// Offline reclustering of the whole file is substantially more accurate
    /// than the streaming timeline (~11% vs ~30% DER on meeting benchmarks).
    /// Downloads the offline models on first use.
    /// - Parameter maxSpeakers: Soft cap on how many speakers the clustering may
    ///   find (an "expected in-room speakers" hint for the mic channel, counting
    ///   the user). nil lets the pipeline discover the count from the clustering
    ///   threshold alone. A cap only bounds the maximum; a quieter room still
    ///   yields fewer speakers.
    func processOffline(_ samples: [Float], maxSpeakers: Int? = nil) async throws {
        if offlineModels == nil {
            // Loads from the cached repo, downloading on first use.
            offlineModels = try await OfflineDiarizerModels.load()
        }
        guard let offlineModels else { return }

        var config = OfflineDiarizerConfig.default
        if let maxSpeakers, maxSpeakers > 0 {
            config.clustering.maxSpeakers = maxSpeakers
        }
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: offlineModels)

        let result: DiarizationResult
        do {
            result = try await manager.process(audio: samples)
        } catch OfflineDiarizationError.noSpeechDetected {
            // A silent channel (e.g. no call audio during an in-person
            // meeting) is a valid empty result, not an engine failure: record
            // it so the caller doesn't fall back to streaming LS-EEND just to
            // rediscover the silence.
            offlineSegments = [:]
            Log.diarization.info("Offline VBx diarization: no speech detected on this channel")
            return
        }

        // Map speaker ids to integer indices in order of first appearance so
        // downstream lettering (Speaker A, B, ...) follows speaking order.
        var indexBySpeakerId: [String: Int] = [:]
        var segments: [Int: [SpeakerSegment]] = [:]
        for segment in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let index: Int
            if let existing = indexBySpeakerId[segment.speakerId] {
                index = existing
            } else {
                index = indexBySpeakerId.count
                indexBySpeakerId[segment.speakerId] = index
            }
            segments[index, default: []].append(
                SpeakerSegment(start: segment.startTimeSeconds, end: segment.endTimeSeconds)
            )
        }
        offlineSegments = segments
        Log.diarization.info("Offline VBx diarization complete: \(segments.count, privacy: .public) speaker(s) across \(result.segments.count, privacy: .public) segments")
    }

    /// Speaker segments from whichever engine ran, keyed by diarizer index.
    /// Offline results win when present; otherwise the live LS-EEND timeline
    /// (finalized plus tentative segments) is normalized into the same shape.
    private func segmentsByIndex() -> [Int: [SpeakerSegment]] {
        if let offlineSegments { return offlineSegments }
        var result: [Int: [SpeakerSegment]] = [:]
        for (index, speaker) in diarizer.timeline.speakers {
            let segments = (speaker.finalizedSegments + speaker.tentativeSegments)
                .map { SpeakerSegment(start: $0.startTime, end: $0.endTime) }
            if !segments.isEmpty {
                result[index] = segments
            }
        }
        return result
    }

    /// Feed audio samples to the diarizer. Samples should be at 16kHz mono Float32.
    /// Uses addAudio + process for streaming (does not reset state between calls).
    func feedAudio(_ samples: [Float]) throws {
        guard isInitialized else { return }
        try diarizer.addAudio(samples, sourceSampleRate: 16000)
        _ = try diarizer.process()
    }

    /// Returns the dominant speaker for a given time range in seconds.
    /// Queries the DiarizerTimeline and finds which speaker has the most
    /// speech frames overlapping [startTime, endTime].
    func dominantSpeaker(
        from startTime: TimeInterval,
        to endTime: TimeInterval,
        channel: Channel = .system
    ) -> Speaker {
        let speakers = segmentsByIndex()

        guard !speakers.isEmpty else { return channel.fallbackSpeaker }

        var bestSpeaker: Int = 0
        var bestOverlap: Float = 0
        var overlapByIndex: [Int: Float] = [:]

        let queryStart = Float(startTime)
        let queryEnd = Float(endTime)

        for (index, segments) in speakers {
            var overlap: Float = 0

            for segment in segments {
                let overlapStart = max(segment.start, queryStart)
                let overlapEnd = min(segment.end, queryEnd)
                if overlapEnd > overlapStart {
                    overlap += overlapEnd - overlapStart
                }
            }

            overlapByIndex[index] = overlap
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = index
            }
        }

        guard bestOverlap > 0 else { return channel.fallbackSpeaker }

        // Sticky-speaker hysteresis: on borderline calls (the previous speaker
        // nearly ties the winner), keep the previous speaker rather than
        // flipping labels mid-conversation. Production systems apply the same
        // preference (e.g. Speechmatics prefer_current_speaker).
        if let last = lastDominantIndex,
           last != bestSpeaker,
           let lastOverlap = overlapByIndex[last],
           lastOverlap >= bestOverlap * 0.8 {
            bestSpeaker = last
        }
        lastDominantIndex = bestSpeaker

        // If only one speaker was detected in the entire session, fall back to the
        // channel's single-speaker label (no point labeling "Speaker 1"/"Speaker A"
        // when there's only one voice; on the mic that voice is presumably you).
        if speakers.count <= 1 {
            return channel.fallbackSpeaker
        }

        // Map diarizer speaker index to Speaker enum
        // System: index 0 → .remote(1); microphone: index 0 → .local(1), etc.
        return channel.speaker(forDiarizerIndex: bestSpeaker)
    }

    /// Raw diarizer index with the most speech overlapping the range, without
    /// the single-speaker collapse or hysteresis. Used to verify the collapsed
    /// "one voice = the user" assumption against the enrolled voiceprint.
    func dominantIndex(from startTime: TimeInterval, to endTime: TimeInterval) -> Int? {
        let queryStart = Float(startTime)
        let queryEnd = Float(endTime)
        var best: (index: Int, overlap: Float)?
        for (index, segments) in segmentsByIndex() {
            var overlap: Float = 0
            for segment in segments {
                let overlapStart = max(segment.start, queryStart)
                let overlapEnd = min(segment.end, queryEnd)
                if overlapEnd > overlapStart {
                    overlap += overlapEnd - overlapStart
                }
            }
            if overlap > 0, overlap > (best?.overlap ?? 0) {
                best = (index, overlap)
            }
        }
        return best?.index
    }

    /// Returns diarized speaker runs overlapping the given range.
    /// These runs can be used to split a longer speech segment into
    /// smaller speaker-consistent chunks.
    func speakerRuns(
        from startTime: TimeInterval,
        to endTime: TimeInterval,
        channel: Channel = .system
    ) -> [BatchTranscriptionSegmentLayout.SpeakerRun] {
        let speakers = segmentsByIndex()

        guard !speakers.isEmpty else { return [] }

        let queryStart = Float(startTime)
        let queryEnd = Float(endTime)

        if speakers.count <= 1 {
            return [
                BatchTranscriptionSegmentLayout.SpeakerRun(
                    startTime: startTime,
                    endTime: endTime,
                    speaker: channel.fallbackSpeaker
                )
            ]
        }

        var runs: [BatchTranscriptionSegmentLayout.SpeakerRun] = []

        for (index, segments) in speakers {
            let mappedSpeaker = channel.speaker(forDiarizerIndex: index)
            for segment in segments {
                let overlapStart = max(segment.start, queryStart)
                let overlapEnd = min(segment.end, queryEnd)
                guard overlapEnd > overlapStart else { continue }
                runs.append(
                    BatchTranscriptionSegmentLayout.SpeakerRun(
                        startTime: TimeInterval(overlapStart),
                        endTime: TimeInterval(overlapEnd),
                        speaker: mappedSpeaker
                    )
                )
            }
        }

        return runs
    }

    /// All diarized segments grouped by diarizer speaker index. Only speakers
    /// with at least one segment are included. Call after finalize() (or
    /// processOffline) and before reset(); used to gather per-speaker audio
    /// for voiceprint matching.
    func speakerSegments() -> [Int: [SpeakerSegment]] {
        segmentsByIndex()
    }

    /// Finalize the diarization session (flush tentative segments).
    func finalize() {
        guard isInitialized else { return }
        do {
            try diarizer.finalizeSession()
        } catch {
            Log.diarization.error("Failed to finalize LS-EEND session: \(error, privacy: .public)")
        }
    }

    /// Reset the diarizer state for a new session.
    func reset() {
        lastDominantIndex = nil
        offlineSegments = nil
        guard isInitialized else { return }
        diarizer.reset()
    }
}
