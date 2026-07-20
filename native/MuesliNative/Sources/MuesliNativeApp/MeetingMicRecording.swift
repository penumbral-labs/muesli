import CoreAudio
import Foundation
import os

enum MeetingMicRecorderKind: String, Codable, Equatable {
    case systemDefaultStreaming
    case appScopedAudioQueue
}

struct MeetingMicRouteDiagnosticsSnapshot: Codable, Equatable {
    let outputRouteKind: String
    let outputIsAmbiguousBluetooth: Bool
    let selectedInputDeviceUID: String?
    let selectedInputDeviceResolved: Bool
    let preferredInputDeviceID: AudioObjectID?
    let preferredInputDeviceName: String?
    let defaultInputDeviceID: AudioObjectID?
    let defaultInputDeviceName: String?
    let builtInInputDeviceID: AudioObjectID?
    let systemDefaultInputIsBuiltIn: Bool
}

struct MeetingMicRecorderDiagnosticsSnapshot: Codable, Equatable {
    let recorderKind: MeetingMicRecorderKind
    let preferredInputDeviceID: AudioObjectID?
    let route: MeetingMicRouteDiagnosticsSnapshot?
    let captureRecovery: StreamingMicRecoveryDiagnosticsSnapshot?

    init(
        recorderKind: MeetingMicRecorderKind,
        preferredInputDeviceID: AudioObjectID?,
        route: MeetingMicRouteDiagnosticsSnapshot?,
        captureRecovery: StreamingMicRecoveryDiagnosticsSnapshot? = nil
    ) {
        self.recorderKind = recorderKind
        self.preferredInputDeviceID = preferredInputDeviceID
        self.route = route
        self.captureRecovery = captureRecovery
    }
}

protocol MeetingMicRecording: AnyObject {
    var preferredInputDeviceID: AudioObjectID? { get set }
    var onRawPCMSamples: (([Int16]) -> Void)? { get set }
    var onRecordingFailed: ((Error) -> Void)? { get set }
    var onCaptureEvent: ((StreamingMicCaptureEvent) -> Void)? { get set }

    func prepare() throws
    func start() throws
    func pause()
    func resume()
    func stop() -> URL?
    func cancel()
    func currentPower() -> Float
    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot
}

extension MeetingMicRecording {
    /// Requests a meeting-only route change. Simple recorders keep the legacy
    /// behavior; the route-aware production wrapper overrides this with a
    /// generation-safe live handoff.
    func requestInputRouteChange(_ selection: MeetingInputRouteSelection) {
        preferredInputDeviceID = selection.preferredInputDeviceID
    }
}

enum MeetingMicStartupPreflight {
    /// Prewarming is an optimization, not an admission requirement. Route
    /// changes commonly invalidate a prepared graph; `start()` owns the real
    /// attempt and its recovery/fallback policy.
    @discardableResult
    static func prepareBestEffort(_ recorder: MeetingMicRecording) -> Error? {
        do {
            try recorder.prepare()
            return nil
        } catch {
            return error
        }
    }
}

final class StreamingMeetingMicRecorderAdapter: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID? {
        get { recorder.preferredInputDeviceID }
        set { recorder.preferredInputDeviceID = newValue }
    }
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onCaptureEvent: ((StreamingMicCaptureEvent) -> Void)?

    private let recorder: StreamingDictationRecording
    private let kind: MeetingMicRecorderKind
    private let lock = OSAllocatedUnfairLock(initialState: false)

    init(
        recorder: StreamingDictationRecording,
        kind: MeetingMicRecorderKind
    ) {
        self.recorder = recorder
        self.kind = kind
        wireCallbacks()
    }

    func prepare() throws {
        try recorder.prepare()
    }

    func start() throws {
        lock.withLock { $0 = false }
        try recorder.start()
    }

    func pause() {
        // Let the recorder drain callbacks committed before its pause epoch;
        // only then suppress any later adapter delivery.
        (recorder as? PausableStreamingDictationRecording)?.pause()
        lock.withLock { $0 = true }
    }

    func resume() {
        lock.withLock { $0 = false }
        (recorder as? PausableStreamingDictationRecording)?.resume()
    }

    func stop() -> URL? {
        // `stop()` preserves the completed recording URL but both underlying
        // implementations intentionally keep a prepared graph for dictation
        // warm starts. Meetings must instead hand the input device back in a
        // fully cold state before the next capture lease is admitted.
        let url = recorder.stop()
        recorder.cancel()
        return url
    }

    func cancel() {
        recorder.cancel()
    }

    func currentPower() -> Float {
        recorder.currentPower()
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: kind,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil,
            captureRecovery: (recorder as? StreamingMicCaptureEventReporting)?.captureRecoveryDiagnostics
        )
    }

    private func wireCallbacks() {
        recorder.onAudioBuffer = { [weak self] samples in
            guard let self else { return }
            guard !self.lock.withLock({ $0 }) else { return }
            let int16Samples = samples.map { sample -> Int16 in
                Int16(max(-1.0, min(1.0, sample)) * 32767)
            }
            self.onRawPCMSamples?(int16Samples)
        }
        recorder.onRecordingFailed = { [weak self] error in
            self?.onRecordingFailed?(error)
        }
        (recorder as? StreamingMicCaptureEventReporting)?.onCaptureEvent = { [weak self] event in
            guard let self else { return }
            if let onCaptureEvent {
                onCaptureEvent(event)
            } else if case .failed(let failure) = event {
                // Preserve the legacy recorder contract for callers that do
                // not consume typed meeting capture events.
                self.onRecordingFailed?(failure.legacyError)
            }
        }
    }
}

final class RouteAwareMeetingMicRecorder: MeetingMicRecording {
    enum ActiveRecorderKind: Equatable {
        case systemDefault
        case appScoped
    }

    private enum LifecycleState {
        case idle
        case prepared
        case running
        case paused
        case awaitingFirstBuffer
        case stopping
    }

    private struct ActiveChild {
        let id: UUID
        let epoch: UInt64
        let kind: ActiveRecorderKind
        let recorder: MeetingMicRecording
        var selection: MeetingInputRouteSelection
        var input: StreamingMicInputSnapshot
    }

    private struct PendingHandoff {
        let childID: UUID
        let epoch: UInt64
        let selection: MeetingInputRouteSelection
        let previousInput: StreamingMicInputSnapshot
        let startedAt: TimeInterval
        let isFallback: Bool
        var shouldEmitDiscontinuity: Bool
        var currentInput: StreamingMicInputSnapshot
    }

    typealias RecorderFactory = () -> MeetingMicRecording

    var preferredInputDeviceID: AudioObjectID? {
        get { lock.withLock { preferredInputDeviceIDStorage } }
        set {
            let shouldRequestLiveChange = lock.withLock { () -> Bool in
                guard preferredInputDeviceIDStorage != newValue else { return false }
                preferredInputDeviceIDStorage = newValue
                if lifecycleState == .idle {
                    desiredSelectionStorage = nil
                }
                return lifecycleState != .idle
            }
            guard shouldRequestLiveChange else { return }
            let route = routeSnapshotProvider() ?? Self.fallbackRouteSnapshot(preferredInputDeviceID: newValue)
            let revision = lock.withLock { () -> UInt64 in
                syntheticRouteRevision &+= 1
                return max(syntheticRouteRevision, (desiredSelectionStorage?.revision ?? 0) &+ 1)
            }
            requestInputRouteChange(MeetingInputRouteSelection(
                revision: revision,
                preferredInputDeviceID: newValue,
                routeSnapshot: route
            ))
        }
    }

    var onRawPCMSamples: (([Int16]) -> Void)? {
        get { lock.withLock { onRawPCMSamplesStorage } }
        set { lock.withLock { onRawPCMSamplesStorage = newValue } }
    }
    var onRecordingFailed: ((Error) -> Void)? {
        get { lock.withLock { onRecordingFailedStorage } }
        set { lock.withLock { onRecordingFailedStorage = newValue } }
    }
    var onCaptureEvent: ((StreamingMicCaptureEvent) -> Void)? {
        get { lock.withLock { onCaptureEventStorage } }
        set { lock.withLock { onCaptureEventStorage = newValue } }
    }

    private let routeSnapshotProvider: () -> MeetingMicRouteDiagnosticsSnapshot?
    private let lifecycleQueue: DispatchQueue
    private let systemDefaultRecorderFactory: RecorderFactory
    private let appScopedRecorderFactory: RecorderFactory
    private let firstBufferTimeout: TimeInterval
    private let now: () -> TimeInterval
    private let lock = NSLock()
    private let callbackDeliveryGroup = DispatchGroup()
    private var seededSystemDefaultRecorder: MeetingMicRecording?
    private var seededAppScopedRecorder: MeetingMicRecording?
    private var preferredInputDeviceIDStorage: AudioObjectID?
    private var desiredSelectionStorage: MeetingInputRouteSelection?
    private var activeChildStorage: ActiveChild?
    private var pendingHandoffStorage: PendingHandoff?
    private var lifecycleState: LifecycleState = .idle
    private var sessionEpoch: UInt64 = 0
    private var syntheticRouteRevision: UInt64 = 0
    private var lastDeliveredEventGeneration: UInt64 = 0
    private var failedDesiredRevision: UInt64?
    private var routeChangeStartedAtStorage: TimeInterval?
    private var payloadAdmissionOpen = false
    private var onRawPCMSamplesStorage: (([Int16]) -> Void)?
    private var onRecordingFailedStorage: ((Error) -> Void)?
    private var onCaptureEventStorage: ((StreamingMicCaptureEvent) -> Void)?

    init(
        systemDefaultRecorder: MeetingMicRecording? = nil,
        appScopedRecorder: MeetingMicRecording? = nil,
        systemDefaultRecorderFactory: RecorderFactory? = nil,
        appScopedRecorderFactory: RecorderFactory? = nil,
        routeSnapshotProvider: @escaping () -> MeetingMicRouteDiagnosticsSnapshot? = { nil },
        lifecycleQueue: DispatchQueue = DispatchQueue(label: "com.muesli.route-aware-meeting-mic-recorder-lifecycle"),
        firstBufferTimeout: TimeInterval = 2.0,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.seededSystemDefaultRecorder = systemDefaultRecorder
        self.seededAppScopedRecorder = appScopedRecorder
        self.systemDefaultRecorderFactory = systemDefaultRecorderFactory ?? Self.makeSystemDefaultRecorder
        self.appScopedRecorderFactory = appScopedRecorderFactory ?? Self.makeAppScopedRecorder
        self.routeSnapshotProvider = routeSnapshotProvider
        self.lifecycleQueue = lifecycleQueue
        self.firstBufferTimeout = firstBufferTimeout
        self.now = now
    }

    func activeRecorderKindForDebug() -> ActiveRecorderKind {
        lock.withLock { activeChildStorage?.kind ?? kind(for: preferredInputDeviceIDStorage) }
    }

    func prepare() throws {
        try lifecycleQueue.sync {
            let selection = desiredSelectionOnLifecycleQueue()
            if let current = lock.withLock({ activeChildStorage }),
               current.selection.preferredInputDeviceID == selection.preferredInputDeviceID,
               lock.withLock({ lifecycleState == .prepared }) {
                return
            }
            retireCurrentChildOnLifecycleQueue(deleteRecording: true, useStop: false)
            let child = makeChildOnLifecycleQueue(selection: selection)
            lock.withLock {
                activeChildStorage = child
                lifecycleState = .prepared
                payloadAdmissionOpen = false
            }
            do {
                try child.recorder.prepare()
            } catch {
                // Prewarm is best effort. Keep this recorder selected so the
                // real `start()` can rebuild/retry on the same route after a
                // transient CoreAudio preparation failure.
                throw error
            }
        }
    }

    func start() throws {
        lifecycleQueue.sync {
            let selection = desiredSelectionOnLifecycleQueue()
            var child = lock.withLock { activeChildStorage }
            if child == nil || child?.selection.preferredInputDeviceID != selection.preferredInputDeviceID {
                retireCurrentChildOnLifecycleQueue(deleteRecording: true, useStop: false)
                child = makeChildOnLifecycleQueue(selection: selection)
            }
            guard let child else { return }
            let epoch = lock.withLock { sessionEpoch }
            let input = Self.inputSnapshot(for: selection)
            let startedAt = now()
            lock.withLock {
                var activated = child
                activated.selection = selection
                activated.input = input
                activeChildStorage = activated
                lifecycleState = .awaitingFirstBuffer
                pendingHandoffStorage = PendingHandoff(
                    childID: child.id,
                    epoch: epoch,
                    selection: selection,
                    previousInput: input,
                    startedAt: startedAt,
                    isFallback: false,
                    shouldEmitDiscontinuity: false,
                    currentInput: input
                )
                failedDesiredRevision = nil
                payloadAdmissionOpen = false
            }
            child.recorder.preferredInputDeviceID = selection.preferredInputDeviceID
            do {
                try child.recorder.start()
            } catch {
                handleReplacementFailureOnLifecycleQueue(
                    childID: child.id,
                    epoch: epoch,
                    message: "Could not start the meeting microphone: \(error.localizedDescription)"
                )
                return
            }
            scheduleFirstBufferTimeout(childID: child.id, epoch: epoch)
        }
    }

    func requestInputRouteChange(_ selection: MeetingInputRouteSelection) {
        let shouldSchedule = lock.withLock { () -> Bool in
            if let desiredSelectionStorage,
               selection.revision < desiredSelectionStorage.revision {
                return false
            }
            if desiredSelectionStorage == selection {
                return false
            }
            desiredSelectionStorage = selection
            preferredInputDeviceIDStorage = selection.preferredInputDeviceID
            syntheticRouteRevision = max(syntheticRouteRevision, selection.revision)
            if failedDesiredRevision != selection.revision {
                failedDesiredRevision = nil
            }
            switch lifecycleState {
            case .running, .awaitingFirstBuffer:
                if pendingHandoffStorage == nil,
                   activeChildStorage?.selection.preferredInputDeviceID == selection.preferredInputDeviceID {
                    activeChildStorage?.selection = selection
                    return false
                }
                if routeChangeStartedAtStorage == nil {
                    routeChangeStartedAtStorage = now()
                }
                payloadAdmissionOpen = false
                return true
            case .prepared:
                return true
            case .idle, .paused, .stopping:
                return false
            }
        }
        guard shouldSchedule else { return }
        lifecycleQueue.async { [weak self] in
            self?.applyLatestRouteOnLifecycleQueue()
        }
    }

    func pause() {
        let shouldPause = lock.withLock { () -> Bool in
            guard lifecycleState == .running || lifecycleState == .awaitingFirstBuffer else { return false }
            payloadAdmissionOpen = false
            lifecycleState = .paused
            return true
        }
        guard shouldPause else { return }
        // Closing admission under the state lock prevents any new callback
        // from entering. Only already-admitted, lightweight handler delivery
        // is drained here; potentially blocking CoreAudio graph work remains
        // on the lifecycle queue so pause controls stay responsive.
        callbackDeliveryGroup.wait()
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.activeChildStorage?.recorder }?.pause()
        }
    }

    func resume() {
        let resumeState = lock.withLock { () -> (shouldResume: Bool, hadPendingHandoff: Bool) in
            guard lifecycleState == .paused else { return (false, false) }
            let hadPendingHandoff = pendingHandoffStorage != nil
            lifecycleState = hadPendingHandoff ? .awaitingFirstBuffer : .running
            return (true, hadPendingHandoff)
        }
        guard resumeState.shouldResume else { return }
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            let pendingState = self.lock.withLock {
                (
                    pending: self.pendingHandoffStorage,
                    desiredRevision: self.desiredSelectionStorage?.revision,
                    recorder: self.activeChildStorage?.recorder
                )
            }
            if let pending = pendingState.pending,
               pendingState.desiredRevision == pending.selection.revision {
                pendingState.recorder?.resume()
                self.scheduleFirstBufferTimeout(childID: pending.childID, epoch: pending.epoch)
                return
            }
            let shouldSwitch = self.lock.withLock { () -> Bool in
                guard let desired = self.desiredSelectionStorage,
                      let active = self.activeChildStorage else { return false }
                if let pending = self.pendingHandoffStorage,
                   pending.selection.revision != desired.revision {
                    return true
                }
                if self.failedDesiredRevision == desired.revision {
                    return false
                }
                return desired.preferredInputDeviceID != active.selection.preferredInputDeviceID
            }
            if shouldSwitch {
                self.applyLatestRouteOnLifecycleQueue()
            } else {
                let recorder = self.lock.withLock { self.activeChildStorage?.recorder }
                if pendingState.pending == nil {
                    recorder?.resume()
                }
                self.lock.withLock { self.payloadAdmissionOpen = true }
            }
        }
    }

    func stop() -> URL? {
        lock.withLock {
            sessionEpoch &+= 1
            payloadAdmissionOpen = false
            pendingHandoffStorage = nil
            routeChangeStartedAtStorage = nil
            lifecycleState = .stopping
        }
        return lifecycleQueue.sync {
            let child = lock.withLock { () -> ActiveChild? in
                let child = activeChildStorage
                activeChildStorage = nil
                return child
            }
            let url = child?.recorder.stop()
            child?.recorder.cancel()
            cancelUnusedSeedRecordersOnLifecycleQueue()
            lock.withLock { lifecycleState = .idle }
            return url
        }
    }

    func cancel() {
        lock.withLock {
            sessionEpoch &+= 1
            payloadAdmissionOpen = false
            pendingHandoffStorage = nil
            routeChangeStartedAtStorage = nil
            lifecycleState = .stopping
        }
        lifecycleQueue.sync {
            let child = lock.withLock { () -> ActiveChild? in
                let child = activeChildStorage
                activeChildStorage = nil
                return child
            }
            child?.recorder.cancel()
            cancelUnusedSeedRecordersOnLifecycleQueue()
            lock.withLock { lifecycleState = .idle }
        }
    }

    func currentPower() -> Float {
        let recorder = lock.withLock {
            payloadAdmissionOpen ? activeChildStorage?.recorder : nil
        }
        return recorder?.currentPower() ?? -160
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        let state = lock.withLock {
            (child: activeChildStorage, preferredInputDeviceID: preferredInputDeviceIDStorage)
        }
        let child = state.child
        guard let child else {
            return MeetingMicRecorderDiagnosticsSnapshot(
                recorderKind: kind(for: state.preferredInputDeviceID).diagnosticsKind,
                preferredInputDeviceID: state.preferredInputDeviceID,
                route: routeSnapshotProvider()
            )
        }
        let childSnapshot = child.recorder.diagnosticsSnapshot()
        return MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: childSnapshot.recorderKind,
            preferredInputDeviceID: child.selection.preferredInputDeviceID,
            route: routeSnapshotProvider() ?? child.selection.routeSnapshot,
            captureRecovery: childSnapshot.captureRecovery
        )
    }

    private func applyLatestRouteOnLifecycleQueue() {
        let state = lock.withLock { lifecycleState }
        guard state != .idle, state != .paused, state != .stopping else { return }
        guard let desired = lock.withLock({ desiredSelectionStorage }) else { return }

        if state == .prepared {
            retireCurrentChildOnLifecycleQueue(deleteRecording: true, useStop: false)
            lock.withLock { lifecycleState = .idle }
            return
        }

        if let active = lock.withLock({ activeChildStorage }),
           active.selection.preferredInputDeviceID == desired.preferredInputDeviceID,
           lock.withLock({ failedDesiredRevision != desired.revision }) {
            lock.withLock {
                guard activeChildStorage?.id == active.id else { return }
                activeChildStorage?.selection = desired
                if let pending = pendingHandoffStorage,
                   pending.childID == active.id {
                    // Another queued/coalesced request reached the lifecycle
                    // lane while this same physical route was still awaiting
                    // proof. Refresh its revision/diagnostics, but never open
                    // admission before the first replacement buffer.
                    pendingHandoffStorage = PendingHandoff(
                        childID: pending.childID,
                        epoch: pending.epoch,
                        selection: desired,
                        previousInput: pending.previousInput,
                        startedAt: pending.startedAt,
                        isFallback: pending.isFallback,
                        shouldEmitDiscontinuity: pending.shouldEmitDiscontinuity,
                        currentInput: Self.inputSnapshot(for: desired)
                    )
                    lifecycleState = .awaitingFirstBuffer
                    payloadAdmissionOpen = false
                } else {
                    routeChangeStartedAtStorage = nil
                    lifecycleState = .running
                    payloadAdmissionOpen = true
                }
            }
            return
        }

        if lock.withLock({ failedDesiredRevision == desired.revision }),
           lock.withLock({ activeChildStorage != nil }) {
            lock.withLock {
                lifecycleState = .running
                payloadAdmissionOpen = true
            }
            return
        }

        let previousInput = lock.withLock {
            activeChildStorage?.input ?? Self.inputSnapshot(for: desired)
        }
        let startedAt = lock.withLock { () -> TimeInterval in
            if let routeChangeStartedAtStorage {
                return routeChangeStartedAtStorage
            }
            let startedAt = now()
            routeChangeStartedAtStorage = startedAt
            return startedAt
        }
        retireCurrentChildOnLifecycleQueue(deleteRecording: true, useStop: state != .prepared)

        // Route changes can arrive while CoreAudio teardown is blocked. Always
        // use the newest selection after the old graph has fully drained.
        guard let latest = lock.withLock({ desiredSelectionStorage }) else { return }
        startReplacementOnLifecycleQueue(
            selection: latest,
            previousInput: previousInput,
            startedAt: startedAt,
            isFallback: false
        )
    }

    private func startReplacementOnLifecycleQueue(
        selection: MeetingInputRouteSelection,
        previousInput: StreamingMicInputSnapshot,
        startedAt: TimeInterval,
        isFallback: Bool
    ) {
        let child = makeChildOnLifecycleQueue(selection: selection)
        let epoch = lock.withLock { sessionEpoch }
        let pending = PendingHandoff(
            childID: child.id,
            epoch: epoch,
            selection: selection,
            previousInput: previousInput,
            startedAt: startedAt,
            isFallback: isFallback,
            shouldEmitDiscontinuity: true,
            currentInput: child.input
        )
        lock.withLock {
            activeChildStorage = child
            pendingHandoffStorage = pending
            lifecycleState = .awaitingFirstBuffer
            payloadAdmissionOpen = false
        }

        if let prepareError = MeetingMicStartupPreflight.prepareBestEffort(child.recorder) {
            fputs("[meeting] replacement microphone prewarm failed: \(prepareError.localizedDescription)\n", stderr)
        }
        do {
            try child.recorder.start()
        } catch {
            handleReplacementFailureOnLifecycleQueue(
                childID: child.id,
                epoch: epoch,
                message: "Could not start the selected meeting microphone: \(error.localizedDescription)"
            )
            return
        }

        scheduleFirstBufferTimeout(childID: child.id, epoch: epoch)
    }

    private func scheduleFirstBufferTimeout(childID: UUID, epoch: UInt64) {
        lifecycleQueue.asyncAfter(deadline: .now() + firstBufferTimeout) { [weak self] in
            self?.handleReplacementFailureOnLifecycleQueue(
                childID: childID,
                epoch: epoch,
                message: "The selected meeting microphone started but produced no audio."
            )
        }
    }

    private func handleReplacementFailureOnLifecycleQueue(
        childID: UUID,
        epoch: UInt64,
        message: String
    ) {
        guard let pending = lock.withLock({ pendingHandoffStorage }),
              pending.childID == childID,
              pending.epoch == epoch,
              lock.withLock({ sessionEpoch == epoch }) else { return }
        if lock.withLock({ lifecycleState == .paused }) {
            scheduleFirstBufferTimeout(childID: childID, epoch: epoch)
            return
        }

        let failedChild = lock.withLock { () -> ActiveChild? in
            guard activeChildStorage?.id == childID else { return nil }
            let child = activeChildStorage
            activeChildStorage = nil
            pendingHandoffStorage = nil
            payloadAdmissionOpen = false
            return child
        }
        let failedURL = failedChild?.recorder.stop()
        failedChild?.recorder.cancel()
        Self.deleteTemporaryRecording(failedURL)
        publishSyntheticFailure(
            previousInput: pending.previousInput,
            message: message
        )

        guard !pending.isFallback,
              lock.withLock({ desiredSelectionStorage?.revision == pending.selection.revision }),
              let fallback = Self.fallbackSelection(from: pending.selection) else {
            lock.withLock {
                routeChangeStartedAtStorage = nil
                lifecycleState = .running
            }
            return
        }

        lock.withLock { failedDesiredRevision = pending.selection.revision }
        startReplacementOnLifecycleQueue(
            selection: fallback,
            previousInput: pending.previousInput,
            startedAt: pending.startedAt,
            isFallback: true
        )
    }

    private func forwardRawSamples(_ samples: [Int16], childID: UUID, epoch: UInt64) {
        guard !samples.isEmpty else { return }
        var recoveryEvent: StreamingMicCaptureEvent?
        var handler: (([Int16]) -> Void)?
        var enteredDelivery = false
        lock.withLock {
            guard sessionEpoch == epoch,
                  var child = activeChildStorage,
                  child.id == childID else { return }
            guard lifecycleState != .paused else { return }
            if let pending = pendingHandoffStorage, pending.childID == childID {
                let desiredRevision = desiredSelectionStorage?.revision ?? pending.selection.revision
                guard desiredRevision == pending.selection.revision else { return }
                if pending.shouldEmitDiscontinuity {
                    let generation = nextEventGenerationLocked(proposed: nil)
                    let downtime = max(0, now() - pending.startedAt)
                    let discontinuity = StreamingMicDiscontinuity(
                        generation: generation,
                        reason: .inputConfigurationChanged,
                        missingSampleCount: Int64((downtime * 16_000).rounded()),
                        downtimeSeconds: downtime,
                        restartAttemptCount: 1,
                        previousInput: pending.previousInput,
                        currentInput: pending.currentInput
                    )
                    recoveryEvent = .recovered(discontinuity)
                }
                child.input = pending.currentInput
                activeChildStorage = child
                pendingHandoffStorage = nil
                routeChangeStartedAtStorage = nil
                lifecycleState = .running
                payloadAdmissionOpen = true
            }
            guard payloadAdmissionOpen else { return }
            handler = onRawPCMSamplesStorage
            if recoveryEvent != nil || handler != nil {
                callbackDeliveryGroup.enter()
                enteredDelivery = true
            }
        }
        defer {
            if enteredDelivery {
                callbackDeliveryGroup.leave()
            }
        }
        if let recoveryEvent {
            onCaptureEvent?(recoveryEvent)
        }
        handler?(samples)
    }

    private func forwardFailure(_ error: Error, childID: UUID, epoch: UInt64) {
        let isPending = lock.withLock {
            sessionEpoch == epoch && pendingHandoffStorage?.childID == childID
        }
        if isPending {
            lifecycleQueue.async { [weak self] in
                self?.handleReplacementFailureOnLifecycleQueue(
                    childID: childID,
                    epoch: epoch,
                    message: error.localizedDescription
                )
            }
            return
        }
        let handler = lock.withLock {
            sessionEpoch == epoch && activeChildStorage?.id == childID
                ? onRecordingFailedStorage
                : nil
        }
        handler?(error)
    }

    private func forwardCaptureEvent(_ event: StreamingMicCaptureEvent, childID: UUID, epoch: UInt64) {
        var forwarded: StreamingMicCaptureEvent?
        var pendingFailureMessage: String?
        var legacyFailure: ((Error) -> Void)?
        lock.withLock {
            guard sessionEpoch == epoch, activeChildStorage?.id == childID else { return }
            if var pending = pendingHandoffStorage, pending.childID == childID {
                switch event {
                case .recovered(let discontinuity):
                    pending.currentInput = discontinuity.currentInput
                    pending.shouldEmitDiscontinuity = true
                    pendingHandoffStorage = pending
                case .failed(let failure):
                    pendingFailureMessage = failure.message
                }
                return
            }
            switch event {
            case .recovered(let discontinuity):
                let generation = nextEventGenerationLocked(proposed: discontinuity.generation)
                activeChildStorage?.input = discontinuity.currentInput
                forwarded = .recovered(StreamingMicDiscontinuity(
                    generation: generation,
                    reason: discontinuity.reason,
                    missingSampleCount: discontinuity.missingSampleCount,
                    downtimeSeconds: discontinuity.downtimeSeconds,
                    restartAttemptCount: discontinuity.restartAttemptCount,
                    previousInput: discontinuity.previousInput,
                    currentInput: discontinuity.currentInput
                ))
            case .failed(let failure):
                let generation = nextEventGenerationLocked(proposed: failure.generation)
                let mapped = StreamingMicCaptureFailure(
                    generation: generation,
                    reason: failure.reason,
                    restartAttemptCount: failure.restartAttemptCount,
                    previousInput: failure.previousInput,
                    message: failure.message
                )
                forwarded = .failed(mapped)
                legacyFailure = onCaptureEventStorage == nil ? onRecordingFailedStorage : nil
            }
        }
        if let pendingFailureMessage {
            lifecycleQueue.async { [weak self] in
                self?.handleReplacementFailureOnLifecycleQueue(
                    childID: childID,
                    epoch: epoch,
                    message: pendingFailureMessage
                )
            }
            return
        }
        if let forwarded {
            if let onCaptureEvent {
                onCaptureEvent(forwarded)
            } else if case .failed(let failure) = forwarded {
                legacyFailure?(failure.legacyError)
            }
        }
    }

    private func publishSyntheticFailure(
        previousInput: StreamingMicInputSnapshot,
        message: String
    ) {
        let result = lock.withLock { () -> (StreamingMicCaptureEvent, ((StreamingMicCaptureEvent) -> Void)?, ((Error) -> Void)?) in
            let generation = nextEventGenerationLocked(proposed: nil)
            let failure = StreamingMicCaptureFailure(
                generation: generation,
                reason: .inputConfigurationChanged,
                restartAttemptCount: 1,
                previousInput: previousInput,
                message: message
            )
            return (.failed(failure), onCaptureEventStorage, onRecordingFailedStorage)
        }
        if let capture = result.1 {
            capture(result.0)
        } else if case .failed(let failure) = result.0 {
            result.2?(failure.legacyError)
        }
    }

    private func nextEventGenerationLocked(proposed: UInt64?) -> UInt64 {
        let minimum = lastDeliveredEventGeneration &+ 1
        lastDeliveredEventGeneration = max(minimum, proposed ?? minimum)
        return lastDeliveredEventGeneration
    }

    private func desiredSelectionOnLifecycleQueue() -> MeetingInputRouteSelection {
        if let desired = lock.withLock({ desiredSelectionStorage }) {
            return desired
        }
        let preferred = lock.withLock { preferredInputDeviceIDStorage }
        let route = routeSnapshotProvider() ?? Self.fallbackRouteSnapshot(preferredInputDeviceID: preferred)
        let selection = MeetingInputRouteSelection(
            revision: 0,
            preferredInputDeviceID: preferred,
            routeSnapshot: route
        )
        lock.withLock { desiredSelectionStorage = selection }
        return selection
    }

    private func makeChildOnLifecycleQueue(selection: MeetingInputRouteSelection) -> ActiveChild {
        let kind = kind(for: selection.preferredInputDeviceID)
        let recorder: MeetingMicRecording
        switch kind {
        case .systemDefault:
            if let seeded = seededSystemDefaultRecorder {
                seededSystemDefaultRecorder = nil
                recorder = seeded
            } else {
                recorder = systemDefaultRecorderFactory()
            }
        case .appScoped:
            if let seeded = seededAppScopedRecorder {
                seededAppScopedRecorder = nil
                recorder = seeded
            } else {
                recorder = appScopedRecorderFactory()
            }
        }
        recorder.preferredInputDeviceID = selection.preferredInputDeviceID
        let id = UUID()
        let epoch = lock.withLock { sessionEpoch }
        wireCallbacks(for: recorder, childID: id, epoch: epoch)
        return ActiveChild(
            id: id,
            epoch: epoch,
            kind: kind,
            recorder: recorder,
            selection: selection,
            input: Self.inputSnapshot(for: selection)
        )
    }

    private func wireCallbacks(for recorder: MeetingMicRecording, childID: UUID, epoch: UInt64) {
        recorder.onRawPCMSamples = { [weak self] samples in
            self?.forwardRawSamples(samples, childID: childID, epoch: epoch)
        }
        recorder.onRecordingFailed = { [weak self] error in
            self?.forwardFailure(error, childID: childID, epoch: epoch)
        }
        recorder.onCaptureEvent = { [weak self] event in
            self?.forwardCaptureEvent(event, childID: childID, epoch: epoch)
        }
    }

    private func retireCurrentChildOnLifecycleQueue(deleteRecording: Bool, useStop: Bool) {
        let child = lock.withLock { () -> ActiveChild? in
            payloadAdmissionOpen = false
            pendingHandoffStorage = nil
            let child = activeChildStorage
            activeChildStorage = nil
            return child
        }
        guard let child else { return }
        let url = useStop ? child.recorder.stop() : nil
        child.recorder.cancel()
        child.recorder.onRawPCMSamples = nil
        child.recorder.onCaptureEvent = nil
        child.recorder.onRecordingFailed = nil
        if deleteRecording {
            Self.deleteTemporaryRecording(url)
        }
    }

    private func cancelUnusedSeedRecordersOnLifecycleQueue() {
        seededSystemDefaultRecorder?.cancel()
        seededAppScopedRecorder?.cancel()
        seededSystemDefaultRecorder = nil
        seededAppScopedRecorder = nil
    }

    private func kind(for preferredInputDeviceID: AudioObjectID?) -> ActiveRecorderKind {
        preferredInputDeviceID == nil ? .systemDefault : .appScoped
    }

    private static func makeSystemDefaultRecorder() -> MeetingMicRecording {
        StreamingMeetingMicRecorderAdapter(
            recorder: StreamingMicRecorder(directoryName: "muesli-meeting-mic"),
            kind: .systemDefaultStreaming
        )
    }

    private static func makeAppScopedRecorder() -> MeetingMicRecording {
        StreamingMeetingMicRecorderAdapter(
            recorder: FallbackStreamingDictationRecorder(
                primary: AudioQueueInputRecorder(directoryName: "muesli-meeting-mic-audioqueue"),
                fallback: StreamingMicRecorder(directoryName: "muesli-meeting-mic-app-scoped-fallback")
            ),
            kind: .appScopedAudioQueue
        )
    }

    private static func inputSnapshot(for selection: MeetingInputRouteSelection) -> StreamingMicInputSnapshot {
        StreamingMicInputSnapshot(
            requestedDeviceID: selection.preferredInputDeviceID,
            actualDeviceID: selection.preferredInputDeviceID ?? selection.routeSnapshot.defaultInputDeviceID,
            sampleRate: 16_000,
            channelCount: 1
        )
    }

    private static func fallbackSelection(
        from selection: MeetingInputRouteSelection
    ) -> MeetingInputRouteSelection? {
        let route = selection.routeSnapshot
        let fallbackDeviceID: AudioObjectID?
        let fallbackDeviceName: String?
        if selection.preferredInputDeviceID != nil {
            // An explicit AudioQueue route failed; yield to the meeting app's
            // already-open system-default route.
            fallbackDeviceID = nil
            fallbackDeviceName = route.defaultInputDeviceName
        } else {
            // The system-default route failed. If the default is an external
            // device, preserve the user's voice by falling back to the Mac mic
            // through the app-scoped recorder. Do not retry the same physical
            // default device under a different recorder label.
            guard let builtInInputDeviceID = route.builtInInputDeviceID,
                  builtInInputDeviceID != route.defaultInputDeviceID else { return nil }
            fallbackDeviceID = builtInInputDeviceID
            fallbackDeviceName = nil
        }
        return MeetingInputRouteSelection(
            revision: selection.revision,
            preferredInputDeviceID: fallbackDeviceID,
            routeSnapshot: MeetingMicRouteDiagnosticsSnapshot(
                outputRouteKind: route.outputRouteKind,
                outputIsAmbiguousBluetooth: route.outputIsAmbiguousBluetooth,
                selectedInputDeviceUID: route.selectedInputDeviceUID,
                selectedInputDeviceResolved: route.selectedInputDeviceResolved,
                preferredInputDeviceID: fallbackDeviceID,
                preferredInputDeviceName: fallbackDeviceName,
                defaultInputDeviceID: route.defaultInputDeviceID,
                defaultInputDeviceName: route.defaultInputDeviceName,
                builtInInputDeviceID: route.builtInInputDeviceID,
                systemDefaultInputIsBuiltIn: route.systemDefaultInputIsBuiltIn
            )
        )
    }

    private static func fallbackRouteSnapshot(
        preferredInputDeviceID: AudioObjectID?
    ) -> MeetingMicRouteDiagnosticsSnapshot {
        MeetingMicRouteDiagnosticsSnapshot(
            outputRouteKind: "unknown",
            outputIsAmbiguousBluetooth: false,
            selectedInputDeviceUID: nil,
            selectedInputDeviceResolved: true,
            preferredInputDeviceID: preferredInputDeviceID,
            preferredInputDeviceName: nil,
            defaultInputDeviceID: nil,
            defaultInputDeviceName: nil,
            builtInInputDeviceID: nil,
            systemDefaultInputIsBuiltIn: false
        )
    }

    private static func deleteTemporaryRecording(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private extension RouteAwareMeetingMicRecorder.ActiveRecorderKind {
    var diagnosticsKind: MeetingMicRecorderKind {
        switch self {
        case .systemDefault: return .systemDefaultStreaming
        case .appScoped: return .appScopedAudioQueue
        }
    }
}
