import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os

/// Enriched download progress info computed from fraction changes over time.
struct DownloadProgressDetail: Sendable {
    let fraction: Double
    /// Formatted string like "142 MB / 800 MB"
    let sizeText: String?
    /// Formatted string like "3.5 MB/s"
    let speedText: String?
    /// Formatted string like "2m 15s remaining"
    let etaText: String?
}

/// Session-scoped transcription settings captured at start time.
struct ActiveTranscriptionSession: Sendable, Equatable {
    let sessionID: String?
    let transcriptionModel: TranscriptionModel

    init(sessionID: String? = nil, transcriptionModel: TranscriptionModel) {
        self.sessionID = sessionID
        self.transcriptionModel = transcriptionModel
    }

    var flushIntervalSamples: Int {
        transcriptionModel.flushIntervalSamples
    }

    func clearModelCache(
        using makeBackend: (TranscriptionModel) -> any TranscriptionBackend = { $0.makeBackend() }
    ) {
        makeBackend(transcriptionModel).clearModelCache()
    }
}

/// Stops forwarding diarization samples after the first feed failure.
struct DiarizationFeedRelay: Sendable {
    private(set) var hasFailed = false

    mutating func feedAudio(
        _ samples: [Float],
        into feedAudio: @Sendable ([Float]) async throws -> Void,
        onFailure: @Sendable (Error) async -> Void
    ) async {
        guard !hasFailed else { return }

        do {
            try await feedAudio(samples)
        } catch {
            hasFailed = true
            await onFailure(error)
        }
    }
}

struct CaptureHealthSnapshot: Sendable, Equatable {
    let micHasCapturedFrames: Bool
    let systemHasCapturedFrames: Bool
    let micCaptureError: String?
}

/// Orchestrates dual StreamingTranscriber instances for mic (you) and system audio (them).
@Observable
@MainActor
final class TranscriptionEngine {
    struct StartPreflightIssue: Equatable {
        let message: String
    }

    enum MicStartupHealthAction: Equatable {
        case none
        case retryCapture
        case showNoAudioError
    }

    private struct PreparedCloudStartBackend {
        let model: TranscriptionModel
        let backend: any TranscriptionBackend
    }

    enum Mode {
        case live
        case scripted([Utterance])
    }

    // These properties are read from SwiftUI body during view evaluation.
    // SwiftUI's ViewBodyAccessor doesn't carry MainActor executor context
    // in Swift 6.2, so @MainActor-isolated @Observable properties trigger
    // a failing runtime check in SerialExecutor.isMainExecutor.getter
    // (EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE).
    //
    // We use @ObservationIgnored nonisolated(unsafe) backing storage with
    // manual observation tracking to bypass the MainActor check while
    // keeping SwiftUI reactivity. Mutations only happen on MainActor.
    @ObservationIgnored nonisolated(unsafe) private var _isRunning = false
    var isRunning: Bool {
        get { access(keyPath: \.isRunning); return _isRunning }
        set { withMutation(keyPath: \.isRunning) { _isRunning = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _assetStatus: String = "Ready"
    var assetStatus: String {
        get { access(keyPath: \.assetStatus); return _assetStatus }
        set { withMutation(keyPath: \.assetStatus) { _assetStatus = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _lastError: String?
    var lastError: String? {
        get { access(keyPath: \.lastError); return _lastError }
        set { withMutation(keyPath: \.lastError) { _lastError = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _liveCloudTranscriptIssue: CloudTranscriptCopy.Presentation?
    var liveCloudTranscriptIssue: CloudTranscriptCopy.Presentation? {
        get { access(keyPath: \.liveCloudTranscriptIssue); return _liveCloudTranscriptIssue }
        set { withMutation(keyPath: \.liveCloudTranscriptIssue) { _liveCloudTranscriptIssue = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _liveCloudTranscriptionIsProcessing = false
    var liveCloudTranscriptionIsProcessing: Bool {
        get { access(keyPath: \.liveCloudTranscriptionIsProcessing); return _liveCloudTranscriptionIsProcessing }
        set { withMutation(keyPath: \.liveCloudTranscriptionIsProcessing) { _liveCloudTranscriptionIsProcessing = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _needsModelDownload = false
    var needsModelDownload: Bool {
        get { access(keyPath: \.needsModelDownload); return _needsModelDownload }
        set { withMutation(keyPath: \.needsModelDownload) { _needsModelDownload = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _downloadConfirmed = false
    var downloadConfirmed: Bool {
        get { access(keyPath: \.downloadConfirmed); return _downloadConfirmed }
        set { withMutation(keyPath: \.downloadConfirmed) { _downloadConfirmed = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _downloadProgress: Double?
    /// Fraction complete (0…1) during model download, nil when not downloading.
    var downloadProgress: Double? {
        get { access(keyPath: \.downloadProgress); return _downloadProgress }
        set { withMutation(keyPath: \.downloadProgress) { _downloadProgress = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _downloadDetail: DownloadProgressDetail?
    var downloadDetail: DownloadProgressDetail? {
        get { access(keyPath: \.downloadDetail); return _downloadDetail }
        set { withMutation(keyPath: \.downloadDetail) { _downloadDetail = newValue } }
    }

    // Progress tracking state (not observed)
    @ObservationIgnored private var downloadStartTime: Date?
    @ObservationIgnored private var downloadTotalBytes: Int64?

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let transcriptStore: TranscriptStore
    private let settings: AppSettings
    private let mode: Mode

    /// Combined audio level (mic + system) for the UI meter.
    /// Per-channel levels for live-lag detection: a channel with audible
    /// speech whose transcript side has stalled means live ASR is behind.
    nonisolated var micAudioLevel: Float { micCapture.audioLevel }
    nonisolated var systemAudioLevel: Float { systemCapture.audioLevel }

    /// nonisolated is safe here — both audioLevel properties are thread-safe (NSLock).
    nonisolated var audioLevel: Float {
        switch mode {
        case .live:
            max(micCapture.audioLevel, systemCapture.audioLevel)
        case .scripted:
            _isRunning ? 0.35 : 0
        }
    }

    /// Mute/unmute the microphone. When muted, mic audio is not transcribed
    /// and the audio level reads as 0. System audio continues normally.
    nonisolated var isMicMuted: Bool {
        get { micCapture.isMuted }
        set { micCapture.isMuted = newValue }
    }

    /// Pause/resume all recording. When paused, neither mic nor system audio
    /// is transcribed and audio levels read as 0.
    nonisolated var isRecordingPaused: Bool {
        get { micCapture.isPaused }
        set {
            micCapture.isPaused = newValue
            systemCapture.isPaused = newValue
        }
    }

    nonisolated var captureHealthSnapshot: CaptureHealthSnapshot {
        CaptureHealthSnapshot(
            micHasCapturedFrames: micCapture.hasCapturedFrames,
            systemHasCapturedFrames: systemCapture.hasCapturedFrames,
            micCaptureError: micCapture.captureError
        )
    }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?

    /// Incremented when a session ends. Live-transcriber callbacks capture the
    /// epoch at creation and are dropped if it changed, so a transcriber that
    /// outlives its session (abandoned wedged teardown, late XPC results)
    /// cannot append into an idle store or the next session's transcript.
    private var liveEpoch = 0
    /// Keeps the mic stream alive for the audio level meter when transcription isn't running.
    private var micKeepAliveTask: Task<Void, Never>?

    /// Separate backend instances for mic and system audio.
    /// Parakeet keeps mutable decoder state per manager, so mic and system audio
    /// need separate instances even when they share the same loaded model files.
    private var micBackend: (any TranscriptionBackend)?
    private var systemBackend: (any TranscriptionBackend)?
    private var vadManager: VadManager?

    /// Audio recorder for tapping streams (set by ContentView when recording is enabled).
    var audioRecorder: AudioRecorder?

    /// Speaker diarization manager for system audio (nil when diarization is disabled).
    private var diarizationManager: DiarizationManager?
    /// LS-EEND on the mic channel: live in-person speaker splitting.
    private var micDiarizationManager: DiarizationManager?

    /// Live "Not me" correction on a You-labeled mic utterance: marks the
    /// voice behind that time range as not the user and returns the lettered
    /// speaker its records should move to (nil when mic diarization is idle).
    func markMicVoiceNotSelf(startTime: TimeInterval, endTime: TimeInterval) async -> Speaker? {
        guard let dm = micDiarizationManager,
              let index = await dm.dominantIndex(from: startTime, to: endTime) else { return nil }
        let n = index + 1
        if let matcher = voiceMatcher {
            await matcher.markNotSelf(localSpeakerNumber: n)
        }
        return .local(n)
    }

    /// Live "This is me" on a lettered mic speaker: pins that diarized voice
    /// as the user so its lines say "You" from here on, immune to rescoring.
    func assignMicSpeakerToSelf(localSpeakerNumber n: Int) async {
        guard let matcher = voiceMatcher else { return }
        await matcher.markSelf(localSpeakerNumber: n)
    }

    /// The user assigned a name to a lettered mic speaker: stop live scoring
    /// of that voice so an auto match (or a self match folding it into "You")
    /// can't fight the manual assignment.
    func pinMicSpeakerUserAssigned(localSpeakerNumber n: Int) async {
        guard let matcher = voiceMatcher else { return }
        await matcher.markAssignedByUser(localSpeakerNumber: n)
    }

    /// The user cleared a manual name from a lettered mic speaker: reopen
    /// live scoring for that voice.
    func unpinMicSpeakerUserAssigned(localSpeakerNumber n: Int) async {
        guard let matcher = voiceMatcher else { return }
        await matcher.unpinUserAssignment(localSpeakerNumber: n)
    }
    /// Live scoring of lettered mic speakers against the enrolled voiceprint
    /// and the named speaker library.
    private var voiceMatcher: LiveVoiceMatcher?

    /// Called (on the main actor) when a live mic speaker is matched to a
    /// named voice in the speaker library: (storageKey, name). Set by the
    /// session controller so the live transcript shows the name without
    /// waiting for the batch pass.
    var onLiveSpeakerAutoNamed: ((String, String) -> Void)?
    /// "This is me" voice references from the just-ended session, exported at
    /// finalize for the batch pass (cleared on the next start).
    private(set) var lastLiveSelfReferences: [[Float]] = []

    /// Active transcription model captured for the current session/startup.
    @ObservationIgnored nonisolated(unsafe) var activeTranscriptionSession: ActiveTranscriptionSession?
    @ObservationIgnored private var preparedCloudStartBackend: PreparedCloudStartBackend?

    /// Tracks the resolved mic device ID currently in use.
    private var currentMicDeviceID: AudioDeviceID = 0

    /// Tracks whether user selected "System Default" (0) or a specific device.
    private var userSelectedDeviceID: AudioDeviceID = 0

    /// Listens for default input device changes at the OS level.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// Listens for default output device changes at the OS level.
    private var defaultOutputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var micRestartTask: Task<Void, Never>?
    private var sysRestartTask: Task<Void, Never>?
    private var pendingMicDeviceID: AudioDeviceID?
    private var pendingSystemAudioRestart = false

    init(transcriptStore: TranscriptStore, settings: AppSettings, mode: Mode = .live) {
        self.transcriptStore = transcriptStore
        self.settings = settings
        self.mode = mode
        switch mode {
        case .live:
            self.needsModelDownload = Self.modelNeedsDownload(settings.transcriptionModel)
        case .scripted:
            self.needsModelDownload = false
        }
    }

    static func micStartupHealthAction(
        hasCapturedFrames: Bool,
        captureError: String?,
        hasRetried: Bool
    ) -> MicStartupHealthAction {
        guard !hasCapturedFrames, captureError == nil else { return .none }
        return hasRetried ? .showNoAudioError : .retryCapture
    }

    func refreshModelAvailability() {
        switch mode {
        case .live:
            needsModelDownload = Self.modelNeedsDownload(settings.transcriptionModel)
        case .scripted:
            needsModelDownload = false
        }
    }

    func preflightStart(transcriptionModel: TranscriptionModel) async -> StartPreflightIssue? {
        guard case .live = mode else { return nil }

        lastError = nil
        liveCloudTranscriptIssue = nil
        liveCloudTranscriptionIsProcessing = false
        preparedCloudStartBackend = nil

        if let inputIssue = validateConfiguredInputDevice() {
            lastError = inputIssue.message
            assetStatus = "Ready"
            return inputIssue
        }

        if let outputIssue = validateConfiguredOutputDevice() {
            lastError = outputIssue.message
            assetStatus = "Ready"
            return outputIssue
        }

        guard transcriptionModel.isCloud else {
            assetStatus = "Ready"
            return nil
        }

        let apiKey = settings.cloudASRApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            let issue = StartPreflightIssue(
                message: "Missing \(transcriptionModel.displayName) API key. Check Settings > Transcription."
            )
            lastError = issue.message
            assetStatus = "Ready"
            return issue
        }

        assetStatus = "Validating \(transcriptionModel.displayName)..."

        do {
            let backend = transcriptionModel.makeBackend(
                customVocabulary: settings.transcriptionCustomVocabulary,
                apiKey: apiKey,
                removeFillerWords: settings.removeFillerWords
            )
            try await prepareBackend(backend)
            preparedCloudStartBackend = PreparedCloudStartBackend(model: transcriptionModel, backend: backend)
            assetStatus = "Ready"
            return nil
        } catch let error as CloudASRError {
            assetStatus = "Ready"
            switch error {
            case .invalidAPIKey:
                let issue = StartPreflightIssue(message: error.localizedDescription)
                lastError = issue.message
                return issue
            default:
                Log.transcription.error(
                    "Cloud start preflight validation fell back to runtime start after non-blocking error: \(error, privacy: .public)"
                )
                lastError = nil
                return nil
            }
        } catch {
            assetStatus = "Ready"
            Log.transcription.error(
                "Cloud start preflight validation fell back to runtime start after unexpected error: \(error, privacy: .public)"
            )
            lastError = nil
            return nil
        }
    }

    /// Download the model without starting a transcription session.
    func downloadModelOnly(transcriptionModel: TranscriptionModel) async {
        guard !isRunning, downloadProgress == nil else { return }

        refreshModelAvailability()
        guard needsModelDownload else { return }

        lastError = nil
        liveCloudTranscriptIssue = nil
        liveCloudTranscriptionIsProcessing = false
        assetStatus = "Downloading \(transcriptionModel.displayName)..."
        beginDownloadTracking(for: transcriptionModel)

        let vocab = settings.transcriptionCustomVocabulary
        let backend = transcriptionModel.makeBackend(
            customVocabulary: vocab,
            localeIdentifier: settings.transcriptionLocale
        )
        do {
            try await prepareBackend(backend)
            needsModelDownload = false
            downloadConfirmed = false
            clearDownloadTracking()
            assetStatus = "Ready"
        } catch is CancellationError {
            clearDownloadTracking()
            assetStatus = "Ready"
        } catch {
            lastError = "Failed to download: \(error.localizedDescription)"
            assetStatus = "Ready"
            clearDownloadTracking()
            transcriptionModel.makeBackend().clearModelCache()
            needsModelDownload = true
        }
    }

    func start(
        locale: Locale,
        inputDeviceID: AudioDeviceID = 0,
        transcriptionModel: TranscriptionModel,
        sessionID: String? = nil
    ) async {
        Log.transcription.info("start() called, isRunning=\(self.isRunning, privacy: .public)")
        guard !isRunning, downloadProgress == nil else { return }
        lastError = nil
        lastLiveSelfReferences = []
        liveCloudTranscriptIssue = nil
        liveCloudTranscriptionIsProcessing = false
        refreshModelAvailability()

        if case .scripted(let scriptedUtterances) = mode {
            downloadConfirmed = false
            assetStatus = "Transcribing (UI Test)"
            isRunning = true
            for utterance in scriptedUtterances {
                transcriptStore.append(utterance)
            }
            return
        }

        if let localeMismatchMessage = localeMismatchMessage(
            for: locale,
            transcriptionModel: transcriptionModel
        ) {
            lastError = localeMismatchMessage
            assetStatus = "Ready"
            return
        }

        // Block start if models need downloading and user hasn't confirmed
        if needsModelDownload && !downloadConfirmed {
            return
        }

        activeTranscriptionSession = ActiveTranscriptionSession(
            sessionID: sessionID,
            transcriptionModel: transcriptionModel
        )

        guard await ensureMicrophonePermission() else {
            activeTranscriptionSession = nil
            return
        }

        isRunning = true

        // 1. Load transcription models via backend protocol
        let isDownloading = needsModelDownload
        assetStatus = isDownloading
            ? "Downloading \(transcriptionModel.displayName)..."
            : "Loading \(transcriptionModel.displayName)..."
        if isDownloading {
            beginDownloadTracking(for: transcriptionModel)
        }
        Log.transcription.info("Loading transcription model \(transcriptionModel.rawValue, privacy: .public)")
        do {
            let vocab = settings.transcriptionCustomVocabulary
            let apiKey = settings.cloudASRApiKey
            let noFiller = settings.removeFillerWords
            let mic: any TranscriptionBackend
            if transcriptionModel.isCloud,
               let preparedCloudStartBackend,
               preparedCloudStartBackend.model == transcriptionModel {
                mic = preparedCloudStartBackend.backend
                self.preparedCloudStartBackend = nil
            } else {
                mic = transcriptionModel.makeBackend(
                    customVocabulary: vocab,
                    apiKey: apiKey,
                    removeFillerWords: noFiller,
                    localeIdentifier: settings.transcriptionLocale
                )
                try await prepareBackend(mic)
            }
            self.micBackend = mic

            // Parakeet needs a separate backend for system audio (mutable decoder state).
            // Apple Speech is stateless per call (the live path builds its own
            // analyzers), so one shared backend is fine.
            if transcriptionModel == .appleSpeech || transcriptionModel.isCloud {
                self.systemBackend = mic
            } else {
                let sys = transcriptionModel.makeBackend(customVocabulary: vocab, apiKey: apiKey, removeFillerWords: noFiller)
                try await sys.prepare { _ in }
                self.systemBackend = sys
            }

            assetStatus = "Loading VAD model..."
            Log.transcription.info("Loading VAD model")
            let vad = try await VadManager()
            self.vadManager = vad

            // Optionally load speaker diarization model
            if settings.enableDiarization {
                assetStatus = "Loading diarization model..."
                Log.transcription.info("Loading LS-EEND diarization model")
                let dm = DiarizationManager()
                let variant = settings.diarizationVariant.lseendVariant
                try await dm.load(variant: variant)
                self.diarizationManager = dm
                Log.transcription.info("Diarization model loaded")
            } else {
                self.diarizationManager = nil
            }

            // Mic-channel diarization: live in-person speaker splitting, with
            // voiceprint self-recognition when a profile is enrolled. Runs its
            // own LS-EEND instance (streaming state is per-channel).
            if settings.enableMicDiarization {
                assetStatus = "Loading in-person diarization model..."
                Log.transcription.info("Loading LS-EEND mic diarization model")
                let dm = DiarizationManager()
                let variant = settings.diarizationVariant.lseendVariant
                try await dm.load(variant: variant)
                self.micDiarizationManager = dm
                let voiceprint = VoiceprintStore.load()?.embedding
                let libraryProfiles = SpeakerLibraryStore.load()
                // Always created while mic diarization is on: even with no
                // voiceprint and an empty library it carries the user's
                // "This is me" / manual-name pins. With nothing to match it
                // never scores audio (classifyUtterance's canScore guard).
                self.voiceMatcher = LiveVoiceMatcher(
                    voiceprint: voiceprint, profiles: libraryProfiles
                )
                Log.transcription.info("Mic diarization model loaded")
            } else {
                self.micDiarizationManager = nil
                self.voiceMatcher = nil
            }

            needsModelDownload = false
            downloadConfirmed = false
            clearDownloadTracking()
            assetStatus = "Models ready"
            Log.transcription.info("Transcription model loaded")
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            Log.transcription.error("Failed to load models: \(error, privacy: .public)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            clearDownloadTracking()
            // Clear corrupt cache so the next attempt triggers a fresh download.
            // Cloud models don't have local caches or download flows.
            if !transcriptionModel.isCloud {
                activeTranscriptionSession?.clearModelCache()
                Log.transcription.info(
                    "Cleared model cache for \(transcriptionModel.rawValue, privacy: .public)"
                )
                needsModelDownload = true
            }
            downloadConfirmed = false
            activeTranscriptionSession = nil
            return
        }

        guard let vadManager else {
            activeTranscriptionSession = nil
            return
        }

        // A stop that raced this start (finalize flips isRunning false while
        // models were loading) must abort here: continuing would start capture
        // for a session that already ended — a hot mic behind an idle UI, and
        // an engine that then refuses every future start.
        guard isRunning, !Task.isCancelled else {
            Log.transcription.info("start() aborted: session ended during model loading")
            micBackend = nil
            systemBackend = nil
            self.vadManager = nil
            diarizationManager = nil
            micDiarizationManager = nil
            voiceMatcher = nil
            onLiveSpeakerAutoNamed = nil
            activeTranscriptionSession = nil
            assetStatus = "Ready"
            isRunning = false
            return
        }

        // 2. Start mic capture
        userSelectedDeviceID = inputDeviceID
        guard let targetMicID = resolvedMicDeviceID(for: inputDeviceID) else {
            let msg = unavailableMicMessage(for: inputDeviceID)
            Log.transcription.error("Mic unavailable: \(msg, privacy: .public)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            activeTranscriptionSession = nil
            return
        }
        currentMicDeviceID = targetMicID
        // AEC (voice processing) historically conflicted with the system tap:
        // VPIO's default ducking silences other audio (≈ -50 dB on the tap) and
        // aggregate-device reconfiguration could stall the mic stream. MicCapture
        // now disables ducking when enabling voice processing, which is the
        // documented fix for tap coexistence. Honor the user setting; the 5 s
        // no-audio health check below retries without AEC if capture stalls.
        let useAEC = settings.enableEchoCancellation
        if useAEC {
            Log.transcription.info("AEC enabled (voice processing with ducking disabled)")
        }

        Log.transcription.info("Starting mic capture, targetMicID=\(targetMicID, privacy: .public), aec=\(useAEC, privacy: .public)")
        startMicStream(
            locale: locale,
            vadManager: vadManager,
            deviceID: targetMicID,
            echoCancellation: useAEC
        )

        // Check for immediate mic capture failure
        if let micError = micCapture.captureError {
            Log.transcription.error("Mic capture error: \(micError, privacy: .public)")
            lastError = micError
        }

        // Health check: if mic produces no audio within 5 seconds, retry once.
        // This covers first-start device initialization races that users otherwise fix by stopping/restarting.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.isRunning else { return }

            switch Self.micStartupHealthAction(
                hasCapturedFrames: self.micCapture.hasCapturedFrames,
                captureError: self.micCapture.captureError,
                hasRetried: false
            ) {
            case .none:
                return
            case .showNoAudioError:
                Log.transcription.error("No mic audio after 5s")
                self.lastError = "Microphone is not producing audio. Check your input device in System Settings."
            case .retryCapture:
                Log.transcription.error("No mic audio after 5s, retrying mic capture once")
                self.micCapture.finishStream()
                if await Self.awaitTeardown(of: [self.micTask].compactMap { $0 }, timeoutSeconds: 10) == false {
                    Log.transcription.error("Mic transcriber teardown timed out during startup retry; abandoning")
                    self.micTask?.cancel()
                }
                self.micTask = nil
                self.micCapture.stop()
                self.startMicStream(
                    locale: locale,
                    vadManager: vadManager,
                    deviceID: targetMicID,
                    echoCancellation: false
                )

                try? await Task.sleep(for: .seconds(5))
                guard self.isRunning else { return }
                if let micError = self.micCapture.captureError {
                    Log.transcription.error("Mic capture error after retry: \(micError, privacy: .public)")
                    self.lastError = micError
                    return
                }
                if Self.micStartupHealthAction(
                    hasCapturedFrames: self.micCapture.hasCapturedFrames,
                    captureError: self.micCapture.captureError,
                    hasRetried: true
                ) == .showNoAudioError {
                    Log.transcription.error("No mic audio after retry")
                    self.lastError = "Microphone is not producing audio. Check your input device in System Settings."
                }
            }
        }

        // 3. Start system audio capture
        await startSystemAudioStream(locale: locale, vadManager: vadManager)

        // Same race, later window: a stop that landed while the system tap was
        // starting already tore down what existed then; nothing started after
        // may outlive it.
        guard isRunning, !Task.isCancelled else {
            Log.transcription.info("start() aborted: session ended during capture startup")
            micTask?.cancel()
            sysTask?.cancel()
            micCapture.finishStream()
            systemCapture.finishStream()
            micTask = nil
            sysTask = nil
            micCapture.stop()
            Task { await self.systemCapture.stop() }
            activeTranscriptionSession = nil
            assetStatus = "Ready"
            isRunning = false
            return
        }

        assetStatus = "Transcribing (\(micBackend?.displayName ?? transcriptionModel.displayName))"
        Log.transcription.info("All transcription tasks started")

        // Install CoreAudio listeners for live device routing changes
        installDefaultDeviceListener()
        installDefaultOutputDeviceListener()
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value (0 = system default, or a specific AudioDeviceID).
    func restartMic(inputDeviceID: AudioDeviceID) {
        if case .scripted = mode { return }
        guard isRunning else { return }
        pendingMicDeviceID = inputDeviceID

        if micRestartTask != nil {
            Log.transcription.info("Queued mic restart for device \(inputDeviceID, privacy: .public)")
            return
        }

        micRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.micRestartTask = nil }

            while self.isRunning, let requestedDeviceID = self.pendingMicDeviceID {
                self.pendingMicDeviceID = nil
                await self.performMicRestart(inputDeviceID: requestedDeviceID)
            }
        }
    }

    // MARK: - Default Device Listener

    private func installDefaultDeviceListener() {
        guard defaultDeviceListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning, self.userSelectedDeviceID == 0 else { return }
                self.restartMic(inputDeviceID: 0)
            }
        }
        defaultDeviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultDeviceListenerBlock = nil
    }

    private func installDefaultOutputDeviceListener() {
        guard defaultOutputDeviceListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning else { return }
                self.restartSystemAudio()
            }
        }
        defaultOutputDeviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDefaultOutputDeviceListener() {
        guard let block = defaultOutputDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultOutputDeviceListenerBlock = nil
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                lastError = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
                assetStatus = "Ready"
            }
            return granted
        case .denied, .restricted:
            lastError = "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
            assetStatus = "Ready"
            return false
        @unknown default:
            lastError = "Unable to verify microphone permission."
            assetStatus = "Ready"
            return false
        }
    }

    func finalize() async {
        if case .scripted = mode {
            isRunning = false
            assetStatus = "Ready"
            transcriptStore.volatileYouText = ""
            transcriptStore.volatileThemText = ""
            activeTranscriptionSession = nil
            return
        }

        // The live status otherwise reads "Transcribing (…)" until teardown
        // completes, which looks like a stuck transcription during stop.
        assetStatus = "Finishing up..."

        removeDefaultDeviceListener()
        removeDefaultOutputDeviceListener()
        micRestartTask?.cancel()
        sysRestartTask?.cancel()
        micRestartTask = nil
        sysRestartTask = nil
        pendingMicDeviceID = nil
        pendingSystemAudioRestart = false
        micKeepAliveTask?.cancel()

        // Cancel BEFORE finishing the streams so the transcriber loops observe
        // cancellation by the time they reach their finish branch and take the
        // fast, no-drain path (see AppleSpeechLiveTranscriber.runAnalyzer).
        micTask?.cancel()
        sysTask?.cancel()
        micCapture.finishStream()
        systemCapture.finishStream()
        let teardownFinished = await Self.awaitTeardown(
            of: [micTask, sysTask].compactMap { $0 },
            timeoutSeconds: 5
        )
        if !teardownFinished {
            Log.transcription.error("Live transcriber teardown timed out; abandoning tasks")
            DiagnosticsSupport.record(
                category: "meeting",
                message: "Transcriber teardown timed out after 5s; abandoned"
            )
        }

        // Reset engine state BEFORE the hardware/diarizer teardown below: any
        // of those awaits wedging must never leave isRunning stuck true (which
        // silently refuses every subsequent start until relaunch). liveEpoch
        // invalidates the abandoned transcribers' late callbacks.
        liveEpoch += 1
        micTask = nil
        sysTask = nil
        pendingMicDeviceID = nil
        micKeepAliveTask = nil
        currentMicDeviceID = 0
        let doomedSystemCapture = systemCapture
        let doomedManagers = [diarizationManager, micDiarizationManager].compactMap { $0 }
        // Preserve the session's "This is me" voice references for the batch
        // pass before the matcher goes away — batch self-matching uses them
        // alongside the enrolled voiceprint.
        if let matcher = voiceMatcher {
            lastLiveSelfReferences = await matcher.exportedSelfReferences()
        }
        diarizationManager = nil
        micDiarizationManager = nil
        voiceMatcher = nil
        onLiveSpeakerAutoNamed = nil
        micBackend = nil
        systemBackend = nil
        vadManager = nil
        transcriptStore.volatileYouText = ""
        transcriptStore.volatileThemText = ""
        liveCloudTranscriptIssue = nil
        liveCloudTranscriptionIsProcessing = false
        preparedCloudStartBackend = nil
        clearDownloadTracking()
        activeTranscriptionSession = nil
        isRunning = false
        assetStatus = "Ready"

        // Mic teardown is synchronous MainActor work (fast in practice); the
        // system tap teardown crosses XPC into coreaudiod and the diarizer
        // finalize can sit behind an inference call, so both are bounded and
        // abandoned on timeout rather than trusted to return.
        micCapture.stop()
        let hardwareTeardown = Task.detached {
            await doomedSystemCapture.stop()
            for dm in doomedManagers {
                await dm.finalize()
            }
        }
        let hardwareFinished = await Self.awaitTeardown(
            of: [hardwareTeardown],
            timeoutSeconds: 10
        )
        if !hardwareFinished {
            Log.transcription.error("System capture/diarizer teardown timed out; abandoning")
            DiagnosticsSupport.record(
                category: "meeting",
                message: "Capture teardown timed out after 10s; abandoned"
            )
        }
    }

    /// Await the given tasks, giving up after `timeoutSeconds`. A wedged live
    /// transcriber (SpeechTranscriber's results stream has been observed to
    /// never terminate after cancellation) must not hang finalize: the
    /// coordinator's watchdog only resets UI state, so a hung finalize left
    /// `isRunning` stuck true and the engine permanently unable to record
    /// until relaunch. Returns false when the tasks were abandoned.
    nonisolated static func awaitTeardown(
        of tasks: [Task<Void, Never>],
        timeoutSeconds: Double
    ) async -> Bool {
        guard !tasks.isEmpty else { return true }
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        // Detached tasks: this runs inside the (possibly cancelled)
        // finalization task, where Task.sleep would throw immediately and a
        // task group would still block on the unabandonable await.
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            Task.detached {
                for task in tasks { await task.value }
                if once.claim() { continuation.resume(returning: true) }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    func stop() {
        if case .scripted = mode {
            isRunning = false
            assetStatus = "Ready"
            transcriptStore.volatileYouText = ""
            transcriptStore.volatileThemText = ""
            liveCloudTranscriptIssue = nil
            liveCloudTranscriptionIsProcessing = false
            return
        }

        removeDefaultDeviceListener()
        removeDefaultOutputDeviceListener()
        micRestartTask?.cancel()
        sysRestartTask?.cancel()
        micRestartTask = nil
        sysRestartTask = nil
        pendingMicDeviceID = nil
        pendingSystemAudioRestart = false
        micTask?.cancel()
        sysTask?.cancel()
        micKeepAliveTask?.cancel()
        liveEpoch += 1
        micTask = nil
        sysTask = nil
        micKeepAliveTask = nil
        Task { await systemCapture.stop() }
        micCapture.stop()
        currentMicDeviceID = 0
        micBackend = nil
        systemBackend = nil
        vadManager = nil
        transcriptStore.volatileYouText = ""
        transcriptStore.volatileThemText = ""
        liveCloudTranscriptIssue = nil
        liveCloudTranscriptionIsProcessing = false
        preparedCloudStartBackend = nil
        clearDownloadTracking()
        activeTranscriptionSession = nil
        diarizationManager = nil
        micDiarizationManager = nil
        voiceMatcher = nil
        onLiveSpeakerAutoNamed = nil
        isRunning = false
        assetStatus = "Ready"
    }

    private func performMicRestart(inputDeviceID: AudioDeviceID) async {
        guard isRunning, let vadManager else { return }

        userSelectedDeviceID = inputDeviceID

        guard let targetMicID = resolvedMicDeviceID(for: inputDeviceID) else {
            let msg = unavailableMicMessage(for: inputDeviceID)
            Log.transcription.error("Mic swap failed: \(msg, privacy: .public)")
            lastError = msg
            return
        }

        guard targetMicID != currentMicDeviceID else {
            Log.transcription.debug("Mic swap skipped, same device \(targetMicID, privacy: .public)")
            return
        }

        Log.transcription.info("Switching mic from \(self.currentMicDeviceID, privacy: .public) to \(targetMicID, privacy: .public)")

        micCapture.finishStream()
        // Bounded: the Apple Speech natural-end teardown drains its backlog
        // and has been observed to wedge outright; a device switch must not
        // silently kill the mic channel for the rest of the session.
        if await Self.awaitTeardown(of: [micTask].compactMap { $0 }, timeoutSeconds: 10) == false {
            Log.transcription.error("Mic transcriber teardown timed out during device switch; abandoning")
            micTask?.cancel()
        }

        if Task.isCancelled || !isRunning {
            return
        }

        micTask = nil
        micCapture.stop()

        guard await ensureMicrophonePermission() else {
            Log.transcription.error("Mic permission lost during device switch")
            return
        }

        startMicStream(
            locale: settings.locale,
            vadManager: vadManager,
            deviceID: targetMicID
        )
        currentMicDeviceID = targetMicID
        lastError = nil

        Log.transcription.info("Mic restarted on device \(targetMicID, privacy: .public)")
    }

    private func restartSystemAudio() {
        guard isRunning else { return }
        pendingSystemAudioRestart = true

        if sysRestartTask != nil {
            Log.transcription.info("Queued system audio restart")
            return
        }

        sysRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.sysRestartTask = nil }

            while self.isRunning, self.pendingSystemAudioRestart {
                self.pendingSystemAudioRestart = false
                await self.performSystemAudioRestart()
            }
        }
    }

    private func performSystemAudioRestart() async {
        guard isRunning, let vadManager else { return }

        Log.transcription.info("Restarting system audio stream")

        systemCapture.finishStream()
        if await Self.awaitTeardown(of: [sysTask].compactMap { $0 }, timeoutSeconds: 10) == false {
            Log.transcription.error("System transcriber teardown timed out during restart; abandoning")
            sysTask?.cancel()
        }

        if Task.isCancelled || !isRunning {
            return
        }

        sysTask = nil
        await systemCapture.stop()
        await startSystemAudioStream(locale: settings.locale, vadManager: vadManager)

        Log.transcription.info("System audio stream restarted")
    }

    private func startMicStream(
        locale: Locale,
        vadManager: VadManager,
        deviceID: AudioDeviceID,
        echoCancellation: Bool = false
    ) {
        var micStream = micCapture.bufferStream(deviceID: deviceID, echoCancellation: echoCancellation)
        if let recorder = audioRecorder {
            micStream = Self.tappedStream(micStream) { buffer in
                recorder.writeMicBuffer(buffer)
            }
        }

        // Tee mic audio to the in-person diarizer (and the self-voice matcher's
        // rolling buffer, which must stay aligned with the diarizer timeline).
        if let dm = micDiarizationManager {
            var onSamples: (@Sendable ([Float]) async -> Void)?
            if let matcher = voiceMatcher {
                onSamples = { samples in await matcher.appendAudio(samples) }
            }
            let feeder = DiarizationStreamFeeder(
                dm: dm,
                channelName: "mic",
                onSamples: onSamples
            )
            micStream = Self.diarizationTappedStream(micStream, feeder: feeder)
        }

        let store = transcriptStore
        let epoch = liveEpoch
        guard let micTranscriber = makeTranscriber(
            locale: locale,
            speaker: .you,
            vadManager: vadManager,
            onPartial: { [weak self] text in
                Task { @MainActor in
                    guard let self, self.liveEpoch == epoch else { return }
                    store.volatileYouText = text
                }
            },
            onFinal: { [weak self] segment in
                Task { @MainActor in
                    guard let self, self.liveEpoch == epoch else { return }
                    store.volatileYouText = ""
                    var speaker: Speaker = .you
                    if let dm = self.micDiarizationManager {
                        let diarized = await dm.dominantSpeaker(
                            from: segment.startTime,
                            to: segment.endTime,
                            channel: .microphone
                        )
                        if let matcher = self.voiceMatcher, matcher.hasVoiceprint {
                            // A voiceprint is enrolled: "You" is earned by matching
                            // the voiceprint, never assumed from speaking first. A
                            // mic voice stays a provisional "Speaker" until the
                            // voiceprint confirms it is the user, so a guest who
                            // speaks first is never labeled "You". Resolve the raw
                            // diarizer index (dominantSpeaker collapses a lone voice
                            // to .you; dominantIndex keeps the real index).
                            let rawIndex = await dm.dominantIndex(
                                from: segment.startTime, to: segment.endTime
                            )
                            let resolvedIndex: Int?
                            if case .local(let localN) = diarized {
                                resolvedIndex = localN
                            } else if let rawIndex {
                                resolvedIndex = rawIndex + 1
                            } else {
                                // No diarized overlap for this range (diarizer
                                // lag or a timeline gap). Don't guess cluster 1:
                                // feeding this window into a guessed cluster's
                                // clip can wrongly confirm or demote that voice.
                                resolvedIndex = nil
                            }

                            if let n = resolvedIndex {
                                let verdict = await matcher.classifyUtterance(
                                    localSpeakerNumber: n,
                                    startTime: segment.startTime,
                                    endTime: segment.endTime
                                )
                                // Re-check after the awaits: a stale task from
                                // a stopped session must not publish names or
                                // bubbles into the session that replaced it.
                                guard self.liveEpoch == epoch else { return }
                                switch verdict {
                                case .isSelf:
                                    // The user's voice, confirmed now or on an
                                    // earlier utterance and re-verified since —
                                    // promote provisional lettered bubbles too.
                                    speaker = .you
                                    store.relabel(from: .local(n), to: .you)
                                case .matchedLibrary(let name):
                                    // Recognized from the speaker library: keep
                                    // the lettered label and surface the name.
                                    speaker = .local(n)
                                    self.onLiveSpeakerAutoNamed?(Speaker.local(n).storageKey, name)
                                case .notSelf, .pending:
                                    // Decisively someone else, or not yet scored:
                                    // keep the provisional "Speaker" label rather
                                    // than guessing "You".
                                    speaker = .local(n)
                                }
                            }
                        } else {
                            // No voiceprint enrolled: fall back to the "mic = you"
                            // default (a lone mic voice is presumed to be the user),
                            // but still score lettered guests against the library
                            // so people from earlier meetings get their names live.
                            speaker = diarized
                            if case .local(let n) = diarized, let matcher = self.voiceMatcher {
                                let verdict = await matcher.classifyUtterance(
                                    localSpeakerNumber: n,
                                    startTime: segment.startTime,
                                    endTime: segment.endTime
                                )
                                guard self.liveEpoch == epoch else { return }
                                switch verdict {
                                case .matchedLibrary(let name):
                                    self.onLiveSpeakerAutoNamed?(Speaker.local(n).storageKey, name)
                                case .isSelf:
                                    // Only reachable via a user's "This is me"
                                    // pin (no voiceprint to match otherwise) —
                                    // honor it or the letter resurrects on the
                                    // next utterance.
                                    speaker = .you
                                    store.relabel(from: .local(n), to: .you)
                                case .notSelf, .pending:
                                    break
                                }
                            }
                        }
                    }
                    // Awaits above can outlive the session; never append a
                    // dead session's utterance into its replacement.
                    guard self.liveEpoch == epoch else { return }
                    store.append(
                        Utterance(
                            text: segment.text,
                            speaker: speaker,
                            startTime: segment.startTime,
                            endTime: segment.endTime,
                            source: .microphone
                        )
                    )
                }
            }
        ) else {
            lastError = "Failed to create transcriber. Try restarting."
            isRunning = false
            assetStatus = "Ready"
            activeTranscriptionSession = nil
            return
        }
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }
    }

    private func startSystemAudioStream(
        locale: Locale,
        vadManager: VadManager
    ) async {
        Log.transcription.info("Starting system audio capture")

        let sysStreams: SystemAudioCapture.CaptureStreams
        do {
            var outputID: AudioDeviceID? = settings.outputDeviceID != 0 ? settings.outputDeviceID : nil
            // If the stored ID is stale, try resolving via stable UID.
            if let id = outputID,
               !SystemAudioCapture.availableOutputDevices().contains(where: { $0.id == id }),
               let uid = settings.outputDeviceUID,
               let resolved = SystemAudioCapture.outputDeviceID(forUID: uid) {
                settings.outputDeviceID = resolved
                outputID = resolved
            }
            sysStreams = try await systemCapture.bufferStream(outputDeviceID: outputID)
            Log.transcription.info("System audio capture started")
            clearSystemAudioErrorIfPresent()
        } catch {
            let msg = "Failed to start system audio: \(error.localizedDescription)"
            Log.transcription.error("Failed to start system audio: \(error, privacy: .public)")
            lastError = msg
            return
        }

        var sysStream = sysStreams.systemAudio
        if let recorder = audioRecorder {
            sysStream = Self.tappedStream(sysStream) { buffer in
                recorder.writeSysBuffer(buffer)
            }
        }

        // Tee system audio to diarization manager if enabled. The feeder
        // resamples to the 16 kHz the diarizer expects (the raw tap runs at
        // the output device's native rate).
        if let dm = diarizationManager {
            let feeder = DiarizationStreamFeeder(dm: dm, channelName: "sys")
            sysStream = Self.diarizationTappedStream(sysStream, feeder: feeder)
        }

        let store = transcriptStore
        let epoch = liveEpoch
        guard let sysTranscriber = makeTranscriber(
            locale: locale,
            speaker: .them,
            vadManager: vadManager,
            onPartial: { [weak self] text in
                Task { @MainActor in
                    guard let self, self.liveEpoch == epoch else { return }
                    store.volatileThemText = text
                }
            },
            onFinal: { [weak self] segment in
                Task { @MainActor in
                    guard let self, self.liveEpoch == epoch else { return }
                    store.volatileThemText = ""
                    let speaker: Speaker
                    if let dm = self.diarizationManager {
                        speaker = await dm.dominantSpeaker(from: segment.startTime, to: segment.endTime)
                    } else {
                        speaker = .them
                    }
                    // Re-check after the await: a stale task from a stopped
                    // session must not append into its replacement.
                    guard self.liveEpoch == epoch else { return }
                    store.append(
                        Utterance(
                            text: segment.text,
                            speaker: speaker,
                            startTime: segment.startTime,
                            endTime: segment.endTime,
                            source: .system
                        )
                    )
                }
            }
        ) else {
            lastError = "Failed to create the system-audio transcriber. Try restarting."
            return
        }

        sysTask = Task.detached {
            await sysTranscriber.run(stream: sysStream)
        }
    }

    /// Passes a capture stream through unchanged while feeding a resampling
    /// diarization feeder; flushes the feeder's tail when the stream ends.
    ///
    /// The feeder runs on its own bounded side-channel: awaiting LS-EEND
    /// inference inline used to backpressure the transcription feed (live ASR
    /// lag) and, worse, let raw native-rate audio buffer without limit in the
    /// upstream capture stream whenever inference fell behind realtime. A
    /// diarizer that falls minutes behind now drops its oldest audio instead
    /// (with a one-time log), which only degrades live speaker labels — the
    /// batch pass re-diarizes from the recorded stems.
    private nonisolated static func diarizationTappedStream(
        _ stream: AsyncStream<AVAudioPCMBuffer>,
        feeder: DiarizationStreamFeeder
    ) -> AsyncStream<AVAudioPCMBuffer> {
        struct Box: @unchecked Sendable { let stream: AsyncStream<AVAudioPCMBuffer> }
        let box = Box(stream: stream)
        let (tapped, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let (feed, feedContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(300)
        )
        let feedBox = Box(stream: feed)
        let feedTask = Task.detached {
            for await buffer in feedBox.stream {
                await feeder.ingest(buffer)
            }
            await feeder.flush()
        }
        Task.detached {
            var loggedDrop = false
            for await buffer in box.stream {
                nonisolated(unsafe) let b = buffer
                continuation.yield(b)
                if case .dropped = feedContinuation.yield(b), !loggedDrop {
                    loggedDrop = true
                    Log.transcription.error("Diarizer fell behind realtime; dropping its oldest audio (live labels may degrade)")
                }
            }
            // Finish downstream first: the transcriber's natural-end teardown
            // must not wait behind the diarizer draining its backlog.
            continuation.finish()
            feedContinuation.finish()
            await feedTask.value
        }
        return tapped
    }

    private func makeTranscriber(
        locale: Locale,
        speaker: Speaker,
        vadManager: VadManager,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (StreamingTranscriber.FinalSegment) -> Void
    ) -> (any LiveTranscribing)? {
        let model = currentTranscriptionModel()

        // Apple Speech streams natively (volatile → finalized) through
        // SpeechAnalyzer instead of the VAD/segment loop.
        if model == .appleSpeech, #available(macOS 26.0, *) {
            return AppleSpeechLiveTranscriber(
                locale: locale,
                speakerKey: speaker.storageKey,
                customVocabulary: settings.transcriptionCustomVocabulary,
                onPartial: onPartial,
                onFinal: onFinal,
                onError: { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.isRunning else { return }
                        self.lastError = message
                    }
                }
            )
        }

        let backend = speaker == .you ? micBackend : systemBackend
        guard let backend else {
            Log.transcription.error("makeTranscriber called without initialized backend for \(speaker.storageKey, privacy: .public)")
            return nil
        }
        return StreamingTranscriber(
            backend: backend,
            locale: locale,
            vadManager: vadManager,
            speaker: speaker,
            sessionID: activeTranscriptionSession?.sessionID,
            transcriptionModel: model.rawValue,
            flushInterval: model.flushIntervalSamples,
            skipPartials: model.isCloud,
            onPartial: onPartial,
            onFinal: onFinal,
            onCloudSegmentStatus: makeCloudSegmentStatusHandler(for: model),
            onCloudProcessingChanged: makeCloudProcessingChangedHandler(for: model)
        )
    }

    private func makeCloudSegmentStatusHandler(
        for model: TranscriptionModel
    ) -> (@Sendable (StreamingTranscriber.CloudSegmentStatus) -> Void)? {
        guard model.isCloud else { return nil }
        return { [weak self] status in
            Task { @MainActor [weak self] in
                self?.handleCloudSegmentStatus(status)
            }
        }
    }

    private func makeCloudProcessingChangedHandler(
        for model: TranscriptionModel
    ) -> (@Sendable (Bool) -> Void)? {
        guard model.isCloud else { return nil }
        return { [weak self] isProcessing in
            Task { @MainActor [weak self] in
                self?.liveCloudTranscriptionIsProcessing = isProcessing
            }
        }
    }

    private func handleCloudSegmentStatus(_ status: StreamingTranscriber.CloudSegmentStatus) {
        switch status.kind {
        case .success:
            liveCloudTranscriptIssue = nil
        case .empty:
            if transcriptStore.utterances.isEmpty {
                liveCloudTranscriptIssue = status.presentation
            }
        case .error:
            liveCloudTranscriptIssue = status.presentation
            if let presentation = status.presentation,
               presentation.title.localizedCaseInsensitiveContains("API key rejected") {
                lastError = "\(presentation.title). \(presentation.detail)"
            }
        }
    }

    func currentTranscriptionModel() -> TranscriptionModel {
        activeTranscriptionSession?.transcriptionModel ?? settings.transcriptionModel
    }

    private func resolvedMicDeviceID(for inputDeviceID: AudioDeviceID) -> AudioDeviceID? {
        if inputDeviceID > 0 {
            let availableDeviceIDs = Set(MicCapture.availableInputDevices().map(\.id))
            if availableDeviceIDs.contains(inputDeviceID) { return inputDeviceID }
            // Device ID is stale; try resolving via stable UID.
            if let uid = settings.inputDeviceUID,
               let resolved = MicCapture.inputDeviceID(forUID: uid) {
                // Update the stored ID so future lookups are fast.
                settings.inputDeviceID = resolved
                return resolved
            }
            return nil
        }

        return MicCapture.defaultInputDeviceID()
    }

    private func unavailableMicMessage(for inputDeviceID: AudioDeviceID) -> String {
        if inputDeviceID > 0 {
            return "The selected microphone is no longer available."
        }

        return "No default microphone is currently available."
    }

    private static func modelNeedsDownload(_ model: TranscriptionModel) -> Bool {
        guard !model.isCloud else { return false }
        let backend = model.makeBackend()
        if case .needsDownload = backend.checkStatus() {
            return true
        }
        return false
    }

    private func validateConfiguredInputDevice() -> StartPreflightIssue? {
        guard settings.inputDeviceID > 0 else {
            guard MicCapture.defaultInputDeviceID() != nil else {
                return StartPreflightIssue(
                    message: "No default microphone is currently available."
                )
            }
            return nil
        }

        if MicCapture.availableInputDevices().contains(where: { $0.id == settings.inputDeviceID }) {
            return nil
        }
        if let uid = settings.inputDeviceUID,
           let resolved = MicCapture.inputDeviceID(forUID: uid) {
            settings.inputDeviceID = resolved
            return nil
        }

        return StartPreflightIssue(
            message: "The selected microphone is no longer available. Choose another microphone in Settings > Transcription."
        )
    }

    private func validateConfiguredOutputDevice() -> StartPreflightIssue? {
        var configuredOutputID: AudioDeviceID? = settings.outputDeviceID != 0 ? settings.outputDeviceID : nil

        if let id = configuredOutputID {
            if SystemAudioCapture.availableOutputDevices().contains(where: { $0.id == id }) {
                return nil
            }
            if let uid = settings.outputDeviceUID,
               let resolved = SystemAudioCapture.outputDeviceID(forUID: uid) {
                settings.outputDeviceID = resolved
                configuredOutputID = resolved
            } else {
                return StartPreflightIssue(
                    message: "The selected output device is no longer available. Choose another output device in Settings > Transcription."
                )
            }
        }

        if configuredOutputID == nil {
            do {
                _ = try SystemAudioCapture.defaultOutputDeviceID()
            } catch SystemAudioCapture.CaptureError.noOutputDevice {
                return StartPreflightIssue(
                    message: "No system audio output device is currently available."
                )
            } catch {
                logOutputValidationFallback(error)
            }
        }

        return nil
    }

    private func logOutputValidationFallback(_ error: Error) {
        Log.transcription.error(
            "Output-device preflight validation fell back to runtime start after unexpected error: \(error, privacy: .public)"
        )
    }

    /// Wrap an audio stream to forward each buffer to a synchronous tap before yielding it downstream.
    private nonisolated static func tappedStream(
        _ stream: AsyncStream<AVAudioPCMBuffer>,
        tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> AsyncStream<AVAudioPCMBuffer> {
        struct Box: @unchecked Sendable { let stream: AsyncStream<AVAudioPCMBuffer> }
        let box = Box(stream: stream)
        let (output, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        Task {
            for await buffer in box.stream {
                tap(buffer)
                nonisolated(unsafe) let b = buffer
                continuation.yield(b)
            }
            continuation.finish()
        }
        return output
    }

    private func localeMismatchMessage(
        for locale: Locale,
        transcriptionModel: TranscriptionModel
    ) -> String? {
        guard transcriptionModel == .parakeetV2,
              let languageCode = normalizedLanguageCode(for: locale),
              languageCode != "en"
        else {
            return nil
        }

        let localeIdentifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        return "Parakeet TDT v2 is English-only. Switch to Parakeet TDT v3 for \(localeIdentifier)."
    }

    private func normalizedLanguageCode(for locale: Locale) -> String? {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        return identifier.split(separator: "-").first.map { String($0).lowercased() }
    }

    private func clearSystemAudioErrorIfPresent() {
        guard let lastError else { return }
        if lastError.localizedCaseInsensitiveContains("system audio") ||
            lastError.localizedCaseInsensitiveContains("audio output device") {
            self.lastError = nil
        }
    }

    // MARK: - Download Helpers

    private func beginDownloadTracking(for model: TranscriptionModel) {
        downloadProgress = 0
        downloadStartTime = Date()
        downloadTotalBytes = model.estimatedDownloadBytes
        downloadDetail = DownloadProgressDetail(fraction: 0, sizeText: nil, speedText: nil, etaText: nil)
    }

    private func clearDownloadTracking() {
        downloadProgress = nil
        downloadDetail = nil
        downloadStartTime = nil
        downloadTotalBytes = nil
    }

    private func prepareBackend(_ backend: any TranscriptionBackend) async throws {
        try await backend.prepare(
            onStatus: { [weak self] status in
                Task { @MainActor in self?.assetStatus = status }
            },
            onProgress: { [weak self] fraction in
                Task { @MainActor in
                    self?.downloadProgress = fraction
                    self?.updateDownloadDetail(fraction: fraction)
                }
            }
        )
    }

    // MARK: - Download Progress Detail

    private func updateDownloadDetail(fraction: Double) {
        guard let startTime = downloadStartTime else {
            downloadDetail = DownloadProgressDetail(fraction: fraction, sizeText: nil, speedText: nil, etaText: nil)
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let totalBytes = downloadTotalBytes

        // Size text: "142 MB / 800 MB" (only when total is known)
        var sizeText: String?
        if let totalBytes {
            let downloaded = Int64(fraction * Double(totalBytes))
            sizeText = "\(Self.formatBytes(downloaded)) / \(Self.formatBytes(totalBytes))"
        }

        // Speed and ETA need enough elapsed time to be meaningful
        var speedText: String?
        var etaText: String?
        if elapsed > 1, fraction > 0.01 {
            // Speed from fraction progress rate + known total
            if let totalBytes {
                let bytesDownloaded = fraction * Double(totalBytes)
                let bytesPerSecond = bytesDownloaded / elapsed
                speedText = "\(Self.formatBytes(Int64(bytesPerSecond)))/s"

                let remaining = Double(totalBytes) - bytesDownloaded
                if bytesPerSecond > 0 {
                    let secondsLeft = remaining / bytesPerSecond
                    etaText = Self.formatDuration(secondsLeft)
                }
            } else {
                // No total bytes known — estimate ETA from fraction rate alone
                let fractionPerSecond = fraction / elapsed
                if fractionPerSecond > 0 {
                    let remainingFraction = 1.0 - fraction
                    let secondsLeft = remainingFraction / fractionPerSecond
                    etaText = Self.formatDuration(secondsLeft)
                }
            }
        }

        downloadDetail = DownloadProgressDetail(
            fraction: fraction,
            sizeText: sizeText,
            speedText: speedText,
            etaText: etaText
        )
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else {
            return String(format: "%.0f MB", Double(bytes) / 1_000_000)
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s remaining" }
        let m = s / 60
        let rem = s % 60
        return rem > 0 ? "\(m)m \(rem)s remaining" : "\(m)m remaining"
    }
}
