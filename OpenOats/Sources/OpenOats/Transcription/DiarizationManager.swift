import FluidAudio
import Foundation

/// Manages LS-EEND speaker diarization for a single audio channel.
/// Wraps the FluidAudio LSEENDDiarizer and provides speaker attribution
/// for transcribed segments by querying the diarizer timeline.
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
    private nonisolated(unsafe) let diarizer = LSEENDDiarizer(
        onsetPadFrames: 1,
        minFramesOn: 3,
        minFramesOff: 6
    )
    private var isInitialized = false
    /// Diarizer index most recently returned by dominantSpeaker, for
    /// sticky-speaker hysteresis on borderline overlap calls.
    private var lastDominantIndex: Int?

    /// Load the LS-EEND model for the given variant. Must be called before feedAudio/dominantSpeaker.
    func load(variant: LSEENDVariant = .dihard3) async throws {
        Log.diarization.info("Loading LS-EEND model (variant: \(variant.rawValue, privacy: .public))")
        try await diarizer.initialize(variant: variant)
        isInitialized = true
        Log.diarization.info("LS-EEND model loaded")
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
        let timeline = diarizer.timeline
        let speakers = timeline.speakers

        guard !speakers.isEmpty else { return channel.fallbackSpeaker }

        var bestSpeaker: Int = 0
        var bestOverlap: Float = 0
        var overlapByIndex: [Int: Float] = [:]

        let queryStart = Float(startTime)
        let queryEnd = Float(endTime)

        for (index, speaker) in speakers {
            let allSegments = speaker.finalizedSegments + speaker.tentativeSegments
            var overlap: Float = 0

            for segment in allSegments {
                let overlapStart = max(segment.startTime, queryStart)
                let overlapEnd = min(segment.endTime, queryEnd)
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
        let activeSpeakers = speakers.values.filter { $0.hasSegments }
        if activeSpeakers.count <= 1 {
            return channel.fallbackSpeaker
        }

        // Map diarizer speaker index to Speaker enum
        // System: index 0 → .remote(1); microphone: index 0 → .local(1), etc.
        return channel.speaker(forDiarizerIndex: bestSpeaker)
    }

    /// Returns diarized speaker runs overlapping the given range.
    /// These runs can be used to split a longer speech segment into
    /// smaller speaker-consistent chunks.
    func speakerRuns(
        from startTime: TimeInterval,
        to endTime: TimeInterval,
        channel: Channel = .system
    ) -> [BatchTranscriptionSegmentLayout.SpeakerRun] {
        let timeline = diarizer.timeline
        let speakers = timeline.speakers

        guard !speakers.isEmpty else { return [] }

        let queryStart = Float(startTime)
        let queryEnd = Float(endTime)
        let activeSpeakers = speakers.values.filter { $0.hasSegments }

        if activeSpeakers.count <= 1 {
            return [
                BatchTranscriptionSegmentLayout.SpeakerRun(
                    startTime: startTime,
                    endTime: endTime,
                    speaker: channel.fallbackSpeaker
                )
            ]
        }

        var runs: [BatchTranscriptionSegmentLayout.SpeakerRun] = []

        for (index, speaker) in speakers {
            let mappedSpeaker = channel.speaker(forDiarizerIndex: index)
            let allSegments = speaker.finalizedSegments + speaker.tentativeSegments
            for segment in allSegments {
                let overlapStart = max(segment.startTime, queryStart)
                let overlapEnd = min(segment.endTime, queryEnd)
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
    /// with at least one segment are included. Call after finalize() and before
    /// reset(); used to gather per-speaker audio for voiceprint matching.
    func speakerSegments() -> [Int: [SpeakerSegment]] {
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
        guard isInitialized else { return }
        lastDominantIndex = nil
        diarizer.reset()
    }
}
