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
}

protocol MeetingMicRecording: AnyObject {
    var preferredInputDeviceID: AudioObjectID? { get set }
    var onRawPCMSamples: (([Int16]) -> Void)? { get set }
    var onRecordingFailed: ((Error) -> Void)? { get set }

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
    var onRecordingFailed: ((Error) -> Void)? {
        get { recorder.onRecordingFailed }
        set { recorder.onRecordingFailed = newValue }
    }

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
        lock.withLock { $0 = true }
        (recorder as? PausableStreamingDictationRecording)?.pause()
    }

    func resume() {
        lock.withLock { $0 = false }
        (recorder as? PausableStreamingDictationRecording)?.resume()
    }

    func stop() -> URL? {
        recorder.stop()
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
            route: nil
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
    }
}

final class RouteAwareMeetingMicRecorder: MeetingMicRecording {
    enum ActiveRecorderKind: Equatable { case systemDefault, appScoped }
    private enum LifecycleState { case idle, prepared, running, paused, stopping }
    private struct Child {
        let id: UUID
        let generation: UInt64
        let kind: ActiveRecorderKind
        let recorder: MeetingMicRecording
        let deviceID: AudioObjectID?
    }
    typealias RecorderFactory = () -> MeetingMicRecording

    var preferredInputDeviceID: AudioObjectID? {
        get { lock.withLock { $0.preferredInputDeviceIDStorage } }
        set {
            let shouldHandoff = lock.withLock { state -> Bool in
                guard state.preferredInputDeviceIDStorage != newValue else { return false }
                state.preferredInputDeviceIDStorage = newValue
                if state.lifecycleState == .running { state.generation &+= 1 }
                return state.lifecycleState == .running
            }
            if shouldHandoff {
                lifecycleQueue.async { [weak self] in self?.restartHandoffIfNeeded() }
            }
        }
    }
    var onRawPCMSamples: (([Int16]) -> Void)? {
        get { lock.withLock { $0.onRawPCMSamplesStorage } }
        set { lock.withLock { $0.onRawPCMSamplesStorage = newValue } }
    }
    var onRecordingFailed: ((Error) -> Void)? {
        get { lock.withLock { $0.onRecordingFailedStorage } }
        set { lock.withLock { $0.onRecordingFailedStorage = newValue } }
    }

    private let systemDefaultRecorderFactory: RecorderFactory
    private let appScopedRecorderFactory: RecorderFactory
    private var seededSystemDefaultRecorder: MeetingMicRecording?
    private var seededAppScopedRecorder: MeetingMicRecording?
    private let routeSnapshotProvider: () -> MeetingMicRouteDiagnosticsSnapshot?
    private let lifecycleQueue: DispatchQueue
    private let handoffTimeout: TimeInterval
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var preferredInputDeviceIDStorage: AudioObjectID?
        var lifecycleState: LifecycleState = .idle
        var active: Child?
        var pending: Child?
        var generation: UInt64 = 0
        var onRawPCMSamplesStorage: (([Int16]) -> Void)?
        var onRecordingFailedStorage: ((Error) -> Void)?
    }

    private var preferredInputDeviceIDStorage: AudioObjectID? {
        get { lock.withLock { $0.preferredInputDeviceIDStorage } }
        set { lock.withLock { $0.preferredInputDeviceIDStorage = newValue } }
    }
    private var lifecycleState: LifecycleState { lock.withLock { $0.lifecycleState } }
    private var onRawPCMSamplesStorage: (([Int16]) -> Void)? { lock.withLock { $0.onRawPCMSamplesStorage } }
    private var onRecordingFailedStorage: ((Error) -> Void)? { lock.withLock { $0.onRecordingFailedStorage } }

    init(
        systemDefaultRecorder: MeetingMicRecording? = nil,
        appScopedRecorder: MeetingMicRecording? = nil,
        systemDefaultRecorderFactory: RecorderFactory? = nil,
        appScopedRecorderFactory: RecorderFactory? = nil,
        routeSnapshotProvider: @escaping () -> MeetingMicRouteDiagnosticsSnapshot? = { nil },
        lifecycleQueue: DispatchQueue = DispatchQueue(label: "com.muesli.route-aware-meeting-mic-recorder-lifecycle"),
        handoffTimeout: TimeInterval = 2
    ) {
        self.seededSystemDefaultRecorder = systemDefaultRecorder
        self.seededAppScopedRecorder = appScopedRecorder
        self.systemDefaultRecorderFactory = systemDefaultRecorderFactory ?? Self.makeSystemDefaultRecorder
        self.appScopedRecorderFactory = appScopedRecorderFactory ?? Self.makeAppScopedRecorder
        self.routeSnapshotProvider = routeSnapshotProvider
        self.lifecycleQueue = lifecycleQueue
        self.handoffTimeout = handoffTimeout
    }

    func activeRecorderKindForDebug() -> ActiveRecorderKind {
        lock.withLock { $0.active?.kind ?? Self.kind(for: $0.preferredInputDeviceIDStorage) }
    }

    func prepare() throws {
        try lifecycleQueue.sync {
            let child = try ensureCurrentChild()
            try child.recorder.prepare()
            lock.withLock { $0.lifecycleState = .prepared }
        }
    }

    func start() throws {
        try lifecycleQueue.sync {
            let child = try ensureCurrentChild()
            try child.recorder.start()
            lock.withLock { $0.lifecycleState = .running }
        }
    }

    func pause() {
        lifecycleQueue.sync {
            let result = lock.withLock { state -> (MeetingMicRecording?, MeetingMicRecording?) in
                guard state.lifecycleState == .running else { return (nil, nil) }
                state.lifecycleState = .paused
                state.generation &+= 1
                let pending = state.pending
                state.pending = nil
                return (state.active?.recorder, pending?.recorder)
            }
            result.1?.cancel()
            result.0?.pause()
        }
    }

    func resume() {
        lifecycleQueue.sync {
            let recorder = lock.withLock { state -> MeetingMicRecording? in
                guard state.lifecycleState == .paused else { return nil }
                state.lifecycleState = .running
                return state.active?.recorder
            }
            recorder?.resume()
            restartHandoffIfNeeded()
        }
    }

    func stop() -> URL? {
        lifecycleQueue.sync {
            let children = lock.withLock { state -> (Child?, Child?) in
                state.lifecycleState = .stopping
                state.generation &+= 1
                let result = (state.active, state.pending)
                state.active = nil
                state.pending = nil
                return result
            }
            children.1?.recorder.cancel()
            let url = children.0?.recorder.stop()
            children.0?.recorder.cancel()
            cancelUnusedSeedRecorders()
            lock.withLock { $0.lifecycleState = .idle }
            return url
        }
    }

    func cancel() {
        lifecycleQueue.sync {
            let children = lock.withLock { state -> (Child?, Child?) in
                state.lifecycleState = .stopping
                state.generation &+= 1
                let result = (state.active, state.pending)
                state.active = nil
                state.pending = nil
                return result
            }
            children.0?.recorder.cancel()
            children.1?.recorder.cancel()
            cancelUnusedSeedRecorders()
            lock.withLock { $0.lifecycleState = .idle }
        }
    }

    func currentPower() -> Float {
        lock.withLock { $0.active?.recorder }?.currentPower() ?? -160
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        let child = lock.withLock { $0.active }
        var snapshot = child?.recorder.diagnosticsSnapshot() ?? MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: Self.kind(for: preferredInputDeviceID).diagnosticsKind,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
        if snapshot.route == nil {
            snapshot = MeetingMicRecorderDiagnosticsSnapshot(
                recorderKind: snapshot.recorderKind,
                preferredInputDeviceID: snapshot.preferredInputDeviceID,
                route: routeSnapshotProvider()
            )
        }
        return snapshot
    }

    private func ensureCurrentChild() throws -> Child {
        let desired = preferredInputDeviceID
        if let active = lock.withLock({ $0.active }), active.deviceID == desired { return active }
        let previous = lock.withLock { state -> Child? in
            let old = state.active
            state.active = nil
            return old
        }
        previous?.recorder.cancel()
        let child = makeChild(deviceID: desired, generation: lock.withLock { $0.generation })
        lock.withLock { $0.active = child }
        return child
    }

    private func restartHandoffIfNeeded() {
        let stalePending = lock.withLock { state -> Child? in
            let pending = state.pending
            state.pending = nil
            return pending
        }
        stalePending?.recorder.cancel()
        beginHandoffIfNeeded()
    }

    private func beginHandoffIfNeeded() {
        let request = lock.withLock { state -> (AudioObjectID, UInt64)? in
            guard state.lifecycleState == .running,
                  state.pending == nil,
                  state.active?.deviceID != state.preferredInputDeviceIDStorage else { return nil }
            return (state.preferredInputDeviceIDStorage ?? kAudioObjectUnknown, state.generation)
        }
        guard let (encodedDeviceID, generation) = request else { return }
        let deviceID = encodedDeviceID == kAudioObjectUnknown ? nil : encodedDeviceID
        let candidate = makeChild(deviceID: deviceID, generation: generation)
        lock.withLock { $0.pending = candidate }
        do {
            try candidate.recorder.prepare()
            try candidate.recorder.start()
        } catch {
            failPendingHandoff(candidateID: candidate.id, generation: generation, error: error)
            return
        }
        lifecycleQueue.asyncAfter(deadline: .now() + handoffTimeout) { [weak self] in
            self?.failPendingHandoff(
                candidateID: candidate.id,
                generation: generation,
                error: NSError(domain: "MeetingMicrophoneRoute", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The selected microphone did not produce audio."
                ])
            )
        }
    }

    private func makeChild(deviceID: AudioObjectID?, generation: UInt64) -> Child {
        let kind = Self.kind(for: deviceID)
        let recorder: MeetingMicRecording
        switch kind {
        case .systemDefault:
            recorder = seededSystemDefaultRecorder ?? systemDefaultRecorderFactory()
            seededSystemDefaultRecorder = nil
        case .appScoped:
            recorder = seededAppScopedRecorder ?? appScopedRecorderFactory()
            seededAppScopedRecorder = nil
        }
        recorder.preferredInputDeviceID = deviceID
        let child = Child(id: UUID(), generation: generation, kind: kind, recorder: recorder, deviceID: deviceID)
        recorder.onRawPCMSamples = { [weak self] samples in self?.receive(samples, from: child.id) }
        recorder.onRecordingFailed = { [weak self] error in self?.receive(error, from: child.id) }
        return child
    }

    private func receive(_ samples: [Int16], from childID: UUID) {
        let role = lock.withLock { state -> (isActive: Bool, isPending: Bool, UInt64) in
            (state.active?.id == childID, state.pending?.id == childID, state.pending?.generation ?? state.generation)
        }
        if role.isActive {
            onRawPCMSamplesStorage?(samples)
        } else if role.isPending {
            lifecycleQueue.async { [weak self] in
                self?.completePendingHandoff(childID: childID, generation: role.2, firstSamples: samples)
            }
        }
    }

    private func receive(_ error: Error, from childID: UUID) {
        let role = lock.withLock {
            ($0.active?.id == childID, $0.pending?.id == childID, $0.pending?.generation ?? $0.generation)
        }
        if role.0 {
            onRecordingFailedStorage?(error)
        } else if role.1 {
            lifecycleQueue.async { [weak self] in
                self?.failPendingHandoff(candidateID: childID, generation: role.2, error: error)
            }
        }
    }

    private func completePendingHandoff(childID: UUID, generation: UInt64, firstSamples: [Int16]) {
        let old = lock.withLock { state -> Child? in
            guard state.generation == generation,
                  state.lifecycleState == .running,
                  state.pending?.id == childID,
                  let candidate = state.pending else { return nil }
            let old = state.active
            state.active = candidate
            state.pending = nil
            return old
        }
        guard let old else { return }
        onRawPCMSamplesStorage?(firstSamples)
        let oldURL = old.recorder.stop()
        old.recorder.cancel()
        if let oldURL { try? FileManager.default.removeItem(at: oldURL) }
    }

    private func failPendingHandoff(candidateID: UUID, generation: UInt64, error: Error) {
        let candidate = lock.withLock { state -> Child? in
            guard state.generation == generation, state.pending?.id == candidateID else { return nil }
            let candidate = state.pending
            state.pending = nil
            return candidate
        }
        guard let candidate else { return }
        candidate.recorder.cancel()
        fputs("[meeting-mic] microphone handoff failed; continuing current route: \(error)\n", stderr)
    }

    private static func kind(for deviceID: AudioObjectID?) -> ActiveRecorderKind {
        deviceID == nil ? .systemDefault : .appScoped
    }

    private func cancelUnusedSeedRecorders() {
        seededSystemDefaultRecorder?.cancel()
        seededAppScopedRecorder?.cancel()
        seededSystemDefaultRecorder = nil
        seededAppScopedRecorder = nil
    }

    private static func makeSystemDefaultRecorder() -> MeetingMicRecording {
        StreamingMeetingMicRecorderAdapter(
            recorder: StreamingMicRecorder(
                directoryName: "muesli-meeting-mic",
                recoversFromInputConfigurationChanges: true
            ),
            kind: .systemDefaultStreaming
        )
    }

    private static func makeAppScopedRecorder() -> MeetingMicRecording {
        StreamingMeetingMicRecorderAdapter(
            recorder: FallbackStreamingDictationRecorder(
                primary: AudioQueueInputRecorder(directoryName: "muesli-meeting-mic-audioqueue"),
                fallback: StreamingMicRecorder(
                    directoryName: "muesli-meeting-mic-app-scoped-fallback",
                    recoversFromInputConfigurationChanges: true
                )
            ),
            kind: .appScopedAudioQueue
        )
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
