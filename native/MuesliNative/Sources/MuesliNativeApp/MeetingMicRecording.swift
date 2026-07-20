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

    var preferredInputDeviceID: AudioObjectID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return preferredInputDeviceIDStorage
        }
        set {
            lifecycleQueue.sync {
                lock.lock()
                preferredInputDeviceIDStorage = newValue
                let recorder = activeRecorderLocked()
                lock.unlock()
                recorder.preferredInputDeviceID = newValue
            }
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

    private let systemDefaultRecorder: MeetingMicRecording
    private let appScopedRecorder: MeetingMicRecording
    private let routeSnapshotProvider: () -> MeetingMicRouteDiagnosticsSnapshot?
    private let lifecycleQueue: DispatchQueue
    private let lock = NSRecursiveLock()
    private var preferredInputDeviceIDStorage: AudioObjectID?
    private var activeRecorderKindStorage: ActiveRecorderKind = .systemDefault
    private var onRawPCMSamplesStorage: (([Int16]) -> Void)?
    private var onRecordingFailedStorage: ((Error) -> Void)?
    private var onCaptureEventStorage: ((StreamingMicCaptureEvent) -> Void)?

    init(
        systemDefaultRecorder: MeetingMicRecording = StreamingMeetingMicRecorderAdapter(
            recorder: StreamingMicRecorder(directoryName: "muesli-meeting-mic"),
            kind: .systemDefaultStreaming
        ),
        appScopedRecorder: MeetingMicRecording = StreamingMeetingMicRecorderAdapter(
            recorder: FallbackStreamingDictationRecorder(
                primary: AudioQueueInputRecorder(directoryName: "muesli-meeting-mic-audioqueue"),
                fallback: StreamingMicRecorder(directoryName: "muesli-meeting-mic-app-scoped-fallback")
            ),
            kind: .appScopedAudioQueue
        ),
        routeSnapshotProvider: @escaping () -> MeetingMicRouteDiagnosticsSnapshot? = { nil },
        lifecycleQueue: DispatchQueue = DispatchQueue(label: "com.muesli.route-aware-meeting-mic-recorder-lifecycle")
    ) {
        self.systemDefaultRecorder = systemDefaultRecorder
        self.appScopedRecorder = appScopedRecorder
        self.routeSnapshotProvider = routeSnapshotProvider
        self.lifecycleQueue = lifecycleQueue
        wireCallbacks()
    }

    func activeRecorderKindForDebug() -> ActiveRecorderKind {
        lock.lock()
        defer { lock.unlock() }
        return activeRecorderKindStorage
    }

    func prepare() throws {
        try lifecycleQueue.sync {
            let recorder = selectRecorder(preferredInputDeviceID: currentPreferredInputDeviceID())
            try recorder.prepare()
        }
    }

    func start() throws {
        try lifecycleQueue.sync {
            let recorder = selectRecorder(preferredInputDeviceID: currentPreferredInputDeviceID())
            try recorder.start()
        }
    }

    func pause() {
        lifecycleQueue.sync {
            activeRecorder().pause()
        }
    }

    func resume() {
        lifecycleQueue.sync {
            activeRecorder().resume()
        }
    }

    func stop() -> URL? {
        lifecycleQueue.sync {
            lock.lock()
            let activeRecorder = activeRecorderLocked()
            let inactiveRecorder = inactiveRecorderLocked()
            lock.unlock()
            let url = activeRecorder.stop()
            inactiveRecorder.cancel()
            return url
        }
    }

    func cancel() {
        lifecycleQueue.sync {
            systemDefaultRecorder.cancel()
            appScopedRecorder.cancel()
        }
    }

    func currentPower() -> Float {
        activeRecorder().currentPower()
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        var snapshot = activeRecorder().diagnosticsSnapshot()
        if snapshot.route == nil {
            snapshot = MeetingMicRecorderDiagnosticsSnapshot(
                recorderKind: snapshot.recorderKind,
                preferredInputDeviceID: snapshot.preferredInputDeviceID,
                route: routeSnapshotProvider(),
                captureRecovery: snapshot.captureRecovery
            )
        }
        return snapshot
    }

    private func wireCallbacks() {
        wireCallbacks(for: systemDefaultRecorder, kind: .systemDefault)
        wireCallbacks(for: appScopedRecorder, kind: .appScoped)
    }

    private func wireCallbacks(for recorder: MeetingMicRecording, kind: ActiveRecorderKind) {
        recorder.onRawPCMSamples = { [weak self] samples in
            self?.forwardRawSamples(samples, from: kind)
        }
        recorder.onRecordingFailed = { [weak self] error in
            self?.forwardFailure(error, from: kind)
        }
        recorder.onCaptureEvent = { [weak self] event in
            self?.forwardCaptureEvent(event, from: kind)
        }
    }

    private func forwardRawSamples(_ samples: [Int16], from kind: ActiveRecorderKind) {
        let handler = lock.withLock {
            activeRecorderKindStorage == kind ? onRawPCMSamplesStorage : nil
        }
        handler?(samples)
    }

    private func forwardFailure(_ error: Error, from kind: ActiveRecorderKind) {
        let handler = lock.withLock {
            activeRecorderKindStorage == kind ? onRecordingFailedStorage : nil
        }
        handler?(error)
    }

    private func forwardCaptureEvent(_ event: StreamingMicCaptureEvent, from kind: ActiveRecorderKind) {
        let handlers: (
            capture: ((StreamingMicCaptureEvent) -> Void)?,
            failure: ((Error) -> Void)?
        ) = lock.withLock {
            guard activeRecorderKindStorage == kind else {
                return (capture: nil, failure: nil)
            }
            return (capture: onCaptureEventStorage, failure: onRecordingFailedStorage)
        }
        if let capture = handlers.capture {
            capture(event)
        } else if case .failed(let failure) = event {
            handlers.failure?(failure.legacyError)
        }
    }

    private func currentPreferredInputDeviceID() -> AudioObjectID? {
        lock.lock()
        defer { lock.unlock() }
        return preferredInputDeviceIDStorage
    }

    private func selectRecorder(preferredInputDeviceID: AudioObjectID?) -> MeetingMicRecording {
        lock.lock()
        let nextKind: ActiveRecorderKind = preferredInputDeviceID == nil ? .systemDefault : .appScoped
        let inactiveRecorderToCancel = nextKind == activeRecorderKindStorage ? nil : activeRecorderLocked()
        preferredInputDeviceIDStorage = preferredInputDeviceID
        activeRecorderKindStorage = nextKind
        let selectedRecorder = activeRecorderLocked()
        lock.unlock()

        selectedRecorder.preferredInputDeviceID = preferredInputDeviceID
        inactiveRecorderToCancel?.cancel()
        return selectedRecorder
    }

    private func activeRecorder() -> MeetingMicRecording {
        lock.lock()
        defer { lock.unlock() }
        return activeRecorderLocked()
    }

    private func activeRecorderLocked() -> MeetingMicRecording {
        recorder(for: activeRecorderKindStorage)
    }

    private func inactiveRecorderLocked() -> MeetingMicRecording {
        inactiveRecorder(for: activeRecorderKindStorage)
    }

    private func recorder(for kind: ActiveRecorderKind) -> MeetingMicRecording {
        switch kind {
        case .systemDefault:
            return systemDefaultRecorder
        case .appScoped:
            return appScopedRecorder
        }
    }

    private func inactiveRecorder(for kind: ActiveRecorderKind) -> MeetingMicRecording {
        switch kind {
        case .systemDefault:
            return appScopedRecorder
        case .appScoped:
            return systemDefaultRecorder
        }
    }
}
