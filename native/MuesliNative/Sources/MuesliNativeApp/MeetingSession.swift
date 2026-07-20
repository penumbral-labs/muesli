import FluidAudio
import ApplicationServices
import Foundation
import MuesliCore
import os

final class MeetingChunkCollector {
    private struct PendingTask {
        let id: UUID
        let task: Task<[SpeechSegment], Never>
    }

    private struct State {
        // Only in-flight tasks live here. Completed tasks are retired into
        // completedSegments so Task objects and their captured state don't
        // accumulate for the full meeting duration.
        var pendingTasks: [PendingTask] = []
        var completedSegments: [SpeechSegment] = []
        var isClosed = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Register a transcription task. Returns the retire ID to pass to retire(id:segments:)
    /// once the task completes.
    func add(_ task: Task<[SpeechSegment], Never>) -> (registered: Bool, retireID: UUID) {
        let id = UUID()
        let registered = lock.withLock { state in
            guard !state.isClosed else { return false }
            state.pendingTasks.append(PendingTask(id: id, task: task))
            return true
        }
        return (registered, id)
    }

    /// Move a completed task's result into the collector and drop the Task reference.
    /// Must be called from the watcher Task after awaiting the transcription task's value.
    func retire(id: UUID, segments: [SpeechSegment]) -> Bool {
        lock.withLock { state in
            guard !state.isClosed else { return false }
            state.completedSegments.append(contentsOf: segments)
            state.pendingTasks.removeAll { $0.id == id }
            return true
        }
    }

    func closeAndDrainSortedSegments() async -> [SpeechSegment] {
        let (tasksToAwait, alreadyCompleted) = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            let completed = state.completedSegments
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            return (tasks, completed)
        }

        var segments = alreadyCompleted
        for task in tasksToAwait {
            segments.append(contentsOf: await task.value)
        }

        return segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    func waitUntilRetired() async {
        while true {
            let tasks = lock.withLock { $0.pendingTasks.map(\.task) }
            guard !tasks.isEmpty else { return }
            for task in tasks {
                _ = await task.value
            }
            await Task.yield()
        }
    }

    func cancelAll() {
        let tasksToCancel = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            return tasks
        }
        tasksToCancel.forEach { $0.cancel() }
    }
}

struct MeetingSessionResult {
    let title: String
    let originalTitle: String
    let calendarEventID: String?
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let formattedNotes: String
    let retainedRecordingURL: URL?
    let retainedRecordingError: Error?
    let systemRecordingURL: URL?
    let templateSnapshot: MeetingTemplateSnapshot
}

extension MeetingSessionResult {
    /// Returns a copy with transcript, notes, and optional timing overrides.
    /// Used by the resume-recording flow to persist the merged transcript while
    /// keeping the original meeting date and accumulating only recorded duration.
    func overriding(
        startTime newStartTime: Date? = nil,
        durationSeconds newDurationSeconds: Double? = nil,
        rawTranscript: String,
        formattedNotes: String
    ) -> MeetingSessionResult {
        let resolvedStart = newStartTime ?? startTime
        let resolvedDuration = newDurationSeconds ?? durationSeconds
        return MeetingSessionResult(
            title: title,
            originalTitle: originalTitle,
            calendarEventID: calendarEventID,
            startTime: resolvedStart,
            endTime: endTime,
            durationSeconds: resolvedDuration,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingError,
            systemRecordingURL: systemRecordingURL,
            templateSnapshot: templateSnapshot
        )
    }
}

enum MeetingProcessingStage {
    case transcribingAudio
    case cleaningAudio
    case generatingTitle
    case summarizingNotes
}

private enum MeetingTranscriptRecoveryResult {
    case none
    case append([SpeechSegment])
    case replace([SpeechSegment])
}

/// Dispatch's work-item closure is `@Sendable`, while `MeetingSession` is
/// deliberately queue-confined rather than globally Sendable. Keep that
/// unchecked boundary local to the one queue that owns capture teardown.
private final class MeetingCaptureTeardownWork: @unchecked Sendable {
    private let operation: () -> Void

    init(_ operation: @escaping () -> Void) {
        self.operation = operation
    }

    func run() {
        operation()
    }
}

/// Defines the synchronous capture stop boundary shared by the real meeting
/// session and deterministic lifecycle tests. A source's `pause` operation is
/// a callback barrier: after both pauses return, callbacks admitted before the
/// stop request have crossed into the owner queue. Disconnecting callbacks
/// then prevents graph teardown from producing a second copy of the tail.
enum MeetingCaptureStopBoundary {
    static func quiesce<OwnerArtifacts, WriterArtifacts, GraphArtifacts>(
        pauseSources: () -> Void,
        disconnectSourceCallbacks: () -> Void,
        drainOwnerAndFinalizeChunks: () -> OwnerArtifacts,
        finalizeWriter: () -> WriterArtifacts,
        stopGraphs: () -> GraphArtifacts
    ) -> (
        owner: OwnerArtifacts,
        writer: WriterArtifacts,
        graphs: GraphArtifacts
    ) {
        pauseSources()
        disconnectSourceCallbacks()
        let owner = drainOwnerAndFinalizeChunks()
        let writer = finalizeWriter()
        let graphs = stopGraphs()
        return (owner, writer, graphs)
    }
}

final class MeetingSession {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingSession")

    private let title: String
    private let calendarEventID: String?
    private let backendLock = OSAllocatedUnfairLock(initialState: BackendOption.whisper)
    private let runtime: RuntimePaths
    private let config: AppConfig
    private let templateSnapshot: MeetingTemplateSnapshot
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let systemAudioRecorder: SystemAudioCapturing
    private let neuralAec = MeetingNeuralAec()

    /// Route-aware mic recorder with real-time 16 kHz mono PCM access.
    private var meetingMicRecorder: MeetingMicRecording
    private var rawMicChunkRecorder: PCMChunkRecorder?
    private var retainedRecordingWriter: MeetingRecordingWriter?
    private var retainedRecordingWriterError: Error?
    /// VAD controller for speech-boundary chunk rotation
    private var vadController: StreamingVadController?
    private var systemVadController: StreamingVadController?
    private let micChunkCollector = MeetingChunkCollector()
    private let systemChunkCollector = MeetingChunkCollector()
    private let micChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let systemChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let micHealthTracker = MeetingMicHealthTracker()
    private let chunkRotationQueue = DispatchQueue(label: "MuesliNative.MeetingSession.chunkRotation")
    /// Potentially blocking CoreAudio teardown belongs here, never on the UI
    /// executor. Stop and discard share the queue so their graph mutations
    /// cannot overlap if termination races an interactive lifecycle action.
    private let captureTeardownQueue = DispatchQueue(label: "MuesliNative.MeetingSession.captureTeardown")
    private struct CaptureActivityState {
        var startTime: Date?
        var isRecording = false
        var isPaused = false
    }
    private let captureActivityState = OSAllocatedUnfairLock(initialState: CaptureActivityState())
    private let screenPauseCommandGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var chunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkTimingTracker = MeetingChunkTimingTracker()
    private var lastMicRecoveryGeneration: UInt64 = 0
    private var systemChunkRecorder: PCMChunkRecorder?
    var onProgress: ((MeetingProcessingStage) -> Void)?
    var onMicHealthChanged: ((MeetingMicHealthSnapshot) -> Void)?
    var manualNotesProvider: (() async -> String?)?
    var liveTitleProvider: (() async -> String?)?
    /// Formatted notes of the predecessor meeting when this session records a
    /// follow-up; injected into the summary prompt for action-item carry-forward.
    var previousMeetingNotes: String?
    var onChunkTranscribed: (([SpeechSegment], String) -> Void)?
    /// Display-only streaming partial for a source ("You"/"Others", tail text).
    /// Empty text clears the source's tail. Called on a background thread.
    var onPartialTranscript: ((String, String) -> Void)?
    /// Lock-guarded because sessions are installed by an async model-loading
    /// task, fed on chunkRotationQueue, and committed by chunk-completion tasks.
    /// `isShutDown` closes the async-setup race with meeting teardown.
    private struct PartialSessionsStorage {
        var mic: MeetingStreamingPartialSession?
        var system: MeetingStreamingPartialSession?
        var isShutDown = false
    }
    private let partialSessionsStorage = OSAllocatedUnfairLock(initialState: PartialSessionsStorage())
    private let screenContextCollector = MeetingScreenContextCollector()
    private var diagnostics: MeetingSessionDiagnostics?

    /// Current mic power level for waveform visualization.
    func currentPower() -> Float {
        if isPaused {
            return -160
        }
        return meetingMicRecorder.currentPower()
    }

    private(set) var startTime: Date? {
        get { captureActivityState.withLock { $0.startTime } }
        set { captureActivityState.withLock { $0.startTime = newValue } }
    }
    private(set) var isRecording: Bool {
        get { captureActivityState.withLock { $0.isRecording } }
        set { captureActivityState.withLock { $0.isRecording = newValue } }
    }
    private(set) var isPaused: Bool {
        get { captureActivityState.withLock { $0.isPaused } }
        set { captureActivityState.withLock { $0.isPaused = newValue } }
    }

    private func setPausedStateOnQueue(_ paused: Bool) {
        isPaused = paused
    }

    private func setScreenContextPaused(_ paused: Bool) {
        let commandGeneration = screenPauseCommandGeneration.withLock { generation -> UInt64 in
            generation &+= 1
            return generation
        }
        Task { [screenContextCollector] in
            await screenContextCollector.setPaused(paused, commandGeneration: commandGeneration)
        }
    }

    init(
        title: String,
        calendarEventID: String?,
        backend: BackendOption,
        runtime: RuntimePaths,
        config: AppConfig,
        templateSnapshot: MeetingTemplateSnapshot,
        transcriptionCoordinator: TranscriptionCoordinator,
        meetingMicRecorder: MeetingMicRecording = RouteAwareMeetingMicRecorder()
    ) {
        self.title = title
        self.calendarEventID = calendarEventID
        backendLock.withLock { $0 = backend }
        self.runtime = runtime
        self.config = config
        self.templateSnapshot = templateSnapshot
        self.transcriptionCoordinator = transcriptionCoordinator
        self.meetingMicRecorder = meetingMicRecorder
        if config.useCoreAudioTap {
            self.systemAudioRecorder = CoreAudioSystemRecorder()
        } else {
            self.systemAudioRecorder = SystemAudioRecorder()
        }
    }

    func updateBackend(_ backend: BackendOption) {
        backendLock.withLock { $0 = backend }
    }

    /// Applies a meeting-only microphone route without touching the meeting
    /// application's device choice. The recorder serializes graph teardown and
    /// first-buffer verification away from the main actor while system audio
    /// capture continues uninterrupted.
    func requestMicrophoneRouteChange(_ selection: MeetingInputRouteSelection) {
        meetingMicRecorder.requestInputRouteChange(selection)
    }

    private func currentBackend() -> BackendOption {
        backendLock.withLock { $0 }
    }

    func start() async throws {
        let vadManager = await transcriptionCoordinator.getVadManager()
        let now = Date()
        diagnostics = MeetingSessionDiagnostics(title: title, startedAt: now)

        // AEC must be loaded before audio pipeline starts (streaming mode)
        await neuralAec.preload()

        chunkRotationQueue.sync {
            startTime = now
            chunkTimingTracker.start()
            systemChunkTimingTracker.start()
            lastMicRecoveryGeneration = 0
            isRecording = true
            setPausedStateOnQueue(false)
        }

        do {
            try prepareRealtimeAudioPipeline(vadManager: vadManager)
            if let prepareError = MeetingMicStartupPreflight.prepareBestEffort(meetingMicRecorder) {
                fputs(
                    "[meeting] microphone prewarm failed; continuing with recoverable start: \(prepareError.localizedDescription)\n",
                    stderr
                )
            }
            setupRetainedRecordingWriterIfNeeded()
            try await systemAudioRecorder.start()
            try meetingMicRecorder.start()
        } catch {
            vadController?.stop()
            vadController = nil
            systemVadController?.stop()
            systemVadController = nil
            meetingMicRecorder.onRawPCMSamples = nil
            meetingMicRecorder.onCaptureEvent = nil
            meetingMicRecorder.onRecordingFailed = nil
            systemAudioRecorder.onPCMSamples = nil
            retainedRecordingWriter?.cancel()
            retainedRecordingWriter = nil
            rawMicChunkRecorder?.cancel()
            rawMicChunkRecorder = nil
            systemChunkRecorder?.cancel()
            systemChunkRecorder = nil
            chunkRotationQueue.sync {
                isRecording = false
                setPausedStateOnQueue(false)
                startTime = nil
                chunkTimingTracker.discard()
                systemChunkTimingTracker.discard()
            }
            meetingMicRecorder.cancel()
            if let url = systemAudioRecorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            systemChunkCollector.cancelAll()
            throw error
        }
        if vadController != nil {
            fputs("[meeting] started with VAD-driven chunk rotation\n", stderr)
        } else {
            fputs("[meeting] VAD not available, using max-duration fallback only\n", stderr)
        }
        if config.enableScreenContext && CGPreflightScreenCaptureAccess() {
            // OCR screenshots are safe when using CoreAudio tap (no SCStream conflict)
            await screenContextCollector.startPeriodicCapture(useOCR: config.useCoreAudioTap)
        }
        setupStreamingPartialsIfAvailable()
    }

    /// Display-only streaming partials (#99). The selected live-caption model
    /// consumes the same cleaned mic and raw system streams as the VAD pipeline;
    /// VAD chunk transcription remains the durable source of truth.
    private func setupStreamingPartialsIfAvailable() {
        guard config.enableLiveStreamingPartials else { return }
        let backend = config.resolvedMeetingLiveCaptionBackend
        guard backend.isDownloaded else {
            fputs("[meeting-partials] \(backend.label) not downloaded; using committed live captions only\n", stderr)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let engines = try await MeetingLiveCaptionModelStore.makeEngines(
                    backend: backend,
                    nemotronPromptId: self.config.resolvedNemotron35Language.promptId
                )
                guard self.chunkRotationQueue.sync(execute: { self.isRecording }),
                      self.partialSessionsStorage.withLock({ !$0.isShutDown }) else {
                    await engines.mic.shutdown()
                    await engines.system.shutdown()
                    return
                }

                let mic = MeetingStreamingPartialSession(engine: engines.mic, label: "You")
                mic.onPartialUpdate = { [weak self] text in self?.onPartialTranscript?("You", text) }
                await mic.connect()
                let system = MeetingStreamingPartialSession(engine: engines.system, label: "Others")
                system.onPartialUpdate = { [weak self] text in self?.onPartialTranscript?("Others", text) }
                await system.connect()

                let stillRecording = self.chunkRotationQueue.sync { self.isRecording }
                guard stillRecording else {
                    mic.stop()
                    system.stop()
                    return
                }
                let installed = self.partialSessionsStorage.withLock { s -> Bool in
                    guard !s.isShutDown else { return false }
                    s.mic = mic
                    s.system = system
                    return true
                }
                guard installed else {
                    mic.stop()
                    system.stop()
                    return
                }
                fputs("[meeting-partials] \(backend.label) active for mic and system audio\n", stderr)
            } catch {
                fputs("[meeting-partials] \(backend.label) setup failed: \(error)\n", stderr)
            }
        }
    }

    private func micPartialSession() -> MeetingStreamingPartialSession? {
        partialSessionsStorage.withLock { $0.mic }
    }

    private func systemPartialSession() -> MeetingStreamingPartialSession? {
        partialSessionsStorage.withLock { $0.system }
    }

    private func feedMicPartialSession(_ samples: [Float]) {
        micPartialSession()?.enqueue(samples)
    }

    private func feedSystemPartialSession(_ samples: [Float]) {
        systemPartialSession()?.enqueue(samples)
    }

    private func markMicPartialBoundary(id: UUID) {
        micPartialSession()?.markSegmentBoundary(id: id)
    }

    private func markSystemPartialBoundary(id: UUID) {
        systemPartialSession()?.markSegmentBoundary(id: id)
    }

    private func commitMicPartialSegment(id: UUID) {
        micPartialSession()?.commitSegment(id: id)
    }

    private func commitSystemPartialSegment(id: UUID) {
        systemPartialSession()?.commitSegment(id: id)
    }

    private func segmentsUsingStreamingTranscript(
        _ segments: [SpeechSegment],
        partialSession: MeetingStreamingPartialSession?,
        segmentID: UUID,
        start: TimeInterval,
        end: TimeInterval
    ) -> [SpeechSegment] {
        let prefersStreamingTranscript = config.enableLiveStreamingPartials
            && config.resolvedMeetingLiveCaptionBackend == .nemotron35
        guard (segments.isEmpty || prefersStreamingTranscript),
              let text = partialSession?.pendingSegmentText(id: segmentID) else { return segments }
        return [SpeechSegment(start: start, end: max(end, start + 0.1), text: text)]
    }

    private func suspendPartialSessions() {
        micPartialSession()?.suspend()
        systemPartialSession()?.suspend()
    }

    private func resumePartialSessions() {
        micPartialSession()?.resume()
        systemPartialSession()?.resume()
    }

    private func stopPartialSessions() {
        let sessions = partialSessionsStorage.withLock { s -> (MeetingStreamingPartialSession?, MeetingStreamingPartialSession?) in
            let taken = (s.mic, s.system)
            s.mic = nil
            s.system = nil
            s.isShutDown = true
            return taken
        }
        sessions.0?.stop()
        sessions.1?.stop()
    }

    func stopStreamingPartials() {
        stopPartialSessions()
    }

    func pause() {
        let shouldPauseSources = chunkRotationQueue.sync {
            isRecording && !isPaused
        }
        guard shouldPauseSources else { return }

        // Capture sources establish their own callback barriers first. Once
        // these calls return, every pre-pause sample has either reached
        // chunkRotationQueue or been rejected by its source generation.
        meetingMicRecorder.pause()
        systemAudioRecorder.pause()

        let didCommitPause = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, !isPaused else { return false }
            appendFlushedStreamingMicOnQueue()
            rotateChunkOnQueue()
            rotateSystemChunkOnQueue()
            retainedRecordingWriter?.markPauseBoundary()
            neuralAec.resetForStreaming()
            vadController?.resetForDiscontinuity()
            systemVadController?.resetForDiscontinuity()
            setPausedStateOnQueue(true)
            suspendPartialSessions()
            return true
        }
        guard didCommitPause else { return }
        setScreenContextPaused(true)
        fputs("[meeting] recording paused\n", stderr)
    }

    func resume() {
        let shouldResume = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, isPaused else { return false }
            setPausedStateOnQueue(false)
            resumePartialSessions()
            return true
        }
        guard shouldResume else { return }

        meetingMicRecorder.resume()
        systemAudioRecorder.resume()
        setScreenContextPaused(false)
        fputs("[meeting] recording resumed\n", stderr)
    }

    /// Abandon the recording — stop everything, delete temp files, don't transcribe.
    /// The continuation resumes only after both audio sources have released
    /// CoreAudio, which is the controller's capture-quiescence boundary.
    func discard() async {
        screenContextCollector.invalidateCapture()
        await withCheckedContinuation { continuation in
            let work = MeetingCaptureTeardownWork { [self] in
                discardOnCaptureTeardownQueue()
                continuation.resume()
            }
            captureTeardownQueue.async { work.run() }
        }
        // Screen context belongs only to this retired session. Its actor may be
        // occupied by slow AX/Vision work, so never make discard or the next
        // meeting's audio lease wait for it.
        Task { [screenContextCollector] in
            _ = await screenContextCollector.stopAndDrain()
        }
    }

    /// Application termination is already a blocking boundary, so it may wait
    /// synchronously while still using the same serialized teardown path.
    func discardForTermination() {
        // Process exit does not admit another meeting, so this can remain a
        // best-effort asynchronous cancellation rather than blocking AppKit
        // termination on an in-flight Vision request.
        screenContextCollector.invalidateCapture()
        Task { await screenContextCollector.stopAndDrain() }
        captureTeardownQueue.sync { [self] in
            discardOnCaptureTeardownQueue()
        }
    }

    private func discardOnCaptureTeardownQueue() {
        let (rawRecorder, systemRecorder) = chunkRotationQueue.sync { () -> (PCMChunkRecorder?, PCMChunkRecorder?) in
            isRecording = false
            setPausedStateOnQueue(false)
            chunkTimingTracker.discard()
            systemChunkTimingTracker.discard()
            let rawRecorder = rawMicChunkRecorder
            let systemRecorder = systemChunkRecorder
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            return (rawRecorder, systemRecorder)
        }
        stopPartialSessions()
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        retainedRecordingWriter?.cancel()
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil
        rawRecorder?.cancel()
        systemRecorder?.cancel()
        meetingMicRecorder.onRawPCMSamples = nil
        meetingMicRecorder.onCaptureEvent = nil
        meetingMicRecorder.onRecordingFailed = nil
        meetingMicRecorder.cancel()
        systemAudioRecorder.onPCMSamples = nil
        if let url = systemAudioRecorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        micChunkCollector.cancelAll()
        systemChunkCollector.cancelAll()
        fputs("[meeting] recording discarded\n", stderr)
    }

    func stop(
        onCaptureQuiesced: (() async -> Void)? = nil
    ) async throws -> MeetingSessionResult {
        onProgress?(.transcribingAudio)
        let endTime = Date()
        var micSegments: [SpeechSegment] = []
        var systemSegments: [SpeechSegment] = []
        let usesUnifiedNemotronTranscript = config.enableLiveStreamingPartials
            && config.resolvedMeetingLiveCaptionBackend == .nemotron35

        let capture = await quiesceCaptureForStop(
            usesUnifiedNemotronTranscript: usesUnifiedNemotronTranscript
        )
        // Transcript finalization may take minutes, but it no longer owns any
        // microphone/system capture graph. The controller can safely admit the
        // next meeting immediately after this awaited handoff returns.
        await onCaptureQuiesced?()
        // Context finalization is intentionally after the audio handoff. A
        // wedged Accessibility or Vision request can delay only this retired
        // meeting's summary, never another application's microphone access.
        let visualContext = await screenContextCollector.stopAndDrain()

        let meetingStart = capture.meetingStart
        let lastChunkTiming = capture.lastChunkTiming
        let lastRawMicURL = capture.lastRawMicURL
        let lastSystemChunkTiming = capture.lastSystemChunkTiming
        let lastSystemChunkURL = capture.lastSystemChunkURL
        let rawStreamingMicURL = capture.rawStreamingMicURL
        let retainedRecordingURL = capture.retainedRecordingURL
        let systemAudioURL = capture.systemAudioURL
        defer {
            if let rawStreamingMicURL {
                try? FileManager.default.removeItem(at: rawStreamingMicURL)
            }
        }

        if usesUnifiedNemotronTranscript {
            async let micRetirement: Void = micChunkCollector.waitUntilRetired()
            async let systemRetirement: Void = systemChunkCollector.waitUntilRetired()
            _ = await (micRetirement, systemRetirement)

            async let micTail = micPartialSession()?.finish()
            async let systemTail = systemPartialSession()?.finish()
            let (finalMicText, finalSystemText) = await (micTail, systemTail)
            if let finalMicText, let timing = lastChunkTiming {
                micSegments.append(SpeechSegment(
                    start: timing.startTimeSeconds,
                    end: timing.startTimeSeconds + max(timing.durationSeconds, 0.1),
                    text: finalMicText
                ))
            }
            if let finalSystemText, let timing = lastSystemChunkTiming {
                systemSegments.append(SpeechSegment(
                    start: timing.startTimeSeconds,
                    end: timing.startTimeSeconds + max(timing.durationSeconds, 0.1),
                    text: finalSystemText
                ))
            }
            stopPartialSessions()
        }

        // The configured meeting model fills only a tail Nemotron could not finalize.
        if !usesUnifiedNemotronTranscript || micSegments.isEmpty {
            let finalMicSegments = await transcribeMicChunk(
                rawURL: lastRawMicURL,
                chunkTiming: lastChunkTiming,
                isFinalChunk: true
            )
            micSegments.append(contentsOf: finalMicSegments)
        } else if let lastRawMicURL {
            try? FileManager.default.removeItem(at: lastRawMicURL)
        }

        if let lastSystemChunkURL {
            let chunkOffset = lastSystemChunkTiming?.startTimeSeconds ?? 0
            let chunkDuration = lastSystemChunkTiming?.durationSeconds ?? 0
            if !usesUnifiedNemotronTranscript || systemSegments.isEmpty {
                fputs("[meeting] transcribing final system chunk (offset=\(String(format: "%.0f", chunkOffset))s)\n", stderr)
                do {
                    let result = try await transcriptionCoordinator.transcribeMeetingChunk(
                        at: lastSystemChunkURL,
                        backend: currentBackend(),
                        cohereLanguage: config.resolvedCohereLanguage,
                        indicASRLanguage: config.resolvedIndicASRLanguage
                    )
                    let normalizedSegments = normalizeSystemTranscription(
                        result: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    )
                    if normalizedSegments.isEmpty {
                        systemChunkHealthTracker.noteEmptyChunk()
                    } else {
                        systemChunkHealthTracker.noteSuccessfulChunk()
                    }
                    systemSegments.append(contentsOf: normalizedSegments)
                } catch {
                    systemChunkHealthTracker.noteFailedChunk()
                    fputs("[meeting] final system chunk transcription failed: \(error)\n", stderr)
                }
            }
            try? FileManager.default.removeItem(at: lastSystemChunkURL)
        }

        var diarizationSegments: [TimedSpeakerSegment]?
        if let systemAudioURL {
            // Run speaker diarization on system audio (batch post-processing)
            if let diarizationResult = try? await transcriptionCoordinator.diarizeSystemAudio(at: systemAudioURL) {
                diarizationSegments = diarizationResult.segments
            }
        }

        micSegments.append(contentsOf: await micChunkCollector.closeAndDrainSortedSegments())
        micSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        systemSegments.append(contentsOf: await systemChunkCollector.closeAndDrainSortedSegments())
        systemSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        if let systemAudioURL,
           Self.shouldAttemptSystemRecovery(
               usesUnifiedNemotronTranscript: usesUnifiedNemotronTranscript,
               hasSystemSegments: !systemSegments.isEmpty
           ) {
            let systemRecovery = await repairSystemSegmentsIfNeeded(
                existingSystemSegments: systemSegments,
                systemAudioURL: systemAudioURL,
                meetingStart: meetingStart,
                endTime: endTime
            )
            switch systemRecovery {
            case .none:
                break
            case .append(let repairedSystemSegments):
                systemSegments.append(contentsOf: repairedSystemSegments)
                systemSegments.sort { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            case .replace(let fallbackSystemSegments):
                systemSegments = fallbackSystemSegments.sorted { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            }
        }

        fputs("[meeting] \(micSegments.count) mic chunks transcribed during meeting\n", stderr)
        fputs("[meeting] \(systemSegments.count) system chunks transcribed during meeting\n", stderr)

        let reconciledTranscriptInputs = TranscriptReconciler.reconcile(
            micTurns: micSegments,
            systemSegments: systemSegments,
            diarizationSegments: diarizationSegments
        )
        let protectedTranscriptInputs = reconciledTranscriptInputs

        let rawTranscript = TranscriptFormatter.merge(
            micSegments: protectedTranscriptInputs.micSegments,
            systemSegments: protectedTranscriptInputs.systemSegments,
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            meetingStart: meetingStart
        )

        let generatedTitle: String
        onProgress?(.generatingTitle)
        if let liveTitle = await userEditedLiveTitle() {
            generatedTitle = liveTitle
        } else if let calendarTitle = Self.calendarTitleCandidate(
            originalTitle: title,
            calendarEventID: calendarEventID
        ) {
            generatedTitle = calendarTitle
        } else if let autoTitle = await MeetingSummaryClient.generateTitle(transcript: rawTranscript, config: config),
           !autoTitle.isEmpty {
            generatedTitle = autoTitle
            fputs("[meeting] auto-generated title: \(generatedTitle)\n", stderr)
        } else {
            generatedTitle = title
        }

        Self.logger.info("visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(self.config.useCoreAudioTap)")
        fputs("[meeting] visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(config.useCoreAudioTap)\n", stderr)
        onProgress?(.summarizingNotes)
        let manualNotes = await manualNotesProvider?()
        let formattedNotes: String
        do {
            formattedNotes = try await MeetingSummaryClient.summarize(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                config: config,
                template: templateSnapshot,
                existingNotes: nil,
                manualNotesToRetain: manualNotes,
                visualContext: visualContext.isEmpty ? nil : visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
        } catch {
            fputs("[meeting] summary generation failed: \(error.localizedDescription)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                error: error,
                manualNotes: manualNotes
            )
        }

        diagnostics?.writeFinalReport(
            title: generatedTitle,
            startedAt: meetingStart,
            endedAt: endTime,
            rawTranscript: rawTranscript,
            rawMicURL: rawStreamingMicURL,
            systemAudioURL: systemAudioURL,
            systemCapture: (systemAudioRecorder as? SystemAudioDiagnosticsProviding)?.diagnosticsSnapshot,
            micRecorder: capture.micRecorderDiagnostics,
            micHealth: micHealthTracker.snapshot(),
            aec: neuralAec.diagnosticsSnapshot,
            micChunks: micChunkHealthTracker.snapshot(),
            systemChunks: systemChunkHealthTracker.snapshot(),
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            protectedSystemSegmentCount: protectedTranscriptInputs.systemSegments.count
        )

        return MeetingSessionResult(
            title: generatedTitle,
            originalTitle: title,
            calendarEventID: calendarEventID,
            startTime: meetingStart,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingWriterError,
            systemRecordingURL: systemAudioURL,
            templateSnapshot: templateSnapshot
        )
    }

    private struct AudioCaptureStopArtifacts: @unchecked Sendable {
        let meetingStart: Date
        let lastChunkTiming: MeetingChunkTimingSnapshot?
        let lastRawMicURL: URL?
        let lastSystemChunkTiming: MeetingChunkTimingSnapshot?
        let lastSystemChunkURL: URL?
        let rawStreamingMicURL: URL?
        let retainedRecordingURL: URL?
        let systemAudioURL: URL?
        let micRecorderDiagnostics: MeetingMicRecorderDiagnosticsSnapshot
    }

    private func quiesceCaptureForStop(
        usesUnifiedNemotronTranscript: Bool
    ) async -> AudioCaptureStopArtifacts {
        // Establish the metadata fence synchronously, without waiting for the
        // screen collector actor. Only audio resources govern capture handoff.
        screenContextCollector.invalidateCapture()
        let audio: AudioCaptureStopArtifacts = await withCheckedContinuation { continuation in
            let work = MeetingCaptureTeardownWork { [self] in
                let boundary = MeetingCaptureStopBoundary.quiesce(
                    pauseSources: {
                        // Both implementations drain callbacks already admitted
                        // by their current generation before returning.
                        meetingMicRecorder.pause()
                        systemAudioRecorder.pause()
                    },
                    disconnectSourceCallbacks: {
                        meetingMicRecorder.onRawPCMSamples = nil
                        meetingMicRecorder.onCaptureEvent = nil
                        meetingMicRecorder.onRecordingFailed = nil
                        systemAudioRecorder.onPCMSamples = nil
                    },
                    drainOwnerAndFinalizeChunks: {
                        // The sync is the owner-queue drain. Every sample that
                        // crossed a source pause barrier executes before this
                        // closure finalizes the two tail chunks.
                        chunkRotationQueue.sync {
                            () -> (Date, MeetingChunkTimingSnapshot?, URL?, MeetingChunkTimingSnapshot?, URL?) in
                            isRecording = false
                            setPausedStateOnQueue(false)
                            appendFlushedStreamingMicOnQueue()

                            let meetingStart = startTime ?? Date()
                            let lastRawMicURL = rawMicChunkRecorder?.stop()
                            let lastSystemChunkURL = systemChunkRecorder?.stop()
                            rawMicChunkRecorder = nil
                            systemChunkRecorder = nil
                            let lastChunkTiming = chunkTimingTracker.finish()
                            let lastSystemChunkTiming = systemChunkTimingTracker.finish()
                            return (
                                meetingStart,
                                lastChunkTiming,
                                lastRawMicURL,
                                lastSystemChunkTiming,
                                lastSystemChunkURL
                            )
                        }
                    },
                    finalizeWriter: {
                        // Tail samples have now passed through the writer and
                        // partial/VAD consumers; only then retire those owners.
                        if !usesUnifiedNemotronTranscript {
                            stopPartialSessions()
                        }
                        vadController?.stop()
                        vadController = nil
                        systemVadController?.stop()
                        systemVadController = nil
                        let url = retainedRecordingWriter?.stop()
                        retainedRecordingWriter = nil
                        return url
                    },
                    stopGraphs: {
                        // Graph stop may block in CoreAudio, but callbacks are
                        // disconnected and the tail is already durable.
                        let micDiagnostics = meetingMicRecorder.diagnosticsSnapshot()
                        return (
                            meetingMicRecorder.stop(),
                            systemAudioRecorder.stop(),
                            micDiagnostics
                        )
                    }
                )

                continuation.resume(returning: AudioCaptureStopArtifacts(
                    meetingStart: boundary.owner.0,
                    lastChunkTiming: boundary.owner.1,
                    lastRawMicURL: boundary.owner.2,
                    lastSystemChunkTiming: boundary.owner.3,
                    lastSystemChunkURL: boundary.owner.4,
                    rawStreamingMicURL: boundary.graphs.0,
                    retainedRecordingURL: boundary.writer,
                    systemAudioURL: boundary.graphs.1,
                    micRecorderDiagnostics: boundary.graphs.2
                ))
            }
            captureTeardownQueue.async { work.run() }
        }
        return audio
    }

    static func calendarTitleCandidate(originalTitle: String, calendarEventID: String?) -> String? {
        guard calendarEventID != nil else { return nil }
        guard !originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return originalTitle
    }

    static func shouldAttemptSystemRecovery(
        usesUnifiedNemotronTranscript: Bool,
        hasSystemSegments: Bool
    ) -> Bool {
        !usesUnifiedNemotronTranscript || !hasSystemSegments
    }

    private func userEditedLiveTitle() async -> String? {
        guard let candidate = await liveTitleProvider?() else { return nil }
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return nil }
        guard trimmedCandidate != trimmedOriginal else { return nil }
        return trimmedCandidate
    }

    private func appendFlushedStreamingMicOnQueue() {
        let flushed = neuralAec.flushStreamingMic()
        appendCleanedMicSamplesOnQueue(flushed)
    }

    /// Called by VAD on speech boundaries or max-duration fallback.
    /// Rotates the streaming mic file and sends the completed chunk for transcription.
    private func rotateChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateChunkOnQueue()
        }
    }

    private func rotateChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        appendFlushedStreamingMicOnQueue()
        guard let chunkTiming = chunkTimingTracker.rotate() else {
            return
        }
        let rawChunkURL = rawMicChunkRecorder?.rotateFile()

        guard rawChunkURL != nil else {
            return
        }

        // Transcribe the completed chunk async
        let chunkOffset = chunkTiming.startTimeSeconds

        fputs("[meeting] rotating raw mic chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)
        let task = Task { [weak self] () -> [SpeechSegment] in
            guard let self else { return [] }
            if Task.isCancelled {
                self.cleanupTemporaryChunkURLs(rawChunkURL)
                return []
            }
            let segments = await self.transcribeMicChunk(
                rawURL: rawChunkURL,
                chunkTiming: chunkTiming,
                isFinalChunk: false
            )
            return segments
        }
        let (registered, retireID) = micChunkCollector.add(task)
        if registered {
            // Bind this frozen prefix to the collector ID because chunk tasks
            // may finish out of submission order.
            markMicPartialBoundary(id: retireID)
            Task { [weak self] in
                let segments = await task.value
                guard let self else { return }
                let resolvedSegments = self.segmentsUsingStreamingTranscript(
                    segments,
                    partialSession: self.micPartialSession(),
                    segmentID: retireID,
                    start: chunkOffset,
                    end: chunkOffset + max(chunkTiming.durationSeconds, 0.1)
                )
                guard self.micChunkCollector.retire(id: retireID, segments: resolvedSegments) else { return }
                self.commitMicPartialSegment(id: retireID)
                guard !resolvedSegments.isEmpty else { return }
                self.onChunkTranscribed?(resolvedSegments, "You")
            }
        } else {
            task.cancel()
            cleanupTemporaryChunkURLs(rawChunkURL)
        }
    }

    private func rotateSystemChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateSystemChunkOnQueue()
        }
    }

    private func rotateSystemChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        guard let chunkURL = systemChunkRecorder?.rotateFile(),
              let chunkTiming = systemChunkTimingTracker.rotate() else {
            return
        }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        fputs("[meeting] rotating system chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)
        let task = Task { [weak self] () -> [SpeechSegment] in
            defer {
                try? FileManager.default.removeItem(at: chunkURL)
            }
            guard let self else { return [] }
            do {
                if Task.isCancelled {
                    return []
                }
                let backend = self.currentBackend()
                let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(
                    at: chunkURL,
                    backend: backend,
                    cohereLanguage: config.resolvedCohereLanguage,
                    indicASRLanguage: config.resolvedIndicASRLanguage
                )
                if !result.text.isEmpty {
                    fputs("[meeting] system chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                    let normalizedSegments = self.normalizeSystemTranscription(
                        result: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    )
                    if normalizedSegments.isEmpty {
                        self.systemChunkHealthTracker.noteEmptyChunk()
                    } else {
                        self.systemChunkHealthTracker.noteSuccessfulChunk()
                    }
                    return normalizedSegments
                }
                self.systemChunkHealthTracker.noteEmptyChunk()
            } catch {
                self.systemChunkHealthTracker.noteFailedChunk()
                fputs("[meeting] system chunk transcription failed: \(error)\n", stderr)
            }
            return []
        }
        let (registered, retireID) = systemChunkCollector.add(task)
        if registered {
            markSystemPartialBoundary(id: retireID)
            Task { [weak self] in
                let segments = await task.value
                guard let self else { return }
                let resolvedSegments = self.segmentsUsingStreamingTranscript(
                    segments,
                    partialSession: self.systemPartialSession(),
                    segmentID: retireID,
                    start: chunkOffset,
                    end: chunkOffset + max(chunkDuration, 0.1)
                )
                guard self.systemChunkCollector.retire(id: retireID, segments: resolvedSegments) else { return }
                self.commitSystemPartialSegment(id: retireID)
                guard !resolvedSegments.isEmpty else { return }
                self.onChunkTranscribed?(resolvedSegments, "Others")
            }
        } else {
            task.cancel()
        }
    }

    private func setupRetainedRecordingWriterIfNeeded() {
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil

        guard config.meetingRecordingSavePolicy != .never else { return }

        do {
            retainedRecordingWriter = try MeetingRecordingWriter()
        } catch {
            retainedRecordingWriterError = error
            fputs("[meeting] failed to prepare retained recording writer: \(error)\n", stderr)
        }
    }

    private func prepareRealtimeAudioPipeline(vadManager: VadManager?) throws {
        rawMicChunkRecorder = try PCMChunkRecorder(directoryName: "muesli-meeting-mic-chunks")
        systemChunkRecorder = try PCMChunkRecorder(directoryName: "muesli-meeting-system-chunks")
        configureRealtimeAudioCallbacks(vadManager: vadManager)
    }

    private func configureRealtimeAudioCallbacks(vadManager: VadManager?) {
        if let vadManager {
            let controller = StreamingVadController(vadManager: vadManager)
            controller.onChunkBoundary = { [weak self, weak controller] generation in
                // Streaming VAD callbacks can arrive off-main; serialize chunk rotation explicitly.
                self?.chunkRotationQueue.async { [weak self, weak controller] in
                    guard let self,
                          let controller,
                          controller.isBoundaryGenerationCurrent(generation) else { return }
                    self.rotateChunkOnQueue()
                }
            }
            controller.start()
            vadController = controller

            let systemController = StreamingVadController(vadManager: vadManager)
            systemController.onChunkBoundary = { [weak self, weak systemController] generation in
                // Streaming VAD callbacks can arrive off-main; serialize chunk rotation explicitly.
                self?.chunkRotationQueue.async { [weak self, weak systemController] in
                    guard let self,
                          let systemController,
                          systemController.isBoundaryGenerationCurrent(generation) else { return }
                    self.rotateSystemChunkOnQueue()
                }
            }
            systemController.start()
            systemVadController = systemController
        } else {
            vadController = nil
            systemVadController = nil
        }
        neuralAec.resetForStreaming()
        meetingMicRecorder.onRawPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeMicSamples(samples)
        }
        meetingMicRecorder.onCaptureEvent = { [weak self] event in
            self?.enqueueMicCaptureEvent(event)
        }
        meetingMicRecorder.onRecordingFailed = { [weak self] error in
            self?.enqueueMicCaptureFailure(reason: error.localizedDescription)
        }
        systemAudioRecorder.onPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeSystemSamples(samples)
        }
    }

    private func enqueueMicCaptureEvent(_ event: StreamingMicCaptureEvent) {
        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording else { return }
            switch event {
            case .recovered(let discontinuity):
                self.handleMicDiscontinuityOnQueue(discontinuity)
            case .failed(let failure):
                self.handleMicCaptureFailureOnQueue(
                    reason: "capture_recovery_failed:\(failure.reason.rawValue):\(failure.message)"
                )
            }
        }
    }

    private func enqueueMicCaptureFailure(reason: String) {
        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.handleMicCaptureFailureOnQueue(reason: "recorder_failed:\(reason)")
        }
    }

    private func handleMicCaptureFailureOnQueue(reason: String) {
        let snapshot = micHealthTracker.noteCaptureFailure(reason: reason)
        onMicHealthChanged?(snapshot)
        fputs("[meeting] microphone capture degraded: \(reason)\n", stderr)
    }

    private func handleMicDiscontinuityOnQueue(_ discontinuity: StreamingMicDiscontinuity) {
        guard !isPaused,
              discontinuity.generation > lastMicRecoveryGeneration else { return }
        lastMicRecoveryGeneration = discontinuity.generation

        // Finish and freeze all pre-gap state before advancing the logical mic
        // clock. The first replacement-tap buffer is queued immediately after
        // this event, so it cannot be paired with pre-gap system audio.
        rotateChunkOnQueue()
        let missingSamples = max(0, discontinuity.missingSampleCount)
        chunkTimingTracker.advance(sampleCount: missingSamples)
        neuralAec.noteMicDiscontinuity(
            missingSampleCount: Int(min(missingSamples, Int64(Int.max)))
        )
        vadController?.resetForDiscontinuity()
        micPartialSession()?.markDiscontinuity()
        retainedRecordingWriter?.markMicDiscontinuity(missingSampleCount: missingSamples)

        let health = micHealthTracker.noteCaptureRecovered()
        onMicHealthChanged?(health)
        fputs(
            "[meeting] microphone timeline recovered generation=\(discontinuity.generation) " +
            "gap_samples=\(missingSamples) old_device=\(String(describing: discontinuity.previousInput.actualDeviceID)) " +
            "new_device=\(String(describing: discontinuity.currentInput.actualDeviceID))\n",
            stderr
        )
    }

    private func enqueueRealtimeMicSamples(_ rawSamples: [Int16]) {
        guard !rawSamples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteRawMicSamples(rawSamples)
            self.onMicHealthChanged?(healthSnapshot)
            self.retainedRecordingWriter?.appendMic(rawSamples)

            let floatSamples = rawSamples.map { Float($0) / 32767.0 }

            // AEC: clean mic using position-aligned system reference
            let cleanedFloat = self.neuralAec.processStreamingMic(floatSamples)
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            // Meeting mic chunks must be driven by the cleaned mic stream. Raw
            // mic VAD sees speaker playback bleed and can create false `You`
            // chunks even when AEC removed that speech from the final mic audio.
            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }
        }
    }

    private func enqueueRealtimeSystemSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteSystemSamples(samples)
            self.onMicHealthChanged?(healthSnapshot)
            self.retainedRecordingWriter?.appendSystem(samples)
            self.systemChunkRecorder?.append(samples)
            self.systemChunkTimingTracker.append(sampleCount: samples.count)

            let floatSamples = samples.map { Float($0) / 32767.0 }
            self.feedSystemPartialSession(floatSamples)
            self.neuralAec.feedSystemSamples(floatSamples)
            let cleanedFloat = self.neuralAec.processStreamingMic([])
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }

            if let systemVadController = self.systemVadController {
                systemVadController.processAudio(floatSamples)
            }
        }
    }

    private func appendCleanedMicSamplesOnQueue(_ cleanedFloat: [Float]) {
        guard !cleanedFloat.isEmpty else { return }
        // Single funnel for all AEC'd mic audio — the streaming partial tail
        // must consume exactly the stream the mic chunks record.
        feedMicPartialSession(cleanedFloat)
        let cleanedInt16 = cleanedFloat.map { sample -> Int16 in
            Int16(max(-1.0, min(1.0, sample)) * 32767)
        }
        rawMicChunkRecorder?.append(cleanedInt16)
        chunkTimingTracker.append(sampleCount: cleanedInt16.count)
        diagnostics?.appendCleanedMicSamples(cleanedInt16)
    }

    private func transcribeMicChunk(
        rawURL: URL?,
        chunkTiming: MeetingChunkTimingSnapshot?,
        isFinalChunk: Bool
    ) async -> [SpeechSegment] {
        defer {
            cleanupTemporaryChunkURLs(rawURL)
        }

        guard let chunkTiming, let rawURL else { return [] }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        let logPrefix = isFinalChunk ? "[meeting] transcribing final mic chunk" : "[meeting] transcribing mic chunk"

        return await transcribeMicChunk(
            at: rawURL,
            chunkOffset: chunkOffset,
            chunkDuration: chunkDuration,
            logPrefix: logPrefix
        ) ?? []
    }

    private func transcribeMicChunk(
        at url: URL,
        chunkOffset: TimeInterval,
        chunkDuration: TimeInterval,
        logPrefix: String
    ) async -> [SpeechSegment]? {
        fputs("\(logPrefix) (offset=\(String(format: "%.0f", chunkOffset))s, source=raw)\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeetingChunk(
                at: url,
                backend: currentBackend(),
                cohereLanguage: config.resolvedCohereLanguage,
                indicASRLanguage: config.resolvedIndicASRLanguage
            )
            if !result.text.isEmpty {
                fputs("[meeting] mic chunk transcribed (raw): \"\(String(result.text.prefix(60)))...\"\n", stderr)
                let normalizedSegments = MicTurnNormalizer.normalize(
                    result: result,
                    startTime: chunkOffset,
                    endTime: chunkOffset + max(chunkDuration, 0.1)
                )
                if normalizedSegments.isEmpty {
                    micChunkHealthTracker.noteEmptyChunk()
                } else {
                    micChunkHealthTracker.noteSuccessfulChunk()
                }
                return normalizedSegments
            }
            micChunkHealthTracker.noteEmptyChunk()
            return []
        } catch {
            micChunkHealthTracker.noteFailedChunk()
            fputs("[meeting] mic chunk transcription failed (raw): \(error)\n", stderr)
            return nil
        }
    }

    private func cleanupTemporaryChunkURLs(_ urls: URL?...) {
        urls.compactMap { $0 }.forEach { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func normalizeSystemTranscription(
        result: SpeechTranscriptionResult,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        SystemTurnNormalizer.normalize(
            result: result,
            startTime: startTime,
            endTime: endTime
        )
    }

    private func durationSeconds(from start: Date, to end: Date) -> Double {
        max(end.timeIntervalSince(start), 0)
    }

    private func repairSystemSegmentsIfNeeded(
        existingSystemSegments: [SpeechSegment],
        systemAudioURL: URL,
        meetingStart: Date,
        endTime: Date
    ) async -> MeetingTranscriptRecoveryResult {
        let totalDuration = durationSeconds(from: meetingStart, to: endTime)

        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }

        do {
            let samples = try AudioConverter().resampleAudioFile(systemAudioURL)
            let speechSegments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
            )
            let health = MeetingTranscriptHealthMonitor.evaluate(
                existingSegments: existingSystemSegments,
                offlineSpeechSegments: speechSegments,
                chunkHealth: systemChunkHealthTracker.snapshot()
            )
            fputs("[meeting] system \(health.summaryLine.dropFirst("[meeting] ".count))\n", stderr)

            switch health.action {
            case .accept:
                return .none
            case .fullFallback(let reason):
                fputs("[meeting] transcript health triggered full system fallback: \(reason)\n", stderr)
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            case .selectiveRepair(let repairSegments):
                guard !repairSegments.isEmpty else { return .none }

                fputs("[meeting] repairing \(repairSegments.count) uncovered system speech regions\n", stderr)

                var repairedSegments: [SpeechSegment] = []
                for speechSegment in repairSegments {
                    let startSample = max(0, speechSegment.startSample(sampleRate: VadManager.sampleRate))
                    let endSample = min(samples.count, speechSegment.endSample(sampleRate: VadManager.sampleRate))
                    guard endSample > startSample else { continue }

                    let segmentURL = try MeetingMicRepairPlanner.writeTemporaryWAV(
                        samples: Array(samples[startSample..<endSample])
                    )
                    defer { try? FileManager.default.removeItem(at: segmentURL) }

                    let result = try await transcriptionCoordinator.transcribeMeeting(
                        at: segmentURL,
                        backend: currentBackend(),
                        cohereLanguage: config.resolvedCohereLanguage,
                        indicASRLanguage: config.resolvedIndicASRLanguage
                    )
                    repairedSegments.append(contentsOf: normalizeSystemTranscription(
                        result: result,
                        startTime: speechSegment.startTime,
                        endTime: speechSegment.endTime
                    ))
                }
                return repairedSegments.isEmpty ? .none : .append(repairedSegments)
            }
        } catch {
            fputs("[meeting] system repair pass failed: \(error)\n", stderr)
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }
    }

    private func fallbackToFullSessionSystemTranscription(
        systemAudioURL: URL,
        meetingDuration: Double
    ) async -> [SpeechSegment] {
        fputs("[meeting] no system chunks survived, falling back to full-session system transcription\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeeting(
                at: systemAudioURL,
                backend: currentBackend(),
                cohereLanguage: config.resolvedCohereLanguage,
                indicASRLanguage: config.resolvedIndicASRLanguage
            )
            return normalizeSystemTranscription(
                result: result,
                startTime: 0,
                endTime: meetingDuration
            )
        } catch {
            fputs("[meeting] full-session system fallback transcription failed: \(error)\n", stderr)
            return []
        }
    }
}
