import Foundation
import Observation
import CoreAudio
import AppKit
import UniformTypeIdentifiers

struct RecordingHealthNotice: Equatable {
    enum Severity: Equatable {
        case warning
        case error
    }

    let severity: Severity
    let message: String
}

/// What a live capture channel is doing right now, for transcript-header
/// status display. Ordered by display priority (worst state wins).
enum LiveChannelActivity: Int, Equatable, Comparable {
    /// No audible speech on the channel.
    case idle = 0
    /// Audible speech, no hypothesis text yet.
    case hearing = 1
    /// Volatile hypothesis text is flowing.
    case transcribing = 2
    /// Audible speech but the transcript stopped progressing (ASR lag).
    case behind = 3

    static func < (lhs: LiveChannelActivity, rhs: LiveChannelActivity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Published state for the live session, projected by ContentView.
/// Declared as @Observable class so SwiftUI tracks each property individually,
/// preventing a full view-tree re-render whenever any single field changes.
@Observable
final class LiveSessionState {
    var isRunning: Bool = false
    var sessionPhase: MeetingState = .idle
    var audioLevel: Float = 0
    var recordingElapsedSeconds: Int = 0
    var liveTranscript: [Utterance] = []
    var liveTranscriptNotice: String? = nil
    var liveTranscriptEmptyStateMessage: String? = nil
    var volatileYouText: String = ""
    var volatileThemText: String = ""
    var suggestions: [Suggestion] = []
    var isGeneratingSuggestions: Bool = false
    var batchStatus: BatchAudioTranscriber.Status = .idle
    var batchIsImporting: Bool = false
    var lastEndedSession: SessionIndex? = nil
    var lastEndedSessionCanRetranscribe: Bool = false
    var lastSessionHasNotes: Bool = false
    var kbIndexingStatus: KnowledgeBaseIndexingStatus = .idle
    var statusMessage: String? = nil
    var errorMessage: String? = nil
    var matchedCalendarEvent: CalendarEvent? = nil
    var needsDownload: Bool = false
    var downloadProgress: Double? = nil
    var downloadDetail: DownloadProgressDetail? = nil
    var transcriptionPrompt: String = ""
    var modelDisplayName: String = ""
    var showLiveTranscript: Bool = true
    /// Combined worst-case live activity across mic and system channels.
    var liveChannelActivity: LiveChannelActivity = .idle
    var isMicMuted: Bool = false
    var isRecordingPaused: Bool = false
    var recordingHealthNotice: RecordingHealthNotice? = nil
    /// The user's live scratchpad text for the active session.
    var scratchpadText: String = ""
    /// Names the user has assigned to live speakers this session
    /// (storageKey → name). Persisted to the session as they're set.
    var liveSpeakerNames: [String: String] = [:]
    /// Names matched live from the voice library (storageKey → name).
    /// Display-only: user renames win over these, and the batch pass
    /// re-derives library names authoritatively for the saved transcript.
    var liveAutoSpeakerNames: [String: String] = [:]

    /// Live display names: library matches with the user's renames on top.
    var displaySpeakerNames: [String: String] {
        liveAutoSpeakerNames.merging(liveSpeakerNames) { _, userName in userName }
    }
}

/// Owns all live session side effects: polling, utterance ingestion,
/// settings change tracking, session start/stop, and finalization.
/// ContentView becomes a pure projection of this controller's state.
@Observable
@MainActor
final class LiveSessionController {
    enum ScratchpadAssetInsertion: Sendable {
        case attachmentFile(URL)
        case imageFile(URL)
        case imageData(Data)
    }

    enum EmptySessionDiagnosticClassification: String, Equatable {
        case noAudioDetected = "no_audio_detected"
        case transcriptionProducedNoText = "transcription_produced_no_text"
        case unclassified = "unclassified"
    }

    struct EmptySessionDiagnosticsEvent: Codable, Equatable {
        let event: String
        let sessionID: String
        let transcriptionModel: String
        let elapsedSeconds: Int
        let utteranceCount: Int
        let peakAudioLevel: Float
        let micCapturedFrames: Bool
        let systemCapturedFrames: Bool
        let micCaptureError: String?
        let classification: String
        let retainedRecoveryAudio: Bool
        let recoveryBatchAttempted: Bool
        let recoveryResult: String
        let finalUtteranceCount: Int?
        let mergedIntoSessionID: String?
        let failureMessage: String?
    }

    private struct PendingRecoveryDiagnostics: Equatable {
        let sessionID: String
        let transcriptionModel: String
        let classification: EmptySessionDiagnosticClassification
    }

    struct AudioRetentionPlan: Equatable {
        let shouldStartRecorder: Bool
        let shouldRetainBatchAudio: Bool
        let shouldExportRecording: Bool
        let shouldRunRecoveryBatch: Bool
    }

    struct RecordingHealthInput: Equatable {
        let elapsed: TimeInterval
        let transcriptionModel: TranscriptionModel
        let utteranceCount: Int
        let peakAudioLevel: Float
        let micHasCapturedFrames: Bool
        let systemHasCapturedFrames: Bool
        let micCaptureError: String?
        let isMicMuted: Bool
        let isRecordingPaused: Bool
        let hasBlockingError: Bool
    }

    /// Persisted state for adaptive silence detection, threaded between
    /// successive evaluations of the polling loop.
    struct SilenceTracking: Equatable {
        var lastAudibleActivityAt: Date?
        /// Running estimate of the ambient (combined mic + system) audio level.
        var noiseFloor: Float
        /// Timestamp of the last sample folded into the floor estimate.
        var lastSampleAt: Date?

        static let initial = SilenceTracking(lastAudibleActivityAt: nil, noiseFloor: 0, lastSampleAt: nil)
    }

    struct AutomaticSilenceTimeoutEvaluation: Equatable {
        let tracking: SilenceTracking
        let shouldStop: Bool
    }

    static let automaticSilenceTimeoutInterval: TimeInterval = 300

    /// Effective silence timeout in seconds, applied to every session (manual
    /// and auto-detected). Resolution order:
    /// 1. `OPENOATS_SILENCE_TIMEOUT_SECONDS` env override (for testing),
    /// 2. the user's `silenceTimeoutSeconds` setting (0 disables auto-stop),
    /// 3. the built-in default.
    static func effectiveAutomaticSilenceTimeoutInterval(settings: AppSettings?) -> TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["OPENOATS_SILENCE_TIMEOUT_SECONDS"],
           let seconds = TimeInterval(raw), seconds > 0 {
            return seconds
        }
        // Read the persisted value so a live recording honors a Settings change
        // immediately (no app restart), falling back to the in-memory value.
        if let configured = settings?.persistedSilenceTimeoutSeconds ?? settings?.silenceTimeoutSeconds {
            return TimeInterval(configured)   // 0 == disabled
        }
        return automaticSilenceTimeoutInterval
    }

    /// Absolute lower bound on what counts as "audible". The adaptive floor
    /// does the real work; this only guards against the dynamic threshold
    /// collapsing toward zero on a near-silent input. ~ -68 dBFS combined.
    static let audibleActivityLevelThreshold: Float = 0.01

    /// A sample counts as audible activity when it exceeds the estimated
    /// noise floor by this factor (≈ 8 dB of headroom above ambient). Speech
    /// typically sits 15–40 dB above the floor, so it clears this comfortably
    /// while steady mic/room/electrical noise does not.
    static let audibleActivityMargin: Float = 2.5

    /// Time constant for the noise floor falling toward quieter input. Short,
    /// so the estimate calibrates to ambient within seconds of going quiet.
    static let noiseFloorFallTimeConstant: TimeInterval = 5

    /// Time constant for the noise floor rising toward louder input. Long, so
    /// transient speech bursts barely inflate the floor (asymmetric tracking).
    static let noiseFloorRiseTimeConstant: TimeInterval = 60

    /// Clamp on the per-sample time delta so a long gap between samples (app
    /// suspended, debugger paused) can't collapse the floor in a single step.
    static let noiseFloorMaxSampleInterval: TimeInterval = 5

    private(set) var state = LiveSessionState()

    private let coordinator: AppCoordinator
    private let container: AppContainer

    private var downloadTask: Task<Void, Never>?
    private var startPreflightTask: Task<Void, Never>?
    private var scratchpadSaveTask: Task<Void, Never>?
    private var pendingInitialScratchpad: String?

    // Tracked-change sentinels
    private var observedUtteranceCount = 0
    private var observedIsRunning = false
    private var observedAudioLevel: Float = 0
    private var observedSuggestions: [Suggestion] = []
    private var observedIsGenerating = false
    private var observedKBFolderPath: String?
    private var observedNotesFolderPath = ""
    private var observedMeetingTranscriptDateFolderFormat: MeetingTranscriptDateFolderFormat?
    private var observedEmbeddingProvider: EmbeddingProvider?
    private var observedVoyageApiKey: String?
    private var observedTranscriptionModel: TranscriptionModel = .parakeetV2
    private var observedInputDeviceID: AudioDeviceID = 0
    private var observedPendingExternalCommandID: UUID?
    /// Tracks the session ID we last handled a batch completion for,
    /// preventing the auto-dismiss → re-poll cycle from re-triggering the notification.
    private var lastNotifiedBatchSessionID: String?
    private var observedPeakAudioLevelSinceStart: Float = 0
    private var observedSystemHasEverCapturedFrames = false
    private var observedMicHasEverCapturedFrames = false
    private var observedSilenceTracking: SilenceTracking = .initial
    private var pendingRecoveryDiagnostics: PendingRecoveryDiagnostics?
    private var pendingAutoNotesSessionID: String?
    private var autoGeneratingNotesSessionID: String?

    init(coordinator: AppCoordinator, container: AppContainer) {
        self.coordinator = coordinator
        self.container = container
    }

    // MARK: - Initialization

    /// One-time setup tasks called when the view first appears.
    func performInitialSetup() async {
        await coordinator.sessionRepository.purgeRecentlyDeleted()
    }

    // MARK: - Polling Loop

    /// Call from a `.task` modifier to start the polling loop.
    /// Polls at 250ms while recording for responsive UI, and at 2s while idle
    /// to minimize observation churn and SwiftUI re-render cycles.
    func runPollingLoop(settings: AppSettings) async {
        syncProjectedState(settings: settings)

        while !Task.isCancelled {
            let isActive = coordinator.transcriptionEngine?.isRunning == true
                || coordinator.batchStatus != .idle
                || coordinator.knowledgeBase?.indexingStatus.needsFrequentPolling == true
            try? await Task.sleep(for: isActive ? .milliseconds(250) : .seconds(2))

            // Poll batch engine status (actor-isolated)
            if let engine = coordinator.batchAudioTranscriber {
                let status = await engine.status
                let importing = await engine.isImporting
                let activeBatchSessionID = await engine.activeSessionID
                if status != .idle || coordinator.batchStatus != .idle {
                    coordinator.batchStatus = status
                    coordinator.batchIsImporting = importing

                    if let pendingRecoveryDiagnostics {
                        if let activeBatchSessionID,
                           activeBatchSessionID != pendingRecoveryDiagnostics.sessionID {
                            self.pendingRecoveryDiagnostics = nil
                            coordinator.pendingRecoverySessionID = nil
                        }

                        switch status {
                        case .completed(let sid) where sid == pendingRecoveryDiagnostics.sessionID:
                            let recoveredIndex = await coordinator.sessionRepository.loadSession(id: sid).index
                            recordEmptySessionDiagnostics(
                                EmptySessionDiagnosticsEvent(
                                    event: "live_empty_session_recovery",
                                    sessionID: sid,
                                    transcriptionModel: pendingRecoveryDiagnostics.transcriptionModel,
                                    elapsedSeconds: 0,
                                    utteranceCount: 0,
                                    peakAudioLevel: 0,
                                    micCapturedFrames: false,
                                    systemCapturedFrames: false,
                                    micCaptureError: nil,
                                    classification: pendingRecoveryDiagnostics.classification.rawValue,
                                    retainedRecoveryAudio: true,
                                    recoveryBatchAttempted: true,
                                    recoveryResult: recoveredIndex.utteranceCount > 0 ? "completed" : "completed_empty",
                                    finalUtteranceCount: recoveredIndex.utteranceCount,
                                    mergedIntoSessionID: nil,
                                    failureMessage: nil
                                )
                            )
                            self.pendingRecoveryDiagnostics = nil
                            coordinator.pendingRecoverySessionID = nil
                        case .failed(let message):
                            recordEmptySessionDiagnostics(
                                EmptySessionDiagnosticsEvent(
                                    event: "live_empty_session_recovery",
                                    sessionID: pendingRecoveryDiagnostics.sessionID,
                                    transcriptionModel: pendingRecoveryDiagnostics.transcriptionModel,
                                    elapsedSeconds: 0,
                                    utteranceCount: 0,
                                    peakAudioLevel: 0,
                                    micCapturedFrames: false,
                                    systemCapturedFrames: false,
                                    micCaptureError: nil,
                                    classification: pendingRecoveryDiagnostics.classification.rawValue,
                                    retainedRecoveryAudio: true,
                                    recoveryBatchAttempted: true,
                                    recoveryResult: "failed",
                                    finalUtteranceCount: nil,
                                    mergedIntoSessionID: nil,
                                    failureMessage: message
                                )
                            )
                            self.pendingRecoveryDiagnostics = nil
                            coordinator.pendingRecoverySessionID = nil
                        default:
                            break
                        }
                    }

                    if case .completed(let sid) = status, lastNotifiedBatchSessionID != sid {
                        lastNotifiedBatchSessionID = sid
                        if !NSApp.isActive, let notifService = container.notificationService {
                            await notifService.postBatchCompleted(sessionID: sid)
                        }
                        await coordinator.loadHistory()
                        if coordinator.lastEndedSession?.id == sid {
                            coordinator.lastEndedSession = await coordinator.sessionRepository.loadSession(id: sid).index
                            let canRetranscribe = await coordinator.sessionRepository.hasRetainedBatchAudio(sessionID: sid)
                            set(\.lastEndedSessionCanRetranscribe, canRetranscribe)
                        }

                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            if case .completed = coordinator.batchStatus {
                                coordinator.batchStatus = .idle
                            }
                        }
                    }

                    resumePendingAutoNotesIfNeeded(for: status, settings: settings)
                }
            }

            syncProjectedState(settings: settings)
        }
    }

    func syncProjectedState(settings: AppSettings) {
        refreshState(settings: settings)
        synchronizeDerivedState(settings: settings)
    }

    // MARK: - Session Actions

    func startSession(
        settings: AppSettings,
        calendarEventOverride: CalendarEvent? = nil,
        initialScratchpad: String? = nil
    ) {
        guard !state.isRunning, startPreflightTask == nil else { return }
        container.ensureMeetingServicesInitialized(settings: settings, coordinator: coordinator)
        coordinator.suggestionEngine?.clear()
        coordinator.sidecastEngine?.clear()
        // Auto-started sessions can begin inside the idle polling gap, so an
        // idle tick isn't guaranteed to have reset these between sessions.
        micLagTracker.reset()
        sysLagTracker.reset()
        let calEvent = calendarEventOverride ?? (settings.calendarIntegrationEnabled
            ? container.calendarManager?.currentEvent(
                excludingCalendarIDs: settings.excludedCalendarIDs
            )
            : nil)
        DiagnosticsSupport.record(
            category: "meeting",
            message: "Start requested (calendarEvent=\(calEvent == nil ? "no" : "yes"))"
        )
        pendingInitialScratchpad = initialScratchpad?.trimmingCharacters(in: .newlines)
        let metadata = MeetingMetadata.manual(calendarEvent: calEvent)

        if settings.transcriptionModel.isCloud {
            state.errorMessage = nil
            state.statusMessage = "Validating \(settings.transcriptionModel.displayName)..."
            startPreflightTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.startPreflightTask = nil }
                let issue = await self.coordinator.transcriptionEngine?.preflightStart(
                    transcriptionModel: settings.transcriptionModel
                )
                self.syncProjectedState(settings: settings)
                guard issue == nil else { return }
                self.coordinator.handle(.userStarted(metadata), settings: settings)
            }
            return
        }

        coordinator.handle(.userStarted(metadata), settings: settings)
    }

    func stopSession(settings: AppSettings) {
        DiagnosticsSupport.record(category: "meeting", message: "Stop requested")
        coordinator.handle(.userStopped, settings: settings)
    }

    func confirmDownloadAndStart(settings: AppSettings) {
        container.ensureRecordingServicesInitialized(settings: settings, coordinator: coordinator)
        coordinator.transcriptionEngine?.downloadConfirmed = true
        startSession(settings: settings)
    }

    func downloadModelOnly(settings: AppSettings) {
        guard downloadTask == nil else { return }
        container.ensureRecordingServicesInitialized(settings: settings, coordinator: coordinator)
        downloadTask = Task {
            await coordinator.transcriptionEngine?.downloadModelOnly(
                transcriptionModel: settings.transcriptionModel
            )
            downloadTask = nil
        }
    }

    func toggleMicMute() {
        guard let engine = coordinator.transcriptionEngine, engine.isRunning else { return }
        engine.isMicMuted.toggle()
    }

    func toggleRecordingPause() {
        guard let engine = coordinator.transcriptionEngine, engine.isRunning else { return }
        engine.isRecordingPaused.toggle()
        observedSilenceTracking.lastAudibleActivityAt = Date()
    }

    /// Update the scratchpad text and schedule a debounced save.
    func updateScratchpad(_ text: String) {
        state.scratchpadText = text
        scratchpadSaveTask?.cancel()
        scratchpadSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let sessionID = _currentSessionID else { return }
            await coordinator.sessionRepository.saveScratchpad(sessionID: sessionID, text: text)
        }
    }

    func insertScratchpadImage(_ imageData: Data) {
        insertScratchpadAssets([.imageData(imageData)])
    }

    func insertScratchpadAssets(_ insertions: [ScratchpadAssetInsertion]) {
        guard let sessionID = _currentSessionID, !insertions.isEmpty else { return }

        Task {
            var updatedText = state.scratchpadText
            var insertedAnyAssets = false

            for insertion in insertions {
                switch insertion {
                case .attachmentFile(let sourceURL):
                    guard let attachment = await coordinator.sessionRepository.importAttachment(
                        sessionID: sessionID,
                        sourceURL: sourceURL
                    ) else {
                        continue
                    }
                    updatedText = Self.appendingMarkdownBlock(
                        Self.markdownLink(for: attachment),
                        to: updatedText
                    )
                    insertedAnyAssets = true

                case .imageFile(let fileURL):
                    guard let normalizedImageData = Self.normalizedPNGImageData(fromFileURL: fileURL) else {
                        continue
                    }
                    let filename = await coordinator.sessionRepository.saveImage(
                        sessionID: sessionID,
                        imageData: normalizedImageData
                    )
                    updatedText = Self.appendingMarkdownBlock(
                        "![](images/\(filename))",
                        to: updatedText
                    )
                    insertedAnyAssets = true

                case .imageData(let imageData):
                    guard let normalizedImageData = Self.normalizedPNGImageData(from: imageData) else {
                        continue
                    }
                    let filename = await coordinator.sessionRepository.saveImage(
                        sessionID: sessionID,
                        imageData: normalizedImageData
                    )
                    updatedText = Self.appendingMarkdownBlock(
                        "![](images/\(filename))",
                        to: updatedText
                    )
                    insertedAnyAssets = true
                }
            }

            guard insertedAnyAssets else { return }

            state.scratchpadText = updatedText
            scratchpadSaveTask?.cancel()
            await coordinator.sessionRepository.saveScratchpad(sessionID: sessionID, text: updatedText)
        }
    }

    // MARK: - KB Indexing

    func indexKBIfNeeded(settings: AppSettings) {
        guard let url = settings.kbFolderURL, let kb = coordinator.knowledgeBase else { return }
        Task {
            // TODO: Coalesce repeated startup/settings-triggered reindex requests into a
            // single in-flight task. Today ContentView startup, kbFolderPath changes, and
            // Voyage key changes can all arrive close together and redo the same cold-start scan.
            kb.clear()
            await kb.index(folderURL: url)
        }
    }

    func loadKBCacheIfAvailable(settings: AppSettings) {
        guard let url = settings.kbFolderURL, let kb = coordinator.knowledgeBase else { return }
        _ = kb.loadCachedStateIfAvailable(folderURL: url)
    }

    // MARK: - External Commands

    func handlePendingExternalCommandIfPossible(settings: AppSettings, openNotesWindow: (() -> Void)?) {
        guard let request = coordinator.pendingExternalCommand else { return }
        let handled: Bool

        switch request.command {
        case .startSession(let calendarEvent, let scratchpadSeed):
            container.ensureMeetingServicesInitialized(settings: settings, coordinator: coordinator)
            guard coordinator.transcriptionEngine != nil,
                  (coordinator.suggestionEngine != nil || coordinator.sidecastEngine != nil) else { return }
            if !state.isRunning {
                startSession(
                    settings: settings,
                    calendarEventOverride: calendarEvent,
                    initialScratchpad: scratchpadSeed
                )
            }
            handled = true
        case .stopSession:
            guard state.isRunning else { return }
            stopSession(settings: settings)
            handled = true
        case .openNotes(let sessionID):
            coordinator.queueSessionSelection(sessionID)
            openNotesWindow?()
            handled = true
        }

        if handled {
            coordinator.completeExternalCommand(request.id)
        }
    }

    // MARK: - Utterance Ingestion (migrated from ContentView)

    private func handleNewUtterance(_ last: Utterance, settings: AppSettings) {
        // No active session (a late final from an abandoned transcriber, or a
        // store append that slipped past finalize): nothing downstream can
        // write it anywhere but the wrong place.
        guard _currentSessionID != nil else { return }
        container.detectionController?.noteUtterance()

        if settings.enableLiveTranscriptCleanup, let engine = coordinator.liveTranscriptCleaner {
            Task {
                await engine.clean(last)
            }
        }

        let sessionID = currentSessionID

        // Echoed speaker audio can briefly land as "You"; do not let it drive the sidebar.
        if !coordinator.transcriptStore.shouldSkipRealtimeAssistant(for: last) {
            switch settings.sidebarMode {
            case .classicSuggestions:
                coordinator.suggestionEngine?.onUtterance(last)
            case .sidecast:
                coordinator.sidecastEngine?.onUtterance(last)
            }
        }

        Task {
            await coordinator.sessionRepository.appendLiveUtterance(
                sessionID: sessionID ?? "",
                utterance: last,
                metadata: LiveUtteranceMetadata(
                    utteranceID: last.id,
                    suggestionEngine: coordinator.suggestionEngine,
                    transcriptStore: coordinator.transcriptStore,
                    isDelayed: true
                )
            )
        }
    }

    /// The current session ID from the repository.
    private var currentSessionID: String? {
        // This is captured at start time and held for the session lifetime.
        _currentSessionID
    }
    private var _currentSessionID: String?

    /// Bumped whenever a session starts or is discarded. A finalization that
    /// was watchdog-cancelled completes late rather than stopping (its awaits
    /// are not cancellation-sensitive); every step after an await checks this
    /// so a stale finalization can never close a newer session's files or
    /// seal its recorder.
    private var sessionGeneration = 0

    /// The in-flight startTranscription task, retained so a stop that races
    /// session startup can cancel it and wait for it to unwind instead of
    /// letting it start capture for a session that already ended.
    var activeStartTask: Task<Void, Never>?

    private static func appendingMarkdownBlock(_ block: String, to existing: String) -> String {
        guard !existing.isEmpty else { return block }
        return existing + "\n\n" + block
    }

    private static func markdownLink(for attachment: NoteAttachment) -> String {
        let label = attachment.displayName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(label)](\(attachment.relativePath))"
    }

    static func isImageFile(url: URL) -> Bool {
        if let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = resourceValues.contentType {
            return contentType.conforms(to: .image)
        }
        if let inferredType = UTType(filenameExtension: url.pathExtension) {
            return inferredType.conforms(to: .image)
        }
        return false
    }

    private static func normalizedPNGImageData(fromFileURL fileURL: URL) -> Data? {
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        return normalizedPNGImageData(from: image)
    }

    private static func normalizedPNGImageData(from imageData: Data) -> Data? {
        guard let image = NSImage(data: imageData),
              let tiffRepresentation = image.tiffRepresentation,
              let bitmapRepresentation = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmapRepresentation.representation(using: .png, properties: [:])
    }

    private static func normalizedPNGImageData(from image: NSImage) -> Data? {
        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmapRepresentation = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmapRepresentation.representation(using: .png, properties: [:])
    }

    private func handleNewUtterances(startingAt startIndex: Int, settings: AppSettings) {
        let utterances = coordinator.transcriptStore.utterances
        guard startIndex < utterances.count else { return }

        for utterance in utterances[startIndex...] {
            handleNewUtterance(utterance, settings: settings)
        }
    }

    // MARK: - Transcription Lifecycle (migrated from AppCoordinator)

    func startTranscription(metadata: MeetingMetadata, settings: AppSettings?) async {
        sessionGeneration += 1
        defer { activeStartTask = nil }
        if let settings {
            container.ensureMeetingServicesInitialized(settings: settings, coordinator: coordinator)
        }
        if let batchAudioTranscriber = coordinator.batchAudioTranscriber {
            // Bounded: cancel() awaits the running batch job, whose CoreML /
            // model-download awaits are not cancellable mid-flight. A wedged
            // batch must not hold the Start button hostage — after 10 s we
            // abandon the old job and start the meeting anyway.
            let cancelTask = Task { await batchAudioTranscriber.cancel() }
            let finished = await TranscriptionEngine.awaitTeardown(
                of: [cancelTask], timeoutSeconds: 10
            )
            if !finished {
                Log.transcription.error("Batch cancel did not finish in 10s; starting meeting anyway")
            }
        }

        coordinator.lastEndedSession = nil
        coordinator.pendingRecoverySessionID = nil
        coordinator.lastStorageError = nil
        coordinator.transcriptStore.clear()

        await coordinator.sessionRepository.setWriteErrorHandler { [weak coordinator] message in
            Task { @MainActor [weak coordinator] in
                coordinator?.lastStorageError = message
            }
        }

        // Freeze template choice at start time
        if let template = coordinator.selectedTemplate {
            coordinator.sessionTemplateSnapshot = coordinator.templateStore.snapshot(of: template)
        } else if let generic = coordinator.templateStore.template(for: TemplateStore.genericID) {
            coordinator.sessionTemplateSnapshot = coordinator.templateStore.snapshot(of: generic)
        } else {
            coordinator.sessionTemplateSnapshot = nil
        }

        // Configure notes folder for mirroring (prefer security-scoped bookmark)
        if let settings {
            let dateSubfolderFormat = Self.dateSubfolderFormat(for: settings)
            if let resolvedURL = settings.resolveNotesFolderBookmark() {
                await coordinator.sessionRepository.setNotesFolderPath(
                    resolvedURL,
                    securityScoped: true,
                    dateSubfolderFormat: dateSubfolderFormat
                )
                coordinator.audioRecorder?.updateDirectory(resolvedURL, securityScoped: true)
            } else {
                let notesURL = URL(fileURLWithPath: settings.notesFolderPath)
                await coordinator.sessionRepository.setNotesFolderPath(
                    notesURL,
                    dateSubfolderFormat: dateSubfolderFormat
                )
                coordinator.audioRecorder?.updateDirectory(notesURL)
            }
        }

        let templateID = coordinator.selectedTemplate?.id
        let startConfig = SessionStartConfig(
            templateID: templateID,
            templateSnapshot: coordinator.sessionTemplateSnapshot,
            title: metadata.title ?? metadata.calendarEvent?.title,
            calendarEvent: metadata.calendarEvent
        )
        let handle: SessionHandle
        let reusedAbandonedRow: Bool
        if let resumed = await coordinator.sessionRepository.resumeAbandonedSession(config: startConfig) {
            handle = resumed
            reusedAbandonedRow = true
        } else {
            handle = await coordinator.sessionRepository.startSession(config: startConfig)
            reusedAbandonedRow = false
        }
        _currentSessionID = handle.sessionID
        DiagnosticsSupport.record(
            category: "meeting",
            message: "\(reusedAbandonedRow ? "Reused" : "Started") session \(handle.sessionID) model=\(settings?.transcriptionModel.rawValue ?? "unknown")"
        )
        let initialScratchpad = pendingInitialScratchpad?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingInitialScratchpad = nil
        state.scratchpadText = initialScratchpad ?? ""
        state.liveSpeakerNames = [:]
        state.liveAutoSpeakerNames = [:]
        if let initialScratchpad, !initialScratchpad.isEmpty {
            await coordinator.sessionRepository.saveScratchpad(sessionID: handle.sessionID, text: initialScratchpad)
        }

        if let settings {
            let audioRetentionPlan = Self.audioRetentionPlan(settings: settings, utteranceCount: nil)
            if audioRetentionPlan.shouldStartRecorder {
                coordinator.audioRecorder?.startSession()
                coordinator.transcriptionEngine?.audioRecorder = coordinator.audioRecorder
            } else {
                coordinator.transcriptionEngine?.audioRecorder = nil
            }

            coordinator.transcriptionEngine?.onLiveSpeakerAutoNamed = { [weak self] key, name in
                self?.applyLiveAutoSpeakerName(key: key, name: name)
            }

            await coordinator.transcriptionEngine?.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID,
                transcriptionModel: settings.transcriptionModel,
                sessionID: handle.sessionID
            )

            // Silence-based auto-stop (manual and auto-detected) is handled by the
            // adaptive audio-level evaluation in the polling loop; see
            // updateAutomaticSilenceTimeout(_:settings:).
        }
    }

    func finalizeCurrentSession(settings: AppSettings?) async {
        // A start still mid-flight (models loading) must not race this
        // teardown: cancel it and give it a bounded moment to unwind, so it
        // cannot start capture for a session that already ended.
        if let startTask = activeStartTask {
            startTask.cancel()
            _ = await TranscriptionEngine.awaitTeardown(of: [startTask], timeoutSeconds: 5)
            activeStartTask = nil
        }

        // Snapshot identity BEFORE any await: a watchdog-cancelled
        // finalization completes late instead of stopping, and must only ever
        // act on the session it was started for.
        let generation = sessionGeneration
        let sessionID: String
        if let id = _currentSessionID {
            sessionID = id
        } else if let id = await coordinator.sessionRepository.getCurrentSessionID() {
            sessionID = id
        } else {
            sessionID = "unknown"
        }

        // 0. Flush scratchpad
        scratchpadSaveTask?.cancel()
        if _currentSessionID != nil, !state.scratchpadText.isEmpty {
            await coordinator.sessionRepository.saveScratchpad(sessionID: sessionID, text: state.scratchpadText)
        }

        let captureHealthAtStop = coordinator.transcriptionEngine?.captureHealthSnapshot
        let wasMicMutedAtStop = state.isMicMuted
        let peakAudioLevelAtStop = observedPeakAudioLevelSinceStart

        // 1. Drain audio buffers
        await coordinator.transcriptionEngine?.finalize()

        // 1b. Drain pending cleanups
        if let settings, settings.enableLiveTranscriptCleanup {
            await coordinator.liveTranscriptCleaner?.drain(timeout: .seconds(5))
        }

        // 2. Drain delayed JSONL writes (bounded: a wedged writer must not
        // hang the stop chain).
        let pendingWrites = Task { await coordinator.sessionRepository.awaitPendingWrites() }
        _ = await TranscriptionEngine.awaitTeardown(of: [pendingWrites], timeoutSeconds: 8)

        guard sessionGeneration == generation else {
            Self.recordStaleFinalization(of: sessionID, step: "post-drain")
            return
        }

        // 3. Build finalization metadata
        let utterancesSnapshot = coordinator.transcriptStore.utterances
        let utteranceCount = utterancesSnapshot.count
        let endingMetadata: MeetingMetadata?
        if case .ending(let metadata) = coordinator.state {
            endingMetadata = metadata
        } else {
            endingMetadata = nil
        }
        let metadataTitle = endingMetadata?.title ?? endingMetadata?.calendarEvent?.title
        let title = coordinator.transcriptStore.conversationState.currentTopic.isEmpty
            ? metadataTitle : coordinator.transcriptStore.conversationState.currentTopic
        let meetingAppName = endingMetadata?.detectionContext?.meetingApp?.name

        let engineName = settings?.transcriptionModel.rawValue
        let transcriptionLanguage: String? = {
            guard let locale = settings?.transcriptionLocale, !locale.isEmpty else { return nil }
            return locale
        }()
        let recordingHealthInput = RecordingHealthInput(
            elapsed: max(0, Date().timeIntervalSince(endingMetadata?.startedAt ?? Date())),
            transcriptionModel: settings?.transcriptionModel ?? .parakeetV3,
            utteranceCount: utteranceCount,
            peakAudioLevel: peakAudioLevelAtStop,
            micHasCapturedFrames: captureHealthAtStop?.micHasCapturedFrames ?? false,
            systemHasCapturedFrames: captureHealthAtStop?.systemHasCapturedFrames ?? false,
            micCaptureError: captureHealthAtStop?.micCaptureError,
            isMicMuted: wasMicMutedAtStop,
            isRecordingPaused: coordinator.transcriptionEngine?.isRecordingPaused ?? false,
            hasBlockingError: false
        )
        let transcriptIssue = Self.transcriptIssue(for: recordingHealthInput)
        let emptySessionClassification = Self.emptySessionDiagnosticClassification(for: recordingHealthInput)

        // 4. Finalize: closes file handle, backfills cleaned text, writes session.json
        await coordinator.sessionRepository.finalizeSession(
            sessionID: sessionID,
            metadata: SessionFinalizeMetadata(
                endedAt: Date(),
                utteranceCount: utteranceCount,
                title: title,
                language: transcriptionLanguage,
                meetingApp: meetingAppName,
                engine: engineName,
                templateSnapshot: coordinator.sessionTemplateSnapshot,
                utterances: utterancesSnapshot,
                calendarEvent: endingMetadata?.calendarEvent,
                transcriptIssue: transcriptIssue
            )
        )

        if let settings,
           let event = endingMetadata?.calendarEvent,
           let folderPath = settings.meetingFamilyPreferences(for: event)?.folderPath {
            await coordinator.sessionRepository.updateSessionFolder(sessionID: sessionID, folderPath: folderPath)
        }

        // 5. Build index for UI state
        let index = SessionIndex(
            id: sessionID,
            startedAt: utterancesSnapshot.first?.timestamp ?? endingMetadata?.startedAt ?? Date(),
            endedAt: Date(),
            templateSnapshot: coordinator.sessionTemplateSnapshot,
            title: title,
            utteranceCount: utteranceCount,
            hasNotes: false,
            language: transcriptionLanguage,
            meetingApp: meetingAppName,
            engine: engineName,
            transcriptIssue: transcriptIssue
        )

        guard sessionGeneration == generation else {
            Self.recordStaleFinalization(of: sessionID, step: "post-sidecar")
            return
        }

        // 5b. Fire webhook if configured
        if let settings {
            WebhookService.fireIfEnabled(
                settings: settings,
                sessionIndex: index,
                utterances: utterancesSnapshot
            )
        }

        // 5c. Export to Apple Notes if configured
        if let settings {
            AppleNotesService.exportIfEnabled(
                settings: settings,
                sessionIndex: index,
                utterances: utterancesSnapshot
            )
        }

        // 6. Handle audio recording
        var retainedBatchAudio = false
        var forcedRecoveryBatch = false
        if let settings, let recorder = coordinator.audioRecorder {
            let audioRetentionPlan = Self.audioRetentionPlan(settings: settings, utteranceCount: utteranceCount)
            let wantsBatch = audioRetentionPlan.shouldRetainBatchAudio
            let wantsExport = audioRetentionPlan.shouldExportRecording
            forcedRecoveryBatch = audioRetentionPlan.shouldRunRecoveryBatch

            if wantsBatch && wantsExport {
                let tempURLs = recorder.tempFileURLs()
                let anchorsData = recorder.timingAnchors()

                // Off-main: these are full-length recording CAFs (GBs for a
                // long meeting) and a synchronous copy here beachballs the
                // whole app the moment the user hits Stop.
                let (copiedMic, copiedSys): (URL?, URL?) = await Task.detached {
                    let fm = FileManager.default
                    func copyStem(_ src: URL?, name: String) -> URL? {
                        guard let src, fm.fileExists(atPath: src.path) else { return nil }
                        let dst = URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent(name)
                        try? fm.copyItem(at: src, to: dst)
                        return fm.fileExists(atPath: dst.path) ? dst : nil
                    }
                    return (
                        copyStem(tempURLs.mic, name: "batch_mic_\(sessionID).caf"),
                        copyStem(tempURLs.sys, name: "batch_sys_\(sessionID).caf")
                    )
                }.value

                retainedBatchAudio = copiedMic != nil || copiedSys != nil
                await coordinator.sessionRepository.stashAudioForBatch(
                    sessionID: sessionID,
                    micURL: copiedMic,
                    sysURL: copiedSys,
                    anchors: BatchAnchors(
                        micStartDate: anchorsData.micStartDate,
                        sysStartDate: anchorsData.sysStartDate,
                        micAnchors: anchorsData.micAnchors,
                        sysAnchors: anchorsData.sysAnchors,
                        sysEffectiveSampleRate: anchorsData.sysEffectiveSampleRate
                    )
                )

                await recorder.finalizeRecording()
            } else if wantsBatch {
                let sealed = recorder.sealForBatch()
                retainedBatchAudio = sealed.mic != nil || sealed.sys != nil
                await coordinator.sessionRepository.stashAudioForBatch(
                    sessionID: sessionID,
                    micURL: sealed.mic,
                    sysURL: sealed.sys,
                    anchors: BatchAnchors(
                        micStartDate: sealed.micStartDate,
                        sysStartDate: sealed.sysStartDate,
                        micAnchors: sealed.micAnchors,
                        sysAnchors: sealed.sysAnchors,
                        sysEffectiveSampleRate: sealed.sysEffectiveSampleRate
                    )
                )
            } else if wantsExport {
                await recorder.finalizeRecording()
            } else {
                recorder.discardRecording()
            }
        }

        guard sessionGeneration == generation else {
            Self.recordStaleFinalization(of: sessionID, step: "post-audio")
            return
        }

        // 7. Collapse obviously empty duplicate sessions back into the real meeting session.
        var effectiveIndex = index
        var shouldRunBatchRetranscription = settings?.enableBatchRetranscription == true
        var mergedSessionID: String?
        if forcedRecoveryBatch {
            if retainedBatchAudio {
                shouldRunBatchRetranscription = true
                DiagnosticsSupport.record(
                    category: "meeting",
                    message: "Escalating empty cloud session \(sessionID) to batch recovery"
                )
            } else {
                DiagnosticsSupport.record(
                    category: "meeting",
                    message: "Cloud session \(sessionID) ended empty with no recovery audio"
                )
            }
        }
        if utteranceCount == 0,
           let merged = await coordinator.sessionRepository.reconcileGhostSession(sessionID: sessionID) {
            mergedSessionID = merged
            effectiveIndex = await coordinator.sessionRepository.loadSession(id: merged).index
            shouldRunBatchRetranscription = false
            DiagnosticsSupport.record(
                category: "meeting",
                message: "Collapsed empty duplicate session \(sessionID) into \(merged)"
            )
        }

        let queuedRecoveryBatch = shouldRunBatchRetranscription && coordinator.batchAudioTranscriber != nil
        if utteranceCount == 0, let classification = emptySessionClassification {
            let recoveryResult: String
            if mergedSessionID != nil {
                recoveryResult = "collapsed_into_existing_session"
            } else if queuedRecoveryBatch {
                recoveryResult = "queued"
            } else if forcedRecoveryBatch && !retainedBatchAudio {
                recoveryResult = "unavailable_no_retained_audio"
            } else {
                recoveryResult = "not_attempted"
            }
            recordEmptySessionDiagnostics(
                EmptySessionDiagnosticsEvent(
                    event: "live_empty_session_finalized",
                    sessionID: sessionID,
                    transcriptionModel: recordingHealthInput.transcriptionModel.rawValue,
                    elapsedSeconds: Int(recordingHealthInput.elapsed.rounded()),
                    utteranceCount: recordingHealthInput.utteranceCount,
                    peakAudioLevel: recordingHealthInput.peakAudioLevel,
                    micCapturedFrames: recordingHealthInput.micHasCapturedFrames,
                    systemCapturedFrames: recordingHealthInput.systemHasCapturedFrames,
                    micCaptureError: recordingHealthInput.micCaptureError,
                    classification: classification.rawValue,
                    retainedRecoveryAudio: retainedBatchAudio,
                    recoveryBatchAttempted: queuedRecoveryBatch,
                    recoveryResult: recoveryResult,
                    finalUtteranceCount: nil,
                    mergedIntoSessionID: mergedSessionID,
                    failureMessage: nil
                )
            )
            if queuedRecoveryBatch {
                pendingRecoveryDiagnostics = PendingRecoveryDiagnostics(
                    sessionID: sessionID,
                    transcriptionModel: recordingHealthInput.transcriptionModel.rawValue,
                    classification: classification
                )
                coordinator.pendingRecoverySessionID = sessionID
            } else {
                pendingRecoveryDiagnostics = nil
                coordinator.pendingRecoverySessionID = nil
            }
        } else {
            pendingRecoveryDiagnostics = nil
            coordinator.pendingRecoverySessionID = nil
        }

        guard sessionGeneration == generation else {
            Self.recordStaleFinalization(of: sessionID, step: "post-reconcile")
            return
        }

        // 8. Update UI state + refresh history
        coordinator.lastEndedSession = effectiveIndex
        set(\.lastEndedSessionCanRetranscribe, retainedBatchAudio)
        coordinator.sessionTemplateSnapshot = nil
        _currentSessionID = nil
        DiagnosticsSupport.record(
            category: "meeting",
            message: "Finalized session \(effectiveIndex.id) utterances=\(utteranceCount) batch=\(shouldRunBatchRetranscription ? "on" : "off")"
        )
        await coordinator.loadHistory()

        let willRunBatchRetranscription = shouldRunBatchRetranscription && coordinator.batchAudioTranscriber != nil

        if let settings {
            scheduleAutoNotesIfNeeded(
                for: effectiveIndex,
                settings: settings,
                waitForBatch: willRunBatchRetranscription
            )
        }

        // 9. Kick off batch transcription if enabled
        if let settings, willRunBatchRetranscription, let batchAudioTranscriber = coordinator.batchAudioTranscriber {
            let batchSessionID = sessionID
            let batchModel = settings.batchTranscriptionModel
            let batchLocale = settings.locale
            let notesDir = URL(fileURLWithPath: settings.notesFolderPath)
            let repo = coordinator.sessionRepository
            let diarize = settings.enableDiarization
            let diarizeMic = settings.enableMicDiarization
            let diarizeVariant = settings.diarizationVariant
            let expectedSpeakers = settings.expectedInRoomSpeakers > 0 ? settings.expectedInRoomSpeakers : nil
            let selfReferences = coordinator.transcriptionEngine?.lastLiveSelfReferences ?? []
            Task.detached { [batchAudioTranscriber] in
                await batchAudioTranscriber.process(
                    sessionID: batchSessionID,
                    model: batchModel,
                    locale: batchLocale,
                    sessionRepository: repo,
                    notesDirectory: notesDir,
                    enableDiarization: diarize,
                    enableMicDiarization: diarizeMic,
                    diarizationVariant: diarizeVariant,
                    expectedInRoomSpeakers: expectedSpeakers,
                    liveSelfReferences: selfReferences
                )
            }
        }
    }

    private static func recordStaleFinalization(of sessionID: String, step: String) {
        DiagnosticsSupport.record(
            category: "meeting",
            message: "Stale finalization of \(sessionID) aborted at \(step) (newer session active)"
        )
    }

    private func scheduleAutoNotesIfNeeded(
        for session: SessionIndex,
        settings: AppSettings,
        waitForBatch: Bool
    ) {
        guard settings.canAutoGeneratePostMeetingNotes else {
            pendingAutoNotesSessionID = nil
            return
        }

        if waitForBatch {
            pendingAutoNotesSessionID = session.id
            return
        }

        guard session.utteranceCount > 0 else { return }
        startAutoNotesGeneration(sessionID: session.id, settings: settings)
    }

    private func resumePendingAutoNotesIfNeeded(
        for status: BatchAudioTranscriber.Status,
        settings: AppSettings
    ) {
        guard let pendingSessionID = pendingAutoNotesSessionID else { return }

        switch status {
        case .completed(let sessionID) where sessionID == pendingSessionID:
            pendingAutoNotesSessionID = nil
            startAutoNotesGeneration(sessionID: sessionID, settings: settings)
        case .failed, .cancelled:
            pendingAutoNotesSessionID = nil
            startAutoNotesGeneration(sessionID: pendingSessionID, settings: settings)
        default:
            break
        }
    }

    private func startAutoNotesGeneration(sessionID: String, settings: AppSettings) {
        guard settings.canAutoGeneratePostMeetingNotes else { return }
        guard autoGeneratingNotesSessionID != sessionID else { return }

        autoGeneratingNotesSessionID = sessionID
        Task { [weak self] in
            await self?.generatePostMeetingNotes(sessionID: sessionID, settings: settings)
        }
    }

    private func generatePostMeetingNotes(sessionID: String, settings: AppSettings) async {
        defer {
            if autoGeneratingNotesSessionID == sessionID {
                autoGeneratingNotesSessionID = nil
            }
        }

        let sessionDetail = await coordinator.sessionRepository.loadSession(id: sessionID)
        let session = sessionDetail.index
        guard !session.hasNotes else { return }
        guard session.utteranceCount > 0 else { return }

        let sessionData = await coordinator.sessionRepository.loadSessionData(sessionID: sessionID)
        guard !sessionData.transcript.isEmpty else { return }
        let customGuidance = await coordinator.sessionRepository.loadCustomNotesGuidance(sessionID: sessionID)

        let template = resolvedNotesTemplate(
            for: session,
            calendarEvent: sessionData.calendarEvent,
            settings: settings
        )
        let scratchpad = await coordinator.sessionRepository.loadScratchpad(sessionID: sessionID)

        do {
            let generatedMarkdown = try await coordinator.notesEngine.generateMarkdownDetached(
                transcript: sessionData.transcript,
                speakerNames: session.speakerNames,
                template: template,
                settings: settings,
                calendarEvent: sessionData.calendarEvent,
                scratchpad: scratchpad.isEmpty ? nil : scratchpad,
                customGuidance: customGuidance
            )

            let notes = GeneratedNotes(
                template: coordinator.templateStore.snapshot(of: template),
                generatedAt: Date(),
                markdown: GeneratedNotes.normalizedMarkdown(
                    generatedMarkdown,
                    title: session.title,
                    date: session.startedAt
                )
            )

            await coordinator.sessionRepository.saveNotes(sessionID: sessionID, notes: notes)
            await coordinator.loadHistory()

            if coordinator.lastEndedSession?.id == sessionID {
                coordinator.lastEndedSession = await coordinator.sessionRepository.loadSession(id: sessionID).index
            }

            syncProjectedState(settings: settings)
            DiagnosticsSupport.record(
                category: "meeting",
                message: "Auto-generated post-meeting notes for \(sessionID)"
            )
        } catch {
            DiagnosticsSupport.record(
                category: "meeting",
                message: "Auto-generated post-meeting notes failed for \(sessionID): \(error.localizedDescription)"
            )
        }
    }

    private func resolvedNotesTemplate(
        for session: SessionIndex,
        calendarEvent: CalendarEvent?,
        settings: AppSettings
    ) -> MeetingTemplate {
        NotesTemplateResolver.resolve(
            templateStore: coordinator.templateStore,
            settings: settings,
            sessionTemplateSnapshot: session.templateSnapshot,
            meetingFamilyEvent: calendarEvent,
            meetingFamilyKey: session.meetingFamilyKey
        ) ?? TemplateStore.builtInTemplates.first!
    }

    static func audioRetentionPlan(settings: AppSettings, utteranceCount: Int?) -> AudioRetentionPlan {
        let shouldRunRecoveryBatch = settings.transcriptionModel.isCloud && utteranceCount == 0
        let shouldRetainBatchAudio = settings.enableBatchRetranscription || shouldRunRecoveryBatch
        let shouldExportRecording = settings.saveAudioRecording
        let shouldStartRecorder = shouldExportRecording || shouldRetainBatchAudio || settings.transcriptionModel.isCloud
        return AudioRetentionPlan(
            shouldStartRecorder: shouldStartRecorder,
            shouldRetainBatchAudio: shouldRetainBatchAudio,
            shouldExportRecording: shouldExportRecording,
            shouldRunRecoveryBatch: shouldRunRecoveryBatch
        )
    }

    private static func dateSubfolderFormat(for settings: AppSettings) -> MeetingTranscriptDateFolderFormat? {
        settings.saveMeetingTranscriptsInDateSubfolders ? settings.meetingTranscriptDateFolderFormat : nil
    }

    static func transcriptIssue(for input: RecordingHealthInput) -> SessionTranscriptIssue? {
        guard input.utteranceCount == 0 else { return nil }

        if let micCaptureError = input.micCaptureError, !micCaptureError.isEmpty {
            return .noAudioDetected
        }

        if input.elapsed >= 5,
           !input.systemHasCapturedFrames,
           (!input.isMicMuted && !input.micHasCapturedFrames) {
            return .noAudioDetected
        }

        if input.peakAudioLevel >= 0.04,
           input.micHasCapturedFrames || input.systemHasCapturedFrames {
            return .transcriptionProducedNoText
        }

        return nil
    }

    static func recordingHealthNotice(for input: RecordingHealthInput) -> RecordingHealthNotice? {
        guard !input.hasBlockingError else { return nil }
        guard !input.isRecordingPaused else { return nil }

        if let micCaptureError = input.micCaptureError, !micCaptureError.isEmpty {
            return RecordingHealthNotice(severity: .error, message: micCaptureError)
        }

        if input.elapsed >= 5 {
            if !input.systemHasCapturedFrames && (!input.isMicMuted && !input.micHasCapturedFrames) {
                return RecordingHealthNotice(
                    severity: .warning,
                    message: "No microphone or system audio detected. Check your input and output device settings."
                )
            }
            if !input.systemHasCapturedFrames {
                return RecordingHealthNotice(
                    severity: .warning,
                    message: "No system audio detected. Check the selected speaker/output device."
                )
            }
            if !input.isMicMuted && !input.micHasCapturedFrames {
                return RecordingHealthNotice(
                    severity: .warning,
                    message: "No microphone audio detected. Check the selected microphone."
                )
            }
        }

        if input.elapsed >= 20,
           input.utteranceCount == 0,
           input.peakAudioLevel >= 0.04,
           input.micHasCapturedFrames || input.systemHasCapturedFrames {
            let message: String
            if input.transcriptionModel.isCloud {
                message = "Capturing audio, but live transcription is not producing text. Recovery batch transcription will run after you stop."
            } else {
                message = "Capturing audio, but live transcription is not producing text."
            }
            return RecordingHealthNotice(severity: .warning, message: message)
        }

        return nil
    }

    static func emptySessionDiagnosticClassification(for input: RecordingHealthInput) -> EmptySessionDiagnosticClassification? {
        guard input.utteranceCount == 0 else { return nil }

        if let micCaptureError = input.micCaptureError, !micCaptureError.isEmpty {
            return .noAudioDetected
        }

        if input.elapsed >= 5,
           !input.systemHasCapturedFrames,
           (!input.isMicMuted && !input.micHasCapturedFrames) {
            return .noAudioDetected
        }

        if input.peakAudioLevel >= 0.04,
           input.micHasCapturedFrames || input.systemHasCapturedFrames {
            return .transcriptionProducedNoText
        }

        return .unclassified
    }

    static func emptySessionDiagnosticsMessage(for event: EmptySessionDiagnosticsEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(event),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "event=\(event.event) session_id=\(event.sessionID) classification=\(event.classification)"
    }

    static func liveTranscriptNotice(
        for model: TranscriptionModel,
        issue: CloudTranscriptCopy.Presentation? = nil,
        isProcessing: Bool = false
    ) -> String? {
        if let issue {
            return issue.title
        }
        if isProcessing {
            return CloudTranscriptCopy.processingChunk.title
        }
        return CloudTranscriptCopy.steadyStateNotice(for: model)
    }

    static func liveTranscriptEmptyStateMessage(
        for model: TranscriptionModel,
        issue: CloudTranscriptCopy.Presentation? = nil,
        isProcessing: Bool = false
    ) -> String? {
        if let issue {
            return issue.detail
        }
        if isProcessing {
            return CloudTranscriptCopy.processingChunk.detail
        }
        return CloudTranscriptCopy.waitingMessage(for: model)
    }

    static func recordingElapsedSeconds(for state: MeetingState) -> Int {
        let startedAt: Date?
        switch state {
        case .recording(let metadata), .ending(let metadata):
            startedAt = metadata.startedAt
        case .idle:
            startedAt = nil
        }

        guard let startedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(startedAt)))
    }

    /// Advance the ambient noise floor estimate toward `level` over `dt`
    /// seconds, falling fast and rising slowly so brief sounds don't inflate it.
    static func updatedNoiseFloor(current: Float, level: Float, dt: TimeInterval) -> Float {
        guard dt > 0 else { return current }
        let tau = level < current ? noiseFloorFallTimeConstant : noiseFloorRiseTimeConstant
        let alpha = Float(1 - exp(-dt / tau))
        return current + (level - current) * alpha
    }

    /// Decide whether a recording should auto-stop after a sustained quiet
    /// period. Rather than comparing the level to a fixed threshold (which
    /// fails because a live mic's noise floor sits well above any fixed
    /// "silence" value), this tracks the ambient floor for *this* mic and
    /// treats audio as activity only when it rises clearly above that floor.
    static func automaticSilenceTimeoutEvaluation(
        isRunning: Bool,
        isRecordingPaused: Bool,
        audioLevel: Float,
        now: Date,
        tracking: SilenceTracking,
        timeoutInterval: TimeInterval = automaticSilenceTimeoutInterval,
        absoluteAudibleThreshold: Float = audibleActivityLevelThreshold,
        activityMargin: Float = audibleActivityMargin
    ) -> AutomaticSilenceTimeoutEvaluation {
        guard isRunning else {
            return AutomaticSilenceTimeoutEvaluation(tracking: .initial, shouldStop: false)
        }

        guard !isRecordingPaused else {
            // Don't accrue silence while paused; keep the floor estimate so it
            // doesn't have to re-converge on resume.
            return AutomaticSilenceTimeoutEvaluation(
                tracking: SilenceTracking(
                    lastAudibleActivityAt: now,
                    noiseFloor: tracking.noiseFloor,
                    lastSampleAt: now
                ),
                shouldStop: false
            )
        }

        // Seed the floor with the first observed level so it calibrates to this
        // mic immediately rather than ramping up from zero.
        let isFirstSample = tracking.lastSampleAt == nil
        let dt: TimeInterval = isFirstSample
            ? 0
            : min(max(0, now.timeIntervalSince(tracking.lastSampleAt!)), noiseFloorMaxSampleInterval)
        let priorFloor = isFirstSample ? audioLevel : tracking.noiseFloor
        let noiseFloor = updatedNoiseFloor(current: priorFloor, level: audioLevel, dt: dt)

        // Audible when the level clearly exceeds the ambient floor (or the
        // absolute backstop, whichever is higher).
        let dynamicThreshold = max(absoluteAudibleThreshold, noiseFloor * activityMargin)
        let isAudible = audioLevel > dynamicThreshold

        if isAudible {
            return AutomaticSilenceTimeoutEvaluation(
                tracking: SilenceTracking(
                    lastAudibleActivityAt: now,
                    noiseFloor: noiseFloor,
                    lastSampleAt: now
                ),
                shouldStop: false
            )
        }

        let lastActivity = tracking.lastAudibleActivityAt ?? now
        return AutomaticSilenceTimeoutEvaluation(
            tracking: SilenceTracking(
                lastAudibleActivityAt: lastActivity,
                noiseFloor: noiseFloor,
                lastSampleAt: now
            ),
            shouldStop: now.timeIntervalSince(lastActivity) >= timeoutInterval
        )
    }

    private func recordEmptySessionDiagnostics(_ event: EmptySessionDiagnosticsEvent) {
        let message = Self.emptySessionDiagnosticsMessage(for: event)
        DiagnosticsSupport.record(category: "meeting", message: message)
        Log.diagnostics.info("\(message, privacy: .public)")
    }

    func discardSession() {
        sessionGeneration += 1
        activeStartTask?.cancel()
        activeStartTask = nil
        coordinator.transcriptionEngine?.stop()
        coordinator.audioRecorder?.discardRecording()
        coordinator.transcriptStore.clear()
        coordinator.pendingRecoverySessionID = nil
        let discardedSessionID = _currentSessionID
        if let discardedSessionID {
            DiagnosticsSupport.record(category: "meeting", message: "Discarded session \(discardedSessionID)")
        }
        _currentSessionID = nil
        Task {
            // Session-checked: a quick restart after discard must not have its
            // fresh live file handle closed by this stale teardown.
            await coordinator.sessionRepository.endSession(sessionID: discardedSessionID)
        }
    }

    // MARK: - State Refresh

    /// Assigns `value` to `state[keyPath:]` only when it differs, avoiding spurious
    /// @Observable withMutation notifications that would trigger unnecessary layout passes.
    @inline(__always)
    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<LiveSessionState, T>, _ value: T) {
        if state[keyPath: kp] != value { state[keyPath: kp] = value }
    }

    private func refreshLastEndedSessionRetranscriptionAvailability(for sessionID: String?) {
        guard let sessionID else {
            set(\.lastEndedSessionCanRetranscribe, false)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let canRetranscribe = await coordinator.sessionRepository.hasRetainedBatchAudio(sessionID: sessionID)
            await MainActor.run {
                guard self.state.lastEndedSession?.id == sessionID else { return }
                self.set(\.lastEndedSessionCanRetranscribe, canRetranscribe)
            }
        }
    }

    // MARK: - Live Transcription Lag Detection

    /// Detects a live channel that is audibly active while its side of the
    /// transcript has stopped progressing — the signature of live ASR falling
    /// behind under load. The recorded audio is unaffected (the batch pass
    /// rebuilds the transcript from it), so this only drives a notice.
    struct ChannelLagTracker {
        static let speechLevel: Float = 0.15
        static let stallSeconds: TimeInterval = 15
        /// Cumulative audible time required since the last progress before a
        /// stall counts as lag — a single chime or brief noise must not latch
        /// the notice on.
        static let minVoicedSeconds: TimeInterval = 2.5

        private var progressCount = -1
        private var volatileSnapshot = ""
        private var lastProgressAt: Date?
        private var lastVoiceAt: Date?
        private var voicedSecondsSinceProgress: TimeInterval = 0
        private var lastSampleAt: Date?

        mutating func reset() {
            progressCount = -1
            volatileSnapshot = ""
            lastProgressAt = nil
            lastVoiceAt = nil
            voicedSecondsSinceProgress = 0
            lastSampleAt = nil
        }

        mutating func isLagging(now: Date, level: Float, progress: Int, volatileText: String) -> Bool {
            let elapsed = lastSampleAt.map { min(now.timeIntervalSince($0), 1.0) } ?? 0
            lastSampleAt = now
            if lastProgressAt == nil { lastProgressAt = now }
            if progress != progressCount || volatileText != volatileSnapshot {
                progressCount = progress
                volatileSnapshot = volatileText
                lastProgressAt = now
                voicedSecondsSinceProgress = 0
            }
            if level >= Self.speechLevel {
                lastVoiceAt = now
                voicedSecondsSinceProgress += elapsed
            }
            guard let progressAt = lastProgressAt, let voiceAt = lastVoiceAt else { return false }
            // Sustained speech with no progress, and the channel is still
            // audible recently — decays once the room goes quiet.
            return voicedSecondsSinceProgress >= Self.minVoicedSeconds
                && now.timeIntervalSince(voiceAt) <= Self.stallSeconds
                && now.timeIntervalSince(progressAt) > Self.stallSeconds
        }
    }

    private var micLagTracker = ChannelLagTracker()
    private var sysLagTracker = ChannelLagTracker()

    static let liveTranscriptLagNotice =
        "Live transcription is falling behind. The full transcript is rebuilt automatically after the meeting."

    /// Per-channel live status: lag flags plus the display activity.
    private struct LiveChannelStatus {
        var micLagging = false
        var sysLagging = false
        var activity: LiveChannelActivity = .idle

        var isLagging: Bool { micLagging || sysLagging }
    }

    @MainActor
    private func liveChannelStatus(isRunning: Bool, transcript: [Utterance]) -> LiveChannelStatus {
        guard isRunning, let engine = coordinator.transcriptionEngine else {
            micLagTracker.reset()
            sysLagTracker.reset()
            return LiveChannelStatus()
        }
        let now = Date()
        var remoteCount = 0
        for utterance in transcript where utterance.speaker.isRemote { remoteCount += 1 }
        let micLevel = engine.micAudioLevel
        let sysLevel = engine.systemAudioLevel
        let volatileYou = coordinator.transcriptStore.volatileYouText
        let volatileThem = coordinator.transcriptStore.volatileThemText
        let micLagging = micLagTracker.isLagging(
            now: now,
            level: micLevel,
            progress: transcript.count - remoteCount,
            volatileText: volatileYou
        )
        let sysLagging = sysLagTracker.isLagging(
            now: now,
            level: sysLevel,
            progress: remoteCount,
            volatileText: volatileThem
        )
        let micActivity = Self.channelActivity(level: micLevel, volatileText: volatileYou, isLagging: micLagging)
        let sysActivity = Self.channelActivity(level: sysLevel, volatileText: volatileThem, isLagging: sysLagging)
        return LiveChannelStatus(
            micLagging: micLagging,
            sysLagging: sysLagging,
            activity: max(micActivity, sysActivity)
        )
    }

    static func channelActivity(level: Float, volatileText: String, isLagging: Bool) -> LiveChannelActivity {
        if isLagging { return .behind }
        if !volatileText.isEmpty { return .transcribing }
        if level >= ChannelLagTracker.speechLevel { return .hearing }
        return .idle
    }

    @MainActor
    private func refreshState(settings: AppSettings) {
        let lastEndedSession = coordinator.lastEndedSession
        let lastSessionHasNotes = lastEndedSession.flatMap { lastSession in
            coordinator.sessionHistory.first { $0.id == lastSession.id }?.hasNotes
        } ?? false

        let activeModelRaw = settings.activeNotesModel

        let sidebarSuggestions: [Suggestion]
        let sidebarGenerating: Bool
        switch settings.sidebarMode {
        case .classicSuggestions:
            sidebarSuggestions = coordinator.suggestionEngine?.suggestions ?? []
            sidebarGenerating = coordinator.suggestionEngine?.isGenerating ?? false
        case .sidecast:
            sidebarSuggestions = coordinator.sidecastEngine?.suggestions ?? []
            sidebarGenerating = coordinator.sidecastEngine?.isGenerating ?? false
        }

        let lifecycleState = coordinator.state
        let engineIsRunning = coordinator.transcriptionEngine?.isRunning ?? false
        let activeTranscriptionModel = coordinator.transcriptionEngine?.currentTranscriptionModel() ?? settings.transcriptionModel
        let liveCloudIssue = coordinator.transcriptionEngine?.liveCloudTranscriptIssue
        let liveCloudIsProcessing = coordinator.transcriptionEngine?.liveCloudTranscriptionIsProcessing ?? false
        let isRunning: Bool
        let matchedCalendarEvent: CalendarEvent?
        switch lifecycleState {
        case .recording(let metadata):
            // Prefer lifecycle state so the primary UI does not lag engine startup.
            isRunning = true
            matchedCalendarEvent = metadata.calendarEvent
        case .ending(let metadata):
            isRunning = engineIsRunning
            matchedCalendarEvent = metadata.calendarEvent
        case .idle:
            isRunning = false
            matchedCalendarEvent = nil
        }

        // Use set(_:_:) for all Equatable fields: only fires @Observable withMutation
        // when the value actually changed, preventing spurious layout passes on NSHostingView.
        set(\.isRunning, isRunning)
        set(\.sessionPhase, lifecycleState)
        set(\.audioLevel, engineIsRunning ? (coordinator.transcriptionEngine?.audioLevel ?? 0) : 0)
        set(\.recordingElapsedSeconds, isRunning ? Self.recordingElapsedSeconds(for: lifecycleState) : 0)
        set(\.volatileYouText, coordinator.transcriptStore.volatileYouText)
        set(\.volatileThemText, coordinator.transcriptStore.volatileThemText)
        set(\.isGeneratingSuggestions, sidebarGenerating)
        set(\.batchStatus, coordinator.batchStatus)
        set(\.batchIsImporting, coordinator.batchIsImporting)
        let previousLastEndedSessionID = state.lastEndedSession?.id
        let currentLastEndedSessionID = lastEndedSession?.id
        if previousLastEndedSessionID != currentLastEndedSessionID {
            state.lastEndedSession = lastEndedSession
            set(\.lastEndedSessionCanRetranscribe, false)
            refreshLastEndedSessionRetranscriptionAvailability(for: currentLastEndedSessionID)
        } else if state.lastEndedSession != lastEndedSession {
            state.lastEndedSession = lastEndedSession
        }
        set(\.lastSessionHasNotes, lastSessionHasNotes)
        set(\.kbIndexingStatus, coordinator.knowledgeBase?.indexingStatus ?? .idle)
        set(\.statusMessage, coordinator.transcriptionEngine?.assetStatus)
        set(\.errorMessage, coordinator.transcriptionEngine?.lastError)
        set(\.matchedCalendarEvent, matchedCalendarEvent)
        set(\.needsDownload, coordinator.transcriptionEngine?.needsModelDownload ?? false)
        set(\.downloadProgress, coordinator.transcriptionEngine?.downloadProgress)
        set(\.transcriptionPrompt, settings.transcriptionModel.downloadPrompt)
        set(\.modelDisplayName, activeModelRaw.split(separator: "/").last.map(String.init) ?? activeModelRaw)
        set(\.showLiveTranscript, settings.showLiveTranscript)
        let nextTranscript = coordinator.transcriptStore.utterances
        let baseNotice = isRunning
            ? Self.liveTranscriptNotice(for: activeTranscriptionModel, issue: liveCloudIssue, isProcessing: liveCloudIsProcessing)
            : nil
        let channelStatus = liveChannelStatus(isRunning: isRunning, transcript: nextTranscript)
        // A storage write failure outranks every other notice: the meeting is
        // running but its transcript is not reaching disk. This is the only
        // surface for coordinator.lastStorageError — without it the failure
        // is invisible until the user discovers an empty meeting.
        let storageNotice = (isRunning && coordinator.lastStorageError != nil)
            ? "Recording isn't being saved to disk (\(coordinator.lastStorageError!)). Free up space or check permissions."
            : nil
        set(\.liveTranscriptNotice, storageNotice ?? baseNotice ?? (channelStatus.isLagging ? Self.liveTranscriptLagNotice : nil))
        set(\.liveChannelActivity, channelStatus.activity)
        set(\.liveTranscriptEmptyStateMessage, isRunning ? Self.liveTranscriptEmptyStateMessage(for: activeTranscriptionModel, issue: liveCloudIssue, isProcessing: liveCloudIsProcessing) : nil)
        set(\.isMicMuted, coordinator.transcriptionEngine?.isMicMuted ?? false)
        set(\.isRecordingPaused, coordinator.transcriptionEngine?.isRecordingPaused ?? false)
        // scratchpadText is managed by updateScratchpad(), not refreshed from coordinator
        // downloadDetail is not Equatable; only update when nil-ness changes or download active
        let nextDetail = coordinator.transcriptionEngine?.downloadDetail
        if nextDetail != nil || state.downloadDetail != nil {
            state.downloadDetail = nextDetail
        }

        // Arrays: compare by ID before assigning — array assignment always fires observation.
        if state.liveTranscript != nextTranscript {
            state.liveTranscript = nextTranscript
        }
        if state.suggestions != sidebarSuggestions {
            state.suggestions = sidebarSuggestions
        }
    }

    // MARK: - Live Speaker Corrections

    /// Records a live library match for a speaker (from the transcription
    /// engine's voice matcher). Display-only: the user's own renames win, and
    /// the batch pass re-derives library names for the saved transcript, so
    /// nothing is persisted here.
    func applyLiveAutoSpeakerName(key: String, name: String) {
        guard _currentSessionID != nil else { return }
        guard state.liveAutoSpeakerNames[key] != name else { return }
        state.liveAutoSpeakerNames[key] = name
    }

    /// Assigns a name to a live speaker (empty name clears it). Persists to the
    /// session immediately so notes generation and the batch pass see it.
    func renameLiveSpeaker(_ speaker: Speaker, to name: String) {
        guard let sessionID = _currentSessionID else { return }
        var names = state.liveSpeakerNames
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == speaker.displayLabel {
            names.removeValue(forKey: speaker.storageKey)
        } else {
            names[speaker.storageKey] = trimmed
        }
        state.liveSpeakerNames = names
        if case .local(let n) = speaker {
            // A manual name (typed or picked from saved voices / invitees) pins
            // the voice: live scoring must not fold it into "You" or rename it.
            // Clearing the name reverses the pin so scoring can resume.
            let isAssignment = !trimmed.isEmpty && trimmed != speaker.displayLabel
            Task {
                if isAssignment {
                    await coordinator.transcriptionEngine?.pinMicSpeakerUserAssigned(
                        localSpeakerNumber: n
                    )
                } else {
                    await coordinator.transcriptionEngine?.unpinMicSpeakerUserAssigned(
                        localSpeakerNumber: n
                    )
                }
            }
        }
        Task {
            await coordinator.sessionRepository.updateSessionSpeakerNames(
                sessionID: sessionID, speakerNames: names
            )
        }
    }

    /// Live "This is me" on a lettered in-person speaker: the reverse of
    /// markLiveUtteranceNotMe. Pins the voice as the user, folds the letter's
    /// bubbles into "You", and clears any name attached to the letter.
    func assignLiveSpeakerToMe(_ speaker: Speaker) {
        guard case .local(let n) = speaker else { return }
        state.liveAutoSpeakerNames.removeValue(forKey: speaker.storageKey)
        // Clear a stale name directly, NOT via renameLiveSpeaker: its unpin
        // side effect would race the self pin below, and unpin-after-markSelf
        // silently undoes "This is me".
        if state.liveSpeakerNames[speaker.storageKey] != nil,
           let sessionID = _currentSessionID {
            var names = state.liveSpeakerNames
            names.removeValue(forKey: speaker.storageKey)
            state.liveSpeakerNames = names
            Task {
                await coordinator.sessionRepository.updateSessionSpeakerNames(
                    sessionID: sessionID, speakerNames: names
                )
            }
        }
        Task {
            await coordinator.transcriptionEngine?.assignMicSpeakerToSelf(localSpeakerNumber: n)
            coordinator.transcriptStore.relabel(from: speaker, to: .you)
            // An in-flight classify task may have republished the auto-name
            // between the synchronous clear above and the pin landing; clear
            // again now that the matcher can no longer produce one.
            state.liveAutoSpeakerNames.removeValue(forKey: speaker.storageKey)
        }
    }

    /// Live "Not me" on a You-labeled mic line: tells the voiceprint matcher
    /// that voice is someone else (future lines letter automatically) and moves
    /// this line off "You". Bulk cleanup of earlier lines is left to the batch
    /// pass, which re-attributes everything anyway.
    func markLiveUtteranceNotMe(_ utterance: Utterance) {
        guard utterance.speaker == .you,
              let start = utterance.startTime, let end = utterance.endTime else { return }
        Task {
            guard let engine = coordinator.transcriptionEngine else { return }
            let letter = await engine.markMicVoiceNotSelf(startTime: start, endTime: end)
            coordinator.transcriptStore.updateSpeaker(
                utteranceID: utterance.id, to: letter ?? .local(1)
            )
        }
    }

    // MARK: - Derived State Synchronization

    /// Callback for MiniBar show/hide — set by the view.
    var onRunningStateChanged: ((_ isRunning: Bool) -> Void)?
    /// Called when minibar-visible state changes during recording.
    var onMiniBarContentUpdate: (() -> Void)?

    /// Callback for opening the notes window — set by the view.
    var openNotesWindow: (() -> Void)?

    @MainActor
    private func synchronizeDerivedState(settings: AppSettings) {
        let currentState = state

        if let observedKBFolderPath {
            if settings.kbFolderPath != observedKBFolderPath {
                self.observedKBFolderPath = settings.kbFolderPath
                if settings.kbFolderPath.isEmpty {
                    coordinator.knowledgeBase?.clear()
                } else {
                    indexKBIfNeeded(settings: settings)
                }
            }
        } else {
            observedKBFolderPath = settings.kbFolderPath
            if settings.kbFolderPath.isEmpty {
                coordinator.knowledgeBase?.clear()
            } else {
                loadKBCacheIfAvailable(settings: settings)
            }
        }

        let dateSubfolderFormat = Self.dateSubfolderFormat(for: settings)
        if settings.notesFolderPath != observedNotesFolderPath
            || dateSubfolderFormat != observedMeetingTranscriptDateFolderFormat {
            observedNotesFolderPath = settings.notesFolderPath
            observedMeetingTranscriptDateFolderFormat = dateSubfolderFormat
            if let resolvedURL = settings.resolveNotesFolderBookmark() {
                Task {
                    await coordinator.sessionRepository.setNotesFolderPath(
                        resolvedURL,
                        securityScoped: true,
                        dateSubfolderFormat: dateSubfolderFormat
                    )
                }
                coordinator.audioRecorder?.updateDirectory(resolvedURL, securityScoped: true)
            } else {
                let url = URL(fileURLWithPath: settings.notesFolderPath)
                Task {
                    await coordinator.sessionRepository.setNotesFolderPath(
                        url,
                        dateSubfolderFormat: dateSubfolderFormat
                    )
                }
                coordinator.audioRecorder?.updateDirectory(url)
            }
        }

        if settings.kbFolderPath.isEmpty {
            observedEmbeddingProvider = nil
            observedVoyageApiKey = nil
        } else {
            if let observedEmbeddingProvider {
                if settings.embeddingProvider != observedEmbeddingProvider {
                    self.observedEmbeddingProvider = settings.embeddingProvider
                    indexKBIfNeeded(settings: settings)
                }
            } else {
                observedEmbeddingProvider = settings.embeddingProvider
            }

            if settings.embeddingProvider == .voyageAI {
                if settings.isSecretLoaded("voyageApiKey") {
                    let voyageApiKey = settings.voyageApiKey
                    if let observedVoyageApiKey {
                        if voyageApiKey != observedVoyageApiKey {
                            self.observedVoyageApiKey = voyageApiKey
                            indexKBIfNeeded(settings: settings)
                        }
                    } else {
                        observedVoyageApiKey = voyageApiKey
                    }
                }
            } else {
                observedVoyageApiKey = nil
            }
        }

        if settings.transcriptionModel != observedTranscriptionModel {
            observedTranscriptionModel = settings.transcriptionModel
            coordinator.transcriptionEngine?.refreshModelAvailability()
        }

        if settings.inputDeviceID != observedInputDeviceID {
            observedInputDeviceID = settings.inputDeviceID
            if currentState.isRunning {
                Task {
                    coordinator.transcriptionEngine?.restartMic(inputDeviceID: settings.inputDeviceID)
                }
            }
        }

        let utteranceCount = currentState.liveTranscript.count
        if utteranceCount > observedUtteranceCount {
            handleNewUtterances(startingAt: observedUtteranceCount, settings: settings)
        }
        observedUtteranceCount = utteranceCount

        if currentState.isRunning {
            observedPeakAudioLevelSinceStart = max(observedPeakAudioLevelSinceStart, currentState.audioLevel)
            if case .recording(let metadata) = currentState.sessionPhase {
                let captureHealth = coordinator.transcriptionEngine?.captureHealthSnapshot
                if captureHealth?.systemHasCapturedFrames == true {
                    observedSystemHasEverCapturedFrames = true
                }
                if captureHealth?.micHasCapturedFrames == true {
                    observedMicHasEverCapturedFrames = true
                }
                let input = RecordingHealthInput(
                    elapsed: max(0, Date().timeIntervalSince(metadata.startedAt)),
                    transcriptionModel: settings.transcriptionModel,
                    utteranceCount: utteranceCount,
                    peakAudioLevel: observedPeakAudioLevelSinceStart,
                    micHasCapturedFrames: observedMicHasEverCapturedFrames,
                    systemHasCapturedFrames: observedSystemHasEverCapturedFrames,
                    micCaptureError: captureHealth?.micCaptureError,
                    isMicMuted: currentState.isMicMuted,
                    isRecordingPaused: currentState.isRecordingPaused,
                    hasBlockingError: currentState.errorMessage != nil
                )
                set(\.recordingHealthNotice, Self.recordingHealthNotice(for: input))
            } else {
                set(\.recordingHealthNotice, nil)
            }
        } else {
            observedPeakAudioLevelSinceStart = 0
            observedSystemHasEverCapturedFrames = false
            observedMicHasEverCapturedFrames = false
            set(\.recordingHealthNotice, nil)
        }

        updateAutomaticSilenceTimeout(currentState: currentState, settings: settings)

        if currentState.isRunning != observedIsRunning {
            observedIsRunning = currentState.isRunning
            onRunningStateChanged?(currentState.isRunning)
        }

        // Refresh minibar content only when visible state changed
        if currentState.isRunning {
            let levelChanged = abs(currentState.audioLevel - observedAudioLevel) > 0.01
            let suggestionsChanged = currentState.suggestions != observedSuggestions
            let generatingChanged = currentState.isGeneratingSuggestions != observedIsGenerating

            if levelChanged || suggestionsChanged || generatingChanged {
                observedAudioLevel = currentState.audioLevel
                observedSuggestions = currentState.suggestions
                observedIsGenerating = currentState.isGeneratingSuggestions
                onMiniBarContentUpdate?()
            }
        }

        let pendingExternalCommandID = coordinator.pendingExternalCommand?.id
        if pendingExternalCommandID != observedPendingExternalCommandID {
            observedPendingExternalCommandID = pendingExternalCommandID
            handlePendingExternalCommandIfPossible(settings: settings, openNotesWindow: openNotesWindow)
        }
    }

    private func updateAutomaticSilenceTimeout(currentState: LiveSessionState, settings: AppSettings) {
        guard let engine = coordinator.transcriptionEngine else {
            observedSilenceTracking = .initial
            return
        }

        let timeout = Self.effectiveAutomaticSilenceTimeoutInterval(settings: settings)
        guard timeout > 0 else {
            observedSilenceTracking = .initial
            return
        }
        let evaluation = Self.automaticSilenceTimeoutEvaluation(
            isRunning: currentState.isRunning && engine.isRunning,
            isRecordingPaused: engine.isRecordingPaused,
            audioLevel: currentState.audioLevel,
            now: Date(),
            tracking: observedSilenceTracking,
            timeoutInterval: timeout
        )
        observedSilenceTracking = evaluation.tracking

        guard evaluation.shouldStop, !engine.isRecordingPaused else { return }
        observedSilenceTracking = .initial
        Log.meetingDetection.notice(
            "Auto-stopping after \(Int(timeout), privacy: .public)s of silence (noise floor \(evaluation.tracking.noiseFloor, privacy: .public))"
        )
        DiagnosticsSupport.record(
            category: "meeting",
            message: "Recording auto-stopped after \(Int(timeout))s of silence (noise floor \(String(format: "%.3f", Double(evaluation.tracking.noiseFloor))))"
        )
        stopSession(settings: settings)
    }
}
