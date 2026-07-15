@preconcurrency import AVFoundation
import FluidAudio

struct BatchTranscriptionSegmentLayout {
    struct SegmentWindow {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let sampleRate: Double

        var duration: TimeInterval {
            max(0, endTime - startTime)
        }

        var sampleCount: Int {
            max(0, Int((duration * sampleRate).rounded()))
        }
    }

    struct SpeakerRun: Equatable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let speaker: Speaker

        var duration: TimeInterval {
            max(0, endTime - startTime)
        }
    }

    struct Slice: Equatable {
        let speaker: Speaker
        let startSample: Int
        let sampleCount: Int
    }

    static func slices(
        for segment: SegmentWindow,
        diarizedRuns: [SpeakerRun],
        fallbackSpeaker: Speaker,
        minimumRunDuration: TimeInterval = 0.8
    ) -> [Slice] {
        guard segment.sampleCount > 0 else { return [] }

        let distinctSpeakers = Set(diarizedRuns.map(\.speaker))
        var runs = diarizedRuns
            .map { run in
                SpeakerRun(
                    startTime: max(segment.startTime, run.startTime),
                    endTime: min(segment.endTime, run.endTime),
                    speaker: run.speaker
                )
            }
            .filter { $0.duration > 0 }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.endTime < rhs.endTime
                }
                return lhs.startTime < rhs.startTime
            }

        guard !runs.isEmpty else {
            return [Slice(speaker: fallbackSpeaker, startSample: 0, sampleCount: segment.sampleCount)]
        }

        runs = normalizeRuns(runs, for: segment)
        runs = mergeShortRuns(runs, minimumRunDuration: minimumRunDuration)

        if runs.isEmpty {
            return [Slice(speaker: fallbackSpeaker, startSample: 0, sampleCount: segment.sampleCount)]
        }

        if runs.count == 1, distinctSpeakers.count > 1 {
            return [Slice(speaker: fallbackSpeaker, startSample: 0, sampleCount: segment.sampleCount)]
        }

        var slices: [Slice] = []
        for (index, run) in runs.enumerated() {
            let startOffset = max(0, run.startTime - segment.startTime)
            let endOffset = max(startOffset, run.endTime - segment.startTime)
            let startSample = min(segment.sampleCount, max(0, Int((startOffset * segment.sampleRate).rounded())))
            let computedEndSample = min(segment.sampleCount, max(startSample, Int((endOffset * segment.sampleRate).rounded())))
            let endSample: Int
            if index == runs.count - 1 {
                endSample = segment.sampleCount
            } else {
                endSample = computedEndSample
            }
            let sampleCount = max(0, endSample - startSample)
            guard sampleCount > 0 else { continue }
            slices.append(Slice(speaker: run.speaker, startSample: startSample, sampleCount: sampleCount))
        }

        guard !slices.isEmpty else {
            return [Slice(speaker: fallbackSpeaker, startSample: 0, sampleCount: segment.sampleCount)]
        }

        if slices.count > 1 {
            for index in 0..<(slices.count - 1) {
                let current = slices[index]
                let next = slices[index + 1]
                if current.startSample + current.sampleCount != next.startSample {
                    let adjustedCurrent = Slice(
                        speaker: current.speaker,
                        startSample: current.startSample,
                        sampleCount: max(0, next.startSample - current.startSample)
                    )
                    slices[index] = adjustedCurrent
                }
            }
            let lastIndex = slices.index(before: slices.endIndex)
            let last = slices[lastIndex]
            slices[lastIndex] = Slice(
                speaker: last.speaker,
                startSample: last.startSample,
                sampleCount: max(0, segment.sampleCount - last.startSample)
            )
        }

        return slices.filter { $0.sampleCount > 0 }
    }

    private static func normalizeRuns(_ runs: [SpeakerRun], for segment: SegmentWindow) -> [SpeakerRun] {
        guard !runs.isEmpty else { return [] }
        var normalized = runs

        if normalized[0].startTime > segment.startTime {
            normalized[0] = SpeakerRun(
                startTime: segment.startTime,
                endTime: normalized[0].endTime,
                speaker: normalized[0].speaker
            )
        }

        if normalized[normalized.index(before: normalized.endIndex)].endTime < segment.endTime {
            let lastIndex = normalized.index(before: normalized.endIndex)
            normalized[lastIndex] = SpeakerRun(
                startTime: normalized[lastIndex].startTime,
                endTime: segment.endTime,
                speaker: normalized[lastIndex].speaker
            )
        }

        for index in 0..<(normalized.count - 1) {
            let current = normalized[index]
            let next = normalized[index + 1]
            let midpoint = (current.endTime + next.startTime) / 2
            normalized[index] = SpeakerRun(
                startTime: current.startTime,
                endTime: midpoint,
                speaker: current.speaker
            )
            normalized[index + 1] = SpeakerRun(
                startTime: midpoint,
                endTime: next.endTime,
                speaker: next.speaker
            )
        }

        return mergeAdjacentSameSpeakerRuns(normalized)
    }

    private static func mergeShortRuns(
        _ runs: [SpeakerRun],
        minimumRunDuration: TimeInterval
    ) -> [SpeakerRun] {
        var merged = mergeAdjacentSameSpeakerRuns(runs)
        guard minimumRunDuration > 0 else { return merged }

        while let index = merged.firstIndex(where: { $0.duration < minimumRunDuration }), merged.count > 1 {
            if index == 0 {
                let next = merged[1]
                merged[1] = SpeakerRun(
                    startTime: merged[0].startTime,
                    endTime: next.endTime,
                    speaker: next.speaker
                )
                merged.remove(at: 0)
            } else if index == merged.count - 1 {
                let previousIndex = index - 1
                let previous = merged[previousIndex]
                merged[previousIndex] = SpeakerRun(
                    startTime: previous.startTime,
                    endTime: merged[index].endTime,
                    speaker: previous.speaker
                )
                merged.remove(at: index)
            } else {
                let previousIndex = index - 1
                let nextIndex = index + 1
                let previous = merged[previousIndex]
                let next = merged[nextIndex]
                if previous.duration >= next.duration {
                    merged[previousIndex] = SpeakerRun(
                        startTime: previous.startTime,
                        endTime: merged[index].endTime,
                        speaker: previous.speaker
                    )
                    merged.remove(at: index)
                } else {
                    merged[nextIndex] = SpeakerRun(
                        startTime: merged[index].startTime,
                        endTime: next.endTime,
                        speaker: next.speaker
                    )
                    merged.remove(at: index)
                }
            }
            merged = mergeAdjacentSameSpeakerRuns(merged)
        }

        return merged
    }

    private static func mergeAdjacentSameSpeakerRuns(_ runs: [SpeakerRun]) -> [SpeakerRun] {
        guard var current = runs.first else { return [] }
        var merged: [SpeakerRun] = []

        for run in runs.dropFirst() {
            if run.speaker == current.speaker {
                current = SpeakerRun(
                    startTime: current.startTime,
                    endTime: max(current.endTime, run.endTime),
                    speaker: current.speaker
                )
            } else {
                merged.append(current)
                current = run
            }
        }

        merged.append(current)
        return merged
    }
}

struct BatchTranscriptOverwriteGuard {
    private struct TranscriptStats {
        let recordCount: Int
        let nonWhitespaceCharacterCount: Int
        let duration: TimeInterval

        init(records: [SessionRecord]) {
            recordCount = records.count
            nonWhitespaceCharacterCount = records.reduce(into: 0) { total, record in
                let text = record.cleanedText ?? record.text
                total += text.unicodeScalars.reduce(into: 0) { count, scalar in
                    if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                        count += 1
                    }
                }
            }
            if let first = records.first?.timestamp, let last = records.last?.timestamp {
                duration = max(0, last.timeIntervalSince(first))
            } else {
                duration = 0
            }
        }

        var isSubstantial: Bool {
            recordCount >= 4 || nonWhitespaceCharacterCount >= 120
        }
    }

    static func rejectionReason(
        existingRecords: [SessionRecord],
        replacementRecords: [SessionRecord]
    ) -> String? {
        let existing = TranscriptStats(records: existingRecords)
        guard existing.isSubstantial else { return nil }

        let replacement = TranscriptStats(records: replacementRecords)
        let characterCollapseThreshold = max(40, Int(Double(existing.nonWhitespaceCharacterCount) * 0.35))
        let characterCollapse = replacement.nonWhitespaceCharacterCount < characterCollapseThreshold
        let recordCollapse = replacement.recordCount * 3 < existing.recordCount
        let durationCollapse = existing.duration >= 60 && replacement.duration < existing.duration * 0.4

        guard characterCollapse && (recordCollapse || durationCollapse) else {
            return nil
        }

        return "Batch re-transcription looks unreliable; kept existing transcript"
    }
}

/// Offline two-pass transcription engine that processes recorded CAF files
/// using a higher-quality model after a meeting ends.
actor BatchAudioTranscriber {

    enum Status: Sendable, Equatable {
        case idle
        case loading(model: String)
        case transcribing(progress: Double)
        case completed(sessionID: String)
        case cancelled
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// True when the current batch job is an audio file import (affects UI copy).
    private(set) var isImporting: Bool = false
    private(set) var activeSessionID: String?
    private var currentTask: Task<Void, Never>?

    /// Process batch transcription for a completed session.
    func process(
        sessionID: String,
        model: TranscriptionModel,
        locale: Locale,
        sessionRepository: SessionRepository,
        notesDirectory: URL,
        enableDiarization: Bool = false,
        enableMicDiarization: Bool = false,
        diarizationVariant: DiarizationVariant = .dihard3
    ) async {
        // Cancel any existing task
        currentTask?.cancel()
        activeSessionID = sessionID
        isImporting = false

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runTranscription(
                    sessionID: sessionID,
                    model: model,
                    locale: locale,
                    sessionRepository: sessionRepository,
                    notesDirectory: notesDirectory,
                    enableDiarization: enableDiarization,
                    enableMicDiarization: enableMicDiarization,
                    diarizationVariant: diarizationVariant
                )
            } catch is CancellationError {
                await self.setStatus(.cancelled)
                await self.setActiveSessionID(nil)
                DiagnosticsSupport.record(category: "batch", message: "Batch transcription cancelled for \(sessionID)")
                Log.batchTranscription.info("Batch transcription cancelled for \(sessionID, privacy: .public)")
            } catch {
                await self.setStatus(.failed(error.localizedDescription))
                await self.setActiveSessionID(nil)
                DiagnosticsSupport.record(category: "batch", message: "Batch transcription failed for \(sessionID): \(error.localizedDescription)")
                Log.batchTranscription.error("Batch transcription failed: \(error, privacy: .public)")
            }
        }
        currentTask = task
        await task.value
    }

    func cancel() async {
        let task = currentTask
        currentTask = nil
        task?.cancel()
        await task?.value
        status = .cancelled
        isImporting = false
        activeSessionID = nil
    }

    // MARK: - Audio Import

    /// Import and transcribe an external audio file (meeting recording).
    func importFile(
        url: URL,
        sessionID: String,
        model: TranscriptionModel,
        locale: Locale,
        sessionRepository: SessionRepository
    ) async {
        currentTask?.cancel()
        isImporting = true
        activeSessionID = sessionID

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runImport(
                    url: url,
                    sessionID: sessionID,
                    model: model,
                    locale: locale,
                    sessionRepository: sessionRepository
                )
            } catch is CancellationError {
                await self.setStatus(.cancelled)
                await self.setIsImporting(false)
                await self.setActiveSessionID(nil)
                DiagnosticsSupport.record(category: "batch", message: "Audio import cancelled for \(sessionID)")
                Log.batchTranscription.info("Audio import cancelled for \(sessionID, privacy: .public)")
            } catch {
                await self.setStatus(.failed(error.localizedDescription))
                await self.setIsImporting(false)
                await self.setActiveSessionID(nil)
                DiagnosticsSupport.record(category: "batch", message: "Audio import failed for \(sessionID): \(error.localizedDescription)")
                Log.batchTranscription.error("Audio import failed: \(error, privacy: .public)")
            }
        }
        currentTask = task
        await task.value
    }

    private func runImport(
        url: URL,
        sessionID: String,
        model: TranscriptionModel,
        locale: Locale,
        sessionRepository: SessionRepository
    ) async throws {
        Log.batchTranscription.info("Starting audio import for \(sessionID, privacy: .public) from \(url.lastPathComponent, privacy: .public)")
        DiagnosticsSupport.record(category: "batch", message: "Starting audio import for \(sessionID) model=\(model.rawValue)")
        status = .loading(model: model.displayName)

        // Prepare backend and VAD
        let backend = model.makeBackend()
        try await backend.prepare { statusMsg in
            Log.batchTranscription.debug("Backend: \(statusMsg, privacy: .public)")
        }

        try Task.checkCancellation()

        let vad = try await VadManager()

        try Task.checkCancellation()

        status = .transcribing(progress: 0)

        // Derive start date from file attributes
        let startDate: Date
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let creationDate = attrs[.creationDate] as? Date {
            startDate = creationDate
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modDate = attrs[.modificationDate] as? Date {
            startDate = modDate
        } else {
            startDate = Date()
        }

        // Transcribe the file as a single speaker
        let records = try await transcribeFile(
            url: url,
            speaker: .them,
            startDate: startDate,
            sampleRate: nil,
            backend: backend,
            vad: vad,
            locale: locale,
            progressBase: 0,
            progressScale: 1.0
        )

        try Task.checkCancellation()

        guard !records.isEmpty else {
            Log.batchTranscription.warning("Audio import produced no records for \(sessionID, privacy: .public)")
            DiagnosticsSupport.record(category: "batch", message: "Audio import produced no speech for \(sessionID)")
            status = .failed("No speech detected in the audio file")
            isImporting = false
            return
        }

        // Derive endedAt from last record timestamp
        let endedAt = records.last?.timestamp ?? startDate

        // Save final transcript atomically
        await sessionRepository.saveFinalTranscript(sessionID: sessionID, records: records)

        // Update session metadata with final counts
        await sessionRepository.finalizeImportedSession(
            sessionID: sessionID,
            utteranceCount: records.count,
            endedAt: endedAt
        )

        // Copy original audio file to session
        await sessionRepository.copyAudioFileToSession(sessionID: sessionID, sourceURL: url)

        status = .completed(sessionID: sessionID)
        isImporting = false
        DiagnosticsSupport.record(category: "batch", message: "Audio import completed for \(sessionID) records=\(records.count)")
        Log.batchTranscription.info("Audio import completed for \(sessionID, privacy: .public): \(records.count, privacy: .public) records")
    }

    // MARK: - Private

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        switch newStatus {
        case .idle, .cancelled, .failed, .completed:
            activeSessionID = nil
        case .loading, .transcribing:
            break
        }
    }

    private func setIsImporting(_ value: Bool) {
        isImporting = value
    }

    private func setActiveSessionID(_ value: String?) {
        activeSessionID = value
    }

    private func runTranscription(
        sessionID: String,
        model: TranscriptionModel,
        locale: Locale,
        sessionRepository: SessionRepository,
        notesDirectory: URL,
        enableDiarization: Bool,
        enableMicDiarization: Bool,
        diarizationVariant: DiarizationVariant
    ) async throws {
        Log.batchTranscription.info("Starting batch transcription for \(sessionID, privacy: .public) with \(model.rawValue, privacy: .public)")
        DiagnosticsSupport.record(category: "batch", message: "Starting batch transcription for \(sessionID) model=\(model.rawValue)")
        status = .loading(model: model.displayName)

        // Load batch metadata
        let urls = await sessionRepository.batchAudioURLs(sessionID: sessionID)
        guard urls.mic != nil || urls.sys != nil else {
            Log.batchTranscription.warning("No batch audio found for \(sessionID, privacy: .public)")
            DiagnosticsSupport.record(category: "batch", message: "No retained batch audio found for \(sessionID)")
            status = .failed("No audio files found")
            return
        }

        // Load timing anchors
        let anchors = await loadBatchMeta(sessionID: sessionID, sessionRepository: sessionRepository)

        // Create and prepare backend
        let backend = model.makeBackend()
        try await backend.prepare { statusMsg in
            Log.batchTranscription.debug("Backend: \(statusMsg, privacy: .public)")
        }

        try Task.checkCancellation()

        // Load VAD
        let vad = try await VadManager()

        try Task.checkCancellation()

        status = .transcribing(progress: 0)

        // Transcribe each audio file
        var micRecords: [SessionRecord] = []
        var sysRecords: [SessionRecord] = []

        let totalFiles = (urls.mic != nil ? 1 : 0) + (urls.sys != nil ? 1 : 0)
        var filesProcessed = 0

        // One shared LS-EEND diarizer serves both channels sequentially
        // (reset between files) so only a single model stays in memory.
        let useElevenLabsNativeDiarization = enableDiarization && model == .elevenLabsScribe
        // Scribe's native diarization numbers speakers per API call, and the
        // mic channel is transcribed one VAD segment per call: letters would
        // not be stable across segments, and segments with a single talker
        // would collapse to "you" regardless of who spoke. The mic channel
        // therefore always uses LS-EEND (whole-file context, and required for
        // voiceprint self-identification); Scribe native diarization remains
        // in use for system audio only.
        let needsLSEENDForMic = enableMicDiarization && urls.mic != nil
        let needsLSEENDForSys = enableDiarization && !useElevenLabsNativeDiarization && urls.sys != nil
        var batchDiarizer: DiarizationManager?
        if needsLSEENDForMic || needsLSEENDForSys {
            do {
                let dm = DiarizationManager()
                let variant = LSEENDVariant(rawValue: diarizationVariant.rawValue) ?? .dihard3
                try await dm.load(variant: variant)
                batchDiarizer = dm
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Diarization is an enhancement: a missing or undownloadable
                // model (e.g. first run while offline) must not sink the
                // whole re-transcription.
                Log.batchTranscription.warning("Speaker diarization unavailable, continuing without it: \(error, privacy: .public)")
            }
        }

        var micSelfIndex: Int?
        var micSpeakerSegments: [Int: [DiarizationManager.SpeakerSegment]]?
        var sysSpeechRanges: [(start: Date, end: Date)] = []

        if let micURL = urls.mic {
            var micDiarizer: DiarizationManager?
            if needsLSEENDForMic, let dm = batchDiarizer {
                Log.batchTranscription.info("Running LS-EEND diarization on microphone audio...")
                let samples = try BatchAudioSampleReader.readAll(
                    url: micURL,
                    targetRate: 16000,
                    overrideSampleRate: anchors?.micSampleRate
                )
                try await dm.feedAudio(samples)
                await dm.finalize()
                micDiarizer = dm
                let segments = await dm.speakerSegments()
                micSpeakerSegments = segments
                Log.batchTranscription.info("Microphone diarization complete")

                // Match the enrolled voiceprint against the diarized speakers now,
                // while the decoded samples are still in memory (before the ASR
                // pass extends their lifetime).
                if let profile = VoiceprintStore.load() {
                    if segments.count >= 2 {
                        do {
                            micSelfIndex = try await SelfVoiceIdentifier.matchSelf(
                                samples: samples,
                                speakerSegments: segments,
                                voiceprint: profile.embedding
                            )
                            if let index = micSelfIndex {
                                Log.batchTranscription.info("Enrolled voice matched diarized mic speaker \(index, privacy: .public)")
                            } else {
                                Log.batchTranscription.info("No diarized mic speaker matched the enrolled voice profile")
                            }
                        } catch {
                            Log.batchTranscription.warning("Self-voice identification failed: \(error, privacy: .public)")
                        }
                    }
                }
            }

            micRecords = try await transcribeFile(
                url: micURL,
                speaker: .you,
                startDate: anchors?.micStartDate,
                sampleRate: anchors?.micSampleRate,
                backend: backend,
                vad: vad,
                locale: locale,
                progressBase: 0,
                progressScale: 1.0 / Double(totalFiles),
                diarizationManager: micDiarizer,
                diarizationChannel: .microphone,
                useElevenLabsNativeDiarization: false
            )
            filesProcessed += 1
            Log.batchTranscription.debug("Mic transcription: \(micRecords.count, privacy: .public) records")

            // Clear mic timeline before the diarizer is reused for system audio.
            if micDiarizer != nil {
                await batchDiarizer?.reset()
            }
        }

        try Task.checkCancellation()

        if let sysURL = urls.sys {
            var sysDiarizer: DiarizationManager?
            if needsLSEENDForSys, let dm = batchDiarizer {
                Log.batchTranscription.info("Running LS-EEND diarization on system audio...")
                // Process complete audio file through diarizer
                let samples = try BatchAudioSampleReader.readAll(
                    url: sysURL,
                    targetRate: 16000,
                    overrideSampleRate: anchors?.sysSampleRate
                )
                try await dm.feedAudio(samples)
                await dm.finalize()
                sysDiarizer = dm
                Log.batchTranscription.info("Diarization complete")
            } else if useElevenLabsNativeDiarization {
                Log.batchTranscription.info("Using ElevenLabs native diarization for system audio")
            }

            sysRecords = try await transcribeFile(
                url: sysURL,
                speaker: .them,
                startDate: anchors?.sysStartDate,
                sampleRate: anchors?.sysSampleRate,
                backend: backend,
                vad: vad,
                locale: locale,
                progressBase: Double(filesProcessed) / Double(totalFiles),
                progressScale: 1.0 / Double(totalFiles),
                diarizationManager: sysDiarizer,
                useElevenLabsNativeDiarization: useElevenLabsNativeDiarization,
                onSpeechSegment: { start, duration in
                    sysSpeechRanges.append((start: start, end: start.addingTimeInterval(duration)))
                }
            )
            Log.batchTranscription.debug("Sys transcription: \(sysRecords.count, privacy: .public) records")
        }

        try Task.checkCancellation()

        // A diarized mic voice whose speaking time mostly coincides with
        // call-audio speech is the far side leaking out of the speakers into
        // the mic (AEC is disabled while the system tap runs). Those words are
        // already on the system channel as "them"; the mic copy is a duplicate,
        // not a participant.
        if let segments = micSpeakerSegments,
           let micStart = anchors?.micStartDate,
           anchors?.sysStartDate != nil,   // both channels need real time anchors to compare
           !sysSpeechRanges.isEmpty {
            let echoIndices = Self.callEchoSpeakerIndices(
                micSpeakerSegments: segments,
                micStartDate: micStart,
                sysSpeechRanges: sysSpeechRanges,
                excluding: micSelfIndex
            )
            if !echoIndices.isEmpty {
                let before = micRecords.count
                if segments.count == 1, micSelfIndex == nil {
                    // A single diarized mic voice is labeled .you throughout
                    // (single-voice collapse), so there are no lettered records
                    // to drop. If that lone voice is mostly concurrent with
                    // call audio it is the far side over the speakers, not the
                    // user: drop the mic records that start inside call-audio
                    // speech. A genuinely talking user pushes the overlap
                    // below the gate's threshold and never reaches here.
                    micRecords.removeAll { record in
                        sysSpeechRanges.contains { range in
                            record.timestamp >= range.start.addingTimeInterval(-0.3)
                                && record.timestamp <= range.end.addingTimeInterval(0.3)
                        }
                    }
                } else {
                    let echoSpeakers = Set(echoIndices.map { Speaker.local($0 + 1) })
                    micRecords.removeAll { echoSpeakers.contains($0.speaker) }
                }
                Log.batchTranscription.info("Dropped \(before - micRecords.count, privacy: .public) mic records from \(echoIndices.count, privacy: .public) diarized voice(s) identified as call-audio echo")
            }
        }
        if let selfIndex = micSelfIndex {
            micRecords = Self.relabelSelfSpeaker(in: micRecords, selfIndex: selfIndex)
        } else {
            micRecords = Self.reletterLocalSpeakers(in: micRecords)
        }

        // Apply echo suppression
        AcousticEchoFilter.suppress(micRecords: &micRecords, against: sysRecords)

        // Interleave by timestamp
        var allRecords = micRecords + sysRecords
        allRecords.sort { $0.timestamp < $1.timestamp }
        let existingRecords = await sessionRepository.loadTranscript(sessionID: sessionID)

        guard !allRecords.isEmpty else {
            Log.batchTranscription.warning("Batch transcription produced no records for \(sessionID, privacy: .public)")
            if existingRecords.isEmpty {
                DiagnosticsSupport.record(category: "batch", message: "Batch transcription produced no speech for \(sessionID)")
                status = .failed("Batch re-transcription produced no speech")
            } else {
                DiagnosticsSupport.record(category: "batch", message: "Batch transcription produced no speech for \(sessionID); kept existing transcript")
                status = .failed("Batch re-transcription produced no speech; kept existing transcript")
            }
            return
        }

        if let rejectionReason = BatchTranscriptOverwriteGuard.rejectionReason(
            existingRecords: existingRecords,
            replacementRecords: allRecords
        ) {
            Log.batchTranscription.warning(
                "Skipping batch transcript overwrite for \(sessionID, privacy: .public): \(rejectionReason, privacy: .public)"
            )
            DiagnosticsSupport.record(category: "batch", message: "Rejected batch overwrite for \(sessionID): \(rejectionReason)")
            status = .failed(rejectionReason)
            return
        }

        // Atomic write of final transcript + full markdown regeneration via mirroring
        await sessionRepository.saveFinalTranscript(
            sessionID: sessionID,
            records: allRecords,
            backupCurrentTranscript: true,
            markAsRecoveredIfIssuePresent: true
        )
        // Retain batch stems/metadata for a bounded rerun/debug window.
        // SessionRepository purges expired retained assets on startup.

        status = .completed(sessionID: sessionID)
        DiagnosticsSupport.record(category: "batch", message: "Batch transcription completed for \(sessionID) records=\(allRecords.count)")
        Log.batchTranscription.info("Batch transcription completed for \(sessionID, privacy: .public): \(allRecords.count, privacy: .public) records")
    }

    // MARK: - File Transcription

    private func transcribeFile(
        url: URL,
        speaker: Speaker,
        startDate: Date?,
        sampleRate: Double?,
        backend: any TranscriptionBackend,
        vad: VadManager,
        locale: Locale,
        progressBase: Double,
        progressScale: Double,
        diarizationManager: DiarizationManager? = nil,
        diarizationChannel: DiarizationManager.Channel = .system,
        useElevenLabsNativeDiarization: Bool = false,
        onSpeechSegment: ((Date, TimeInterval) -> Void)? = nil
    ) async throws -> [SessionRecord] {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            Log.batchTranscription.warning("Cannot open audio file: \(url.lastPathComponent, privacy: .public)")
            return []
        }

        let fileSampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = audioFile.length
        guard totalFrames > 0 else { return [] }

        let resolvedStartDate = startDate ?? Date()
        let resolvedSampleRate = sampleRate ?? fileSampleRate

        // Process in 30-second chunks
        let chunkFrames = Int64(30.0 * resolvedSampleRate)
        var records: [SessionRecord] = []
        var frameOffset: Int64 = 0

        while frameOffset < totalFrames {
            try Task.checkCancellation()

            let framesToRead = min(chunkFrames, totalFrames - frameOffset)
            let chunk = try readChunk(
                file: audioFile,
                startFrame: frameOffset,
                frameCount: AVAudioFrameCount(framesToRead),
                overrideSampleRate: sampleRate
            )

            guard !chunk.isEmpty else {
                frameOffset += framesToRead
                continue
            }

            // Run VAD on the chunk to find speech segments
            let speechSegments = try await detectSpeech(samples: chunk, vad: vad)

            for segment in speechSegments {
                try Task.checkCancellation()
                let sampleOffsetInFile = Double(frameOffset) + Double(segment.startSample) * resolvedSampleRate / 16000.0
                let segmentStartTime = sampleOffsetInFile / resolvedSampleRate
                let segmentDuration = Double(segment.samples.count) / 16000.0
                let segmentEndTime = segmentStartTime + segmentDuration
                onSpeechSegment?(resolvedStartDate.addingTimeInterval(segmentStartTime), segmentDuration)

                if useElevenLabsNativeDiarization,
                   let elevenLabsBackend = backend as? ElevenLabsScribeBackend
                {
                    let result = try await elevenLabsBackend.transcribeDiarized(
                        segment.samples,
                        locale: locale,
                        previousContext: nil
                    )
                    let diarizedRecords = makeRecords(
                        from: result,
                        fallbackSpeaker: speaker,
                        baseTimestamp: resolvedStartDate.addingTimeInterval(segmentStartTime)
                    )
                    records.append(contentsOf: diarizedRecords)
                    continue
                }

                let slices: [BatchTranscriptionSegmentLayout.Slice]
                if let dm = diarizationManager {
                    let fallbackSpeaker = await dm.dominantSpeaker(
                        from: segmentStartTime,
                        to: segmentEndTime,
                        channel: diarizationChannel
                    )
                    let diarizedRuns = await dm.speakerRuns(
                        from: segmentStartTime,
                        to: segmentEndTime,
                        channel: diarizationChannel
                    )
                    slices = BatchTranscriptionSegmentLayout.slices(
                        for: .init(
                            startTime: segmentStartTime,
                            endTime: segmentEndTime,
                            sampleRate: 16_000
                        ),
                        diarizedRuns: diarizedRuns,
                        fallbackSpeaker: fallbackSpeaker
                    )
                } else {
                    slices = [
                        BatchTranscriptionSegmentLayout.Slice(
                            speaker: speaker,
                            startSample: 0,
                            sampleCount: segment.samples.count
                        )
                    ]
                }

                for slice in slices {
                    let rangeEnd = min(segment.samples.count, slice.startSample + slice.sampleCount)
                    guard slice.startSample < rangeEnd else { continue }
                    var sliceSamples = Array(segment.samples[slice.startSample..<rangeEnd])
                    // Parakeet rejects clips under 1 s outright, and diarized
                    // speaker runs (min 0.8 s) and VAD segments (min 0.5 s) can
                    // both be shorter. Pad with trailing silence instead of
                    // letting one short slice fail the whole batch.
                    let minimumSampleCount = 16_000
                    if sliceSamples.count < minimumSampleCount {
                        sliceSamples.append(
                            contentsOf: [Float](repeating: 0, count: minimumSampleCount - sliceSamples.count)
                        )
                    }
                    let text = try await backend.transcribe(sliceSamples, locale: locale, previousContext: nil)
                    guard !text.isEmpty else { continue }

                    let timestamp = resolvedStartDate.addingTimeInterval(
                        segmentStartTime + (Double(slice.startSample) / 16_000.0)
                    )

                    records.append(SessionRecord(
                        speaker: slice.speaker,
                        text: text,
                        timestamp: timestamp
                    ))
                }
            }

            frameOffset += framesToRead

            // Update progress
            let fileProgress = Double(frameOffset) / Double(totalFrames)
            status = .transcribing(progress: progressBase + fileProgress * progressScale)
        }

        return records
    }

    private func makeRecords(
        from result: ElevenLabsScribeBackend.TranscriptResult,
        fallbackSpeaker: Speaker,
        baseTimestamp: Date
    ) -> [SessionRecord] {
        if result.segments.isEmpty {
            guard !result.text.isEmpty else { return [] }
            return [
                SessionRecord(
                    speaker: fallbackSpeaker,
                    text: result.text,
                    timestamp: baseTimestamp
                )
            ]
        }

        return result.segments.map { segment in
            SessionRecord(
                speaker: segment.speaker,
                text: segment.text,
                timestamp: baseTimestamp.addingTimeInterval(segment.startTime)
            )
        }
    }

    /// Rewrite the diarized speaker matched to the enrolled voiceprint as .you,
    /// and reletter the remaining in-person speakers contiguously so guests
    /// always start at Speaker A.
    private static func relabelSelfSpeaker(in records: [SessionRecord], selfIndex: Int) -> [SessionRecord] {
        let selfSpeaker = Speaker.local(selfIndex + 1)
        let remaining = Set(
            records.compactMap { record -> Int? in
                guard case .local(let n) = record.speaker, record.speaker != selfSpeaker else { return nil }
                return n
            }
        ).sorted()

        var mapping: [Speaker: Speaker] = [selfSpeaker: .you]
        for (offset, n) in remaining.enumerated() {
            mapping[.local(n)] = .local(offset + 1)
        }

        return records.map { record in
            guard let mapped = mapping[record.speaker], mapped != record.speaker else { return record }
            return record.withSpeaker(mapped)
        }
    }

    /// Reletter surviving .local speakers contiguously (Speaker A, B, ...)
    /// after echo removal, so the first guest is always Speaker A.
    static func reletterLocalSpeakers(in records: [SessionRecord]) -> [SessionRecord] {
        let remaining = Set(
            records.compactMap { record -> Int? in
                guard case .local(let n) = record.speaker else { return nil }
                return n
            }
        ).sorted()

        var mapping: [Speaker: Speaker] = [:]
        for (offset, n) in remaining.enumerated() where n != offset + 1 {
            mapping[.local(n)] = .local(offset + 1)
        }
        guard !mapping.isEmpty else { return records }

        return records.map { record in
            guard let mapped = mapping[record.speaker] else { return record }
            return record.withSpeaker(mapped)
        }
    }

    /// Indices of diarized mic speakers whose speech overlaps call-audio
    /// speech for at least half their total speaking time. The far side of a
    /// call playing over the speakers reaches the mic almost exclusively while
    /// the system channel also has speech; a person in the room does not.
    static func callEchoSpeakerIndices(
        micSpeakerSegments: [Int: [DiarizationManager.SpeakerSegment]],
        micStartDate: Date,
        sysSpeechRanges: [(start: Date, end: Date)],
        excluding selfIndex: Int?
    ) -> [Int] {
        let overlapThreshold = 0.5
        // Absorbs channel anchor drift and speaker-to-mic propagation delay.
        let tolerance: TimeInterval = 0.3

        var echoes: [Int] = []
        for (index, segments) in micSpeakerSegments {
            if index == selfIndex { continue }
            var total: TimeInterval = 0
            var overlap: TimeInterval = 0
            for segment in segments {
                let duration = TimeInterval(segment.end - segment.start)
                guard duration > 0 else { continue }
                total += duration
                let start = micStartDate.addingTimeInterval(TimeInterval(segment.start))
                let end = micStartDate.addingTimeInterval(TimeInterval(segment.end))
                for range in sysSpeechRanges {
                    let overlapStart = max(start, range.start.addingTimeInterval(-tolerance))
                    let overlapEnd = min(end, range.end.addingTimeInterval(tolerance))
                    if overlapEnd > overlapStart {
                        overlap += overlapEnd.timeIntervalSince(overlapStart)
                    }
                }
            }
            guard total > 0 else { continue }
            if overlap / total >= overlapThreshold {
                echoes.append(index)
            }
        }
        return echoes.sorted()
    }

    // MARK: - Audio Reading

    /// Read a chunk from an AVAudioFile and resample to 16kHz mono Float32.
    private func readChunk(
        file: AVAudioFile,
        startFrame: Int64,
        frameCount: AVAudioFrameCount,
        overrideSampleRate: Double? = nil
    ) throws -> [Float] {
        file.framePosition = startFrame
        return try BatchAudioSampleReader.readChunk(
            from: file,
            frameCount: frameCount,
            targetRate: 16000,
            overrideSampleRate: overrideSampleRate
        )
    }

    // MARK: - VAD

    private struct SpeechSegment {
        let startSample: Int
        let samples: [Float]
    }

    /// Detect speech segments in a chunk of 16kHz mono audio using Silero VAD.
    private func detectSpeech(samples: [Float], vad: VadManager) async throws -> [SpeechSegment] {
        let vadChunkSize = 4096
        let minimumSpeechSamples = 8000

        var vadState = await vad.makeStreamState()
        var segments: [SpeechSegment] = []
        var speechBuffer: [Float] = []
        var speechStart: Int?
        var offset = 0

        while offset + vadChunkSize <= samples.count {
            try Task.checkCancellation()

            let chunk = Array(samples[offset..<(offset + vadChunkSize)])

            let result = try await vad.processStreamingChunk(
                chunk,
                state: vadState,
                config: .default,
                returnSeconds: true,
                timeResolution: 2
            )
            vadState = result.state

            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    if speechStart == nil {
                        speechStart = offset
                        speechBuffer = []
                    }
                case .speechEnd:
                    if speechStart != nil {
                        speechBuffer.append(contentsOf: chunk)
                        if speechBuffer.count >= minimumSpeechSamples {
                            segments.append(SpeechSegment(
                                startSample: speechStart!,
                                samples: speechBuffer
                            ))
                        }
                        speechStart = nil
                        speechBuffer = []
                    }
                }
            }

            if speechStart != nil {
                speechBuffer.append(contentsOf: chunk)
            }

            offset += vadChunkSize
        }

        // Flush remaining speech
        if let start = speechStart, speechBuffer.count >= minimumSpeechSamples {
            segments.append(SpeechSegment(startSample: start, samples: speechBuffer))
        }

        return segments
    }

    // MARK: - Batch Meta

    private struct ResolvedAnchors {
        let micStartDate: Date?
        let sysStartDate: Date?
        let micSampleRate: Double?
        let sysSampleRate: Double?
    }

    private func loadBatchMeta(
        sessionID: String,
        sessionRepository: SessionRepository
    ) async -> ResolvedAnchors? {
        guard let meta = await sessionRepository.loadBatchMeta(sessionID: sessionID) else {
            return nil
        }

        return ResolvedAnchors(
            micStartDate: meta.micStartDate,
            sysStartDate: meta.sysStartDate,
            micSampleRate: nil,
            sysSampleRate: meta.sysEffectiveSampleRate
        )
    }

}

enum BatchAudioSampleReader {
    static func readAll(
        url: URL,
        targetRate: Double,
        overrideSampleRate: Double? = nil
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }
        file.framePosition = 0
        return try readChunk(
            from: file,
            frameCount: AVAudioFrameCount(file.length),
            targetRate: targetRate,
            overrideSampleRate: overrideSampleRate
        )
    }

    static func readChunk(
        from file: AVAudioFile,
        frameCount: AVAudioFrameCount,
        targetRate: Double,
        overrideSampleRate: Double? = nil
    ) throws -> [Float] {
        let srcFormat = file.processingFormat
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: readBuf)
        return resample(readBuf, targetRate: targetRate, overrideSampleRate: overrideSampleRate)
    }

    static func resample(
        _ readBuf: AVAudioPCMBuffer,
        targetRate: Double,
        overrideSampleRate: Double? = nil
    ) -> [Float] {
        let srcFormat = readBuf.format
        guard readBuf.frameLength > 0 else { return [] }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        )!

        if overrideSampleRate == nil,
           srcFormat.sampleRate == targetRate,
           srcFormat.channelCount == 1,
           srcFormat.commonFormat == .pcmFormatFloat32
        {
            return extractSamples(from: readBuf)
        }

        let converterInput: AVAudioPCMBuffer
        let converterSrcFormat: AVAudioFormat
        if let overrideSampleRate, overrideSampleRate != srcFormat.sampleRate {
            guard let retaggedFormat = AVAudioFormat(
                commonFormat: srcFormat.commonFormat,
                sampleRate: overrideSampleRate,
                channels: srcFormat.channelCount,
                interleaved: srcFormat.isInterleaved
            ),
            let retaggedBuffer = AVAudioPCMBuffer(
                pcmFormat: retaggedFormat,
                frameCapacity: readBuf.frameCapacity
            )
            else {
                return extractMonoSamples(from: readBuf)
            }
            retaggedBuffer.frameLength = readBuf.frameLength
            if let src = readBuf.floatChannelData, let dst = retaggedBuffer.floatChannelData {
                for ch in 0..<Int(srcFormat.channelCount) {
                    memcpy(dst[ch], src[ch], Int(readBuf.frameLength) * MemoryLayout<Float>.size)
                }
            }
            converterInput = retaggedBuffer
            converterSrcFormat = retaggedFormat
        } else {
            converterInput = readBuf
            converterSrcFormat = srcFormat
        }

        guard let converter = AVAudioConverter(from: converterSrcFormat, to: targetFormat) else {
            return extractMonoSamples(from: converterInput)
        }

        let ratio = targetRate / converterSrcFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(converterInput.frameLength) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
            return []
        }

        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let inputRef = converterInput
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputRef
        }

        return extractSamples(from: outBuf)
    }

    private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: count))
    }

    private static func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData else { return [] }
        let channels = Int(buffer.format.channelCount)
        if channels <= 1 { return extractSamples(from: buffer) }

        let scale = 1.0 / Float(channels)
        return (0..<count).map { i in
            var sum: Float = 0
            for ch in 0..<channels { sum += data[ch][i] }
            return sum * scale
        }
    }
}

// MARK: - JSONDecoder Extension

extension JSONDecoder {
    static let iso8601Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
