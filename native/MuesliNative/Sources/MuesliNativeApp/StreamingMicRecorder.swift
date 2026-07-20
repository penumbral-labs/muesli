import AVFoundation
import AudioToolbox
import AudioGraphExceptionBridge
import CoreAudio
import Darwin
import Foundation
import os

/// Mic recorder using AVAudioEngine for real-time buffer access.
/// Used by MeetingSession for VAD-driven chunk rotation (zero-gap file switching).
protocol StreamingDictationRecording: AnyObject {
    var onAudioBuffer: (([Float]) -> Void)? { get set }
    var onRecordingFailed: ((Error) -> Void)? { get set }
    var preferredInputDeviceID: AudioObjectID? { get set }

    func prepare() throws
    func start() throws
    func stop() -> URL?
    func cancel()
    func currentPower() -> Float
}

protocol StreamingDictationLatencyReporting: AnyObject {
    var onLatencyEvent: ((String, Date) -> Void)? { get set }
}

protocol PausableStreamingDictationRecording: AnyObject {
    func pause()
    func resume()
}

struct StreamingMicCallbackDrainFence: Equatable, Sendable {
    private(set) var ownerCount = 0

    var permitsNewCapture: Bool { ownerCount == 0 }

    mutating func begin() {
        ownerCount += 1
    }

    mutating func end() {
        precondition(ownerCount > 0, "Unbalanced microphone callback drain fence")
        ownerCount -= 1
    }
}

/// Serial callback delivery scoped to one recording generation. Queue backlog
/// from a stopped run is discarded before a later run can install new owner
/// callbacks, while matching-run submissions preserve FIFO order.
final class StreamingMicCallbackDeliveryGate: @unchecked Sendable {
    private final class Work: @unchecked Sendable {
        private let operation: () -> Void

        init(_ operation: @escaping () -> Void) {
            self.operation = operation
        }

        func run() {
            operation()
        }
    }

    private let queue: DispatchQueue
    private let condition = NSCondition()
    private var activeRecordingID: UUID?
    private var pausedRecordingID: UUID?
    /// A closing ID rejects new payload admission while allowing every payload
    /// admitted before an external pause to finish as one compound delivery.
    private var closingRecordingID: UUID?
    private var resumeRequestedWhileClosingID: UUID?
    /// Includes queued and executing work. Counting at submission closes the
    /// race where a tap enqueues immediately after a queue barrier returns.
    private var outstandingCountByRecordingID: [UUID: Int] = [:]
    private let queueIdentityKey = DispatchSpecificKey<UUID>()
    private let queueIdentity = UUID()

    init(queue: DispatchQueue = DispatchQueue(label: "com.muesli.streaming-mic-recorder-callbacks")) {
        self.queue = queue
        queue.setSpecific(key: queueIdentityKey, value: queueIdentity)
    }

    func begin(_ recordingID: UUID) {
        condition.lock()
        activeRecordingID = recordingID
        pausedRecordingID = nil
        closingRecordingID = nil
        resumeRequestedWhileClosingID = nil
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func invalidate(_ recordingID: UUID?) -> UUID? {
        condition.lock()
        defer { condition.unlock() }
        guard recordingID == nil || activeRecordingID == recordingID else { return nil }
        let invalidatedRecordingID = activeRecordingID ?? recordingID
        activeRecordingID = nil
        if pausedRecordingID == invalidatedRecordingID || recordingID == nil {
            pausedRecordingID = nil
        }
        if closingRecordingID == invalidatedRecordingID || recordingID == nil {
            closingRecordingID = nil
        }
        if resumeRequestedWhileClosingID == invalidatedRecordingID || recordingID == nil {
            resumeRequestedWhileClosingID = nil
        }
        condition.broadcast()
        return invalidatedRecordingID
    }

    func accepts(_ recordingID: UUID) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return activeRecordingID == recordingID && pausedRecordingID != recordingID
    }

    /// Wait only for callbacks submitted by this recording. Invalidated queued
    /// callbacks retire without running; callbacks from a newer run are unrelated.
    func drain(recordingID: UUID?) {
        guard let recordingID else { return }
        _ = drain(recordingIDs: [recordingID], onReentrantCompletion: {})
    }

    /// Returns true when matching owner work was drained synchronously. When
    /// lifecycle teardown is invoked by an owner callback itself, waiting would
    /// deadlock; the completion is instead queued behind that callback and all
    /// older payloads so the recorder can keep its start fence closed.
    @discardableResult
    func drain(
        recordingIDs: Set<UUID>,
        onReentrantCompletion: @escaping @Sendable () -> Void
    ) -> Bool {
        guard !recordingIDs.isEmpty else { return true }
        if DispatchQueue.getSpecific(key: queueIdentityKey) == queueIdentity {
            queue.async(execute: onReentrantCompletion)
            return false
        }
        condition.lock()
        while recordingIDs.contains(where: {
            outstandingCountByRecordingID[$0, default: 0] > 0
        }) {
            condition.wait()
        }
        condition.unlock()
        return true
    }

    /// Establishes a pause boundary without invalidating the run. Admission is
    /// closed atomically before waiting, so work submitted before an external
    /// pause finishes in full and work racing after it is rejected. Reentrant
    /// pause cannot wait on itself, so it closes delivery immediately and the
    /// compound callback's cooperative checks stop its remaining payloads.
    func pause(_ recordingID: UUID) {
        let isReentrant = DispatchQueue.getSpecific(key: queueIdentityKey) == queueIdentity
        condition.lock()
        guard activeRecordingID == recordingID else {
            condition.unlock()
            return
        }
        closingRecordingID = recordingID
        // Publish admission closure before waiting for previously-committed
        // payloads. Besides making the boundary observable, this ensures any
        // lifecycle waiter cannot mistake scheduler delay for an open gate.
        condition.broadcast()
        if isReentrant {
            pausedRecordingID = recordingID
            closingRecordingID = nil
        } else {
            while activeRecordingID == recordingID,
                  outstandingCountByRecordingID[recordingID, default: 0] > 0 {
                condition.wait()
            }
            if activeRecordingID == recordingID,
               resumeRequestedWhileClosingID != recordingID {
                pausedRecordingID = recordingID
            }
            if closingRecordingID == recordingID {
                closingRecordingID = nil
            }
            if resumeRequestedWhileClosingID == recordingID {
                resumeRequestedWhileClosingID = nil
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Waits until pause has atomically closed new payload admission for this
    /// run. This observes the boundary itself, rather than relying on dispatch
    /// scheduling delays to infer that `pause` has begun.
    func waitUntilPayloadAdmissionCloses(
        _ recordingID: UUID,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while activeRecordingID == recordingID,
              pausedRecordingID != recordingID,
              closingRecordingID != recordingID {
            guard condition.wait(until: deadline) else { break }
        }
        return activeRecordingID != recordingID
            || pausedRecordingID == recordingID
            || closingRecordingID == recordingID
    }

    func resume(_ recordingID: UUID) {
        condition.lock()
        if activeRecordingID == recordingID {
            if closingRecordingID == recordingID {
                resumeRequestedWhileClosingID = recordingID
            } else if pausedRecordingID == recordingID {
                pausedRecordingID = nil
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    func enqueue(recordingID: UUID, _ operation: @escaping () -> Void) {
        enqueue(recordingID: recordingID, deliverWhilePaused: false, operation)
    }

    /// Control-plane events such as terminal capture failure must reach the
    /// owner even while audio payload delivery is paused. They remain scoped
    /// to the active recording, so stop/cancel still discard stale events.
    func enqueueControl(recordingID: UUID, _ operation: @escaping () -> Void) {
        enqueue(recordingID: recordingID, deliverWhilePaused: true, operation)
    }

    private func enqueue(
        recordingID: UUID,
        deliverWhilePaused: Bool,
        _ operation: @escaping () -> Void
    ) {
        let work = Work(operation)
        condition.lock()
        guard activeRecordingID == recordingID,
              deliverWhilePaused || (
                  pausedRecordingID != recordingID
                    && closingRecordingID != recordingID
              ) else {
            condition.unlock()
            return
        }
        outstandingCountByRecordingID[recordingID, default: 0] += 1
        condition.unlock()

        queue.async { [self] in
            condition.lock()
            let shouldRun = activeRecordingID == recordingID
                && (deliverWhilePaused || pausedRecordingID != recordingID)
            condition.unlock()
            defer {
                condition.lock()
                let remaining = outstandingCountByRecordingID[recordingID, default: 1] - 1
                if remaining == 0 {
                    outstandingCountByRecordingID[recordingID] = nil
                } else {
                    outstandingCountByRecordingID[recordingID] = remaining
                }
                condition.broadcast()
                condition.unlock()
            }
            if shouldRun {
                work.run()
            }
        }
    }
}

final class StreamingMicRecorder: StreamingDictationRecording, StreamingDictationLatencyReporting, PausableStreamingDictationRecording, StreamingMicCaptureEventReporting {
    /// Called with 4096-sample Float chunks (256ms at 16kHz) for VAD processing.
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?
    var onCaptureEvent: ((StreamingMicCaptureEvent) -> Void)?
    /// Called with 16-bit PCM mono samples for retained meeting recording.
    var onPCMSamples: (([Int16]) -> Void)?
    var preferredInputDeviceID: AudioObjectID? {
        get { routeLock.withLock { $0 } }
        set { routeLock.withLock { $0 = newValue } }
    }

    /// An AVAudioEngine that has observed an I/O configuration change is never
    /// reused. AVFAudio retains the old node formats even after stop/reset, so
    /// route recovery always swaps in a fresh graph instance.
    private var engine: AVAudioEngine
    private let engineFactory: () -> AVAudioEngine
    private let audioDeviceInspector: CoreAudioDeviceInspector
    private var engineGeneration: UInt64 = 0
    private let directoryName: String
    /// Sole owner of AVAudioEngine graph mutations. Delayed work is still
    /// generation-validated; queue ordering prevents concurrent stop/start.
    private let engineControlQueue = DispatchQueue(label: "com.muesli.streaming-mic-recorder-engine")
    private let lock = OSAllocatedUnfairLock(initialState: FileState())
    private let routeLock = OSAllocatedUnfairLock<AudioObjectID?>(initialState: nil)
    private let failureLock = OSAllocatedUnfairLock(initialState: FailureState())
    private let recoveryLock: OSAllocatedUnfairLock<StreamingMicRecoveryCoordinator>
    /// All owner callbacks share one run-scoped FIFO. Recovery events are
    /// enqueued before their proving audio buffer, and stale runs are rejected
    /// when their queued work eventually executes.
    private let callbackDelivery: StreamingMicCallbackDeliveryGate
    private var isRunning = false
    /// Set on the engine queue between graph teardown and callback quiescence.
    /// A concurrent new start fails cleanly instead of overlapping owner work
    /// from the recording that is still leaving the callback queue.
    private let callbackDrainFence = OSAllocatedUnfairLock(
        initialState: StreamingMicCallbackDrainFence()
    )
    private var tapInstalled = false
    private var graphPreparedInputDeviceID: AudioObjectID?
    private var graphPreparedRouteFingerprint: StreamingMicRouteFingerprint?
    private var isGraphPrepared = false
    private var configurationChangeObserver: (any NSObjectProtocol)?
    private var routeSettlementWindow: RouteSettlementWindow?

    private struct FailureState {
        var activeRecordingID: UUID?
        var hasReportedFailure = false
    }

    private struct RouteObservation {
        let fingerprint: StreamingMicRouteFingerprint
        let outputFormat: AVAudioFormat
    }

    private struct RouteSettlementWindow {
        let recordingID: UUID
        let recoveryGeneration: UInt64
        let hardDeadline: TimeInterval

        func matches(_ request: StreamingMicRecoveryCoordinator.RestartRequest) -> Bool {
            recordingID == request.settlementToken.recordingID
                && recoveryGeneration == request.settlementToken.recoveryGeneration
        }
    }

    private struct FileState {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten: Int = 0
        var latestPowerDB: Float = -160
        var isPaused = false
    }

    private static let sampleRate: Double = 16_000
    private static let bufferSize: AVAudioFrameCount = 4096 // 256ms at 16kHz
    private static let routeStabilityPollDelay: TimeInterval = 0.10
    private static let routeStabilityTimeout: TimeInterval = 1.25
    private static let routeStabilityHardTimeout: TimeInterval = 8.0

    init(
        directoryName: String = "muesli-meeting-mic",
        recoveryPolicy: StreamingMicRecoveryCoordinator.Policy = .production,
        callbackDelivery: StreamingMicCallbackDeliveryGate = StreamingMicCallbackDeliveryGate(),
        engineFactory: @escaping () -> AVAudioEngine = { AVAudioEngine() },
        audioDeviceInspector: CoreAudioDeviceInspector = CoreAudioDeviceInspector()
    ) {
        self.engineFactory = engineFactory
        engine = engineFactory()
        self.audioDeviceInspector = audioDeviceInspector
        self.directoryName = directoryName
        self.callbackDelivery = callbackDelivery
        recoveryLock = OSAllocatedUnfairLock(initialState: StreamingMicRecoveryCoordinator(policy: recoveryPolicy))
    }

    var captureRecoveryDiagnostics: StreamingMicRecoveryDiagnosticsSnapshot {
        recoveryLock.withLock { $0.diagnosticsSnapshot }
    }

    deinit {
        // Safety net for callers that drop the recorder without stop()/cancel().
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func prepare() throws {
        try engineControlQueue.sync {
            guard callbackDrainFence.withLock({ $0.permitsNewCapture }) else {
                throw Self.runtimeError(
                    code: 10,
                    message: "Microphone capture teardown is still completing"
                )
            }
            try prepareOnEngineQueue()
        }
    }

    private func prepareOnEngineQueue() throws {
        let requestedDeviceID = preferredInputDeviceID
        if isGraphPrepared,
           graphPreparedInputDeviceID == requestedDeviceID,
           let preparedFingerprint = graphPreparedRouteFingerprint {
            let currentFingerprint = try? currentRouteObservationOnEngineQueue().fingerprint
            if let currentFingerprint,
               currentFingerprint.validationFailure == nil,
               currentFingerprint == preparedFingerprint {
                emitLatency("app_scoped_prepare_reused")
                return
            }

            // The route moved while the graph was prewarmed. A reset is not
            // sufficient because AVAudioEngine retains the old I/O formats.
            replaceAudioEngineOnEngineQueue()
        } else if isGraphPrepared {
            replaceAudioEngineOnEngineQueue()
        }

        if isGraphPrepared {
            emitLatency("app_scoped_prepare_reused")
            return
        }

        emitLatency("app_scoped_prepare_begin")
        do {
            try AudioInputDeviceSelection.applyPreferredInputDeviceID(
                requestedDeviceID,
                to: engine,
                logPrefix: "streaming-mic"
            )
            emitLatency("app_scoped_preferred_input_applied")

            let beforePrepare = try currentRouteObservationOnEngineQueue().fingerprint
            if let failure = beforePrepare.validationFailure {
                throw Self.runtimeError(code: 1, message: failure)
            }
            if let error = MuesliAudioGraphPrepareEngine(engine) {
                throw error
            }
            let afterPrepare = try currentRouteObservationOnEngineQueue().fingerprint
            guard afterPrepare.validationFailure == nil,
                  afterPrepare == beforePrepare else {
                throw Self.runtimeError(
                    code: 11,
                    message: "The microphone route changed while its audio graph was being prepared"
                )
            }
            isGraphPrepared = true
            graphPreparedInputDeviceID = requestedDeviceID
            graphPreparedRouteFingerprint = afterPrepare
            emitLatency("app_scoped_prepare_end")
        } catch {
            // The prepare operation itself can poison AVFAudio's retained
            // formats, so even an initial-start retry receives a fresh graph.
            replaceAudioEngineOnEngineQueue()
            throw error
        }
    }

    func start() throws {
        var callbackRunToDrain: UUID?
        do {
            try engineControlQueue.sync {
                guard callbackDrainFence.withLock({ $0.permitsNewCapture }) else {
                    throw Self.runtimeError(
                        code: 10,
                        message: "Microphone capture teardown is still completing"
                    )
                }
                guard !isRunning else { return }
                guard failureLock.withLock({ $0.activeRecordingID == nil }),
                      lock.withLock({ $0.fileURL == nil }) else {
                    throw Self.runtimeError(
                        code: 7,
                        message: "The previous microphone capture must be stopped or discarded before starting again"
                    )
                }
                routeSettlementWindow = nil
                var initialGraphError: Error?
                do {
                    try prepareOnEngineQueue()
                } catch {
                    initialGraphError = error
                }

                // File creation precedes run activation. A filesystem failure must
                // not leave a phantom active recording/failure generation behind.
                let fileState = try createNewFile()
                let recordingID = UUID()
                let input: StreamingMicInputSnapshot
                if initialGraphError == nil {
                    do {
                        input = try currentInputSnapshot()
                    } catch {
                        initialGraphError = error
                        input = fallbackInputSnapshot()
                    }
                } else {
                    input = fallbackInputSnapshot()
                }
                let captureToken = recoveryLock.withLock {
                    $0.beginRecording(
                        recordingID: recordingID,
                        input: input,
                        now: ProcessInfo.processInfo.systemUptime,
                        audioClockTime: AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    )
                }
                failureLock.withLock {
                    $0.activeRecordingID = recordingID
                    $0.hasReportedFailure = false
                }
                callbackDelivery.begin(recordingID)
                lock.withLock { $0 = fileState }

                if let initialGraphError {
                    if beginInitialGraphRecoveryOnEngineQueue(
                        captureToken: captureToken,
                        previousInput: input,
                        error: initialGraphError
                    ) {
                        return
                    }
                    recoveryLock.withLock { $0.endRecording(recordingID) }
                    replaceAudioEngineOnEngineQueue()
                    clearFailureState(recordingID: recordingID)
                    _ = callbackDelivery.invalidate(recordingID)
                    callbackRunToDrain = recordingID
                    callbackDrainFence.withLock { $0.begin() }
                    removeCurrentFile()
                    throw initialGraphError
                }

                installConfigurationChangeObserverIfNeeded()
                do {
                    try startEngineWithTapOnEngineQueue(captureToken: captureToken)
                    let startedInput = try currentInputSnapshot()
                    let startedDecision = recoveryLock.withLock {
                        $0.initialGraphStarted(token: captureToken, input: startedInput)
                    }
                    guard case .awaitFirstBuffer(let timeoutToken, let timeoutDelay) = startedDecision else {
                        throw Self.runtimeError(
                            code: 8,
                            message: "Microphone capture was invalidated while its input graph was starting"
                        )
                    }
                    isRunning = true
                    scheduleFirstBufferTimeout(timeoutToken, delay: timeoutDelay)
                } catch {
                    // A route transition can overlap initial meeting startup,
                    // not only an established recording. Keep the meeting and
                    // system-audio side alive while the same asynchronous
                    // fresh-engine recovery path restores the microphone.
                    if beginInitialGraphRecoveryOnEngineQueue(
                        captureToken: captureToken,
                        previousInput: input,
                        error: error
                    ) {
                        return
                    }
                    recoveryLock.withLock { $0.endRecording(recordingID) }
                    // A graph that failed setup may retain an incompatible
                    // CoreAudio format. Discard the entire instance.
                    replaceAudioEngineOnEngineQueue()
                    clearFailureState(recordingID: recordingID)
                    _ = callbackDelivery.invalidate(recordingID)
                    callbackRunToDrain = recordingID
                    callbackDrainFence.withLock { $0.begin() }
                    removeCurrentFile()
                    throw error
                }
            }
        } catch {
            if let callbackRunToDrain {
                finishCallbackDrain(recordingIDs: [callbackRunToDrain])
            }
            throw error
        }
    }

    private func beginInitialGraphRecoveryOnEngineQueue(
        captureToken: StreamingMicRecoveryCoordinator.CaptureToken,
        previousInput: StreamingMicInputSnapshot,
        error: Error
    ) -> Bool {
        let recoveryDecision = recoveryLock.withLock {
            let startedDecision = $0.initialGraphStarted(
                token: captureToken,
                input: previousInput
            )
            guard case .awaitFirstBuffer(let timeoutToken, _) = startedDecision else {
                return StreamingMicRecoveryCoordinator.RecoveryFailureDecision.ignored
            }
            return $0.firstBufferTimedOut(
                timeoutToken,
                now: ProcessInfo.processInfo.systemUptime
            )
        }
        guard case .retry = recoveryDecision else { return false }

        replaceAudioEngineOnEngineQueue()
        isRunning = true
        emitLatency("initial_engine_start_recovery_scheduled")
        handleRecoveryFailureOnEngineQueue(recoveryDecision, error: error)
        return true
    }

    /// Installs the input tap (with conversion to 16kHz mono) and starts the engine.
    /// Called only on `engineControlQueue`; restart taps keep appending to the
    /// same file while capture generations reject in-flight callbacks from the
    /// graph they replaced.
    private func startEngineWithTapOnEngineQueue(
        captureToken: StreamingMicRecoveryCoordinator.CaptureToken,
        expectedRoute: StreamingMicRouteFingerprint? = nil
    ) throws {
        let route = try currentRouteObservationOnEngineQueue()
        if let failure = route.fingerprint.validationFailure {
            throw Self.runtimeError(code: 12, message: failure)
        }
        if let expectedRoute, route.fingerprint != expectedRoute {
            throw Self.runtimeError(
                code: 13,
                message: "The microphone route changed immediately before its tap was installed"
            )
        }
        let hwFormat = route.outputFormat

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "StreamingMicRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not create target audio format",
            ])
        }

        // Install converter if sample rates differ
        let needsConversion = hwFormat.sampleRate != Self.sampleRate || hwFormat.channelCount != 1
        let converter: AVAudioConverter?
        if needsConversion {
            guard let createdConverter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
                throw Self.runtimeError(
                    code: 14,
                    message: "Could not convert the current microphone format to 16 kHz mono"
                )
            }
            converter = createdConverter
        } else {
            converter = nil
        }

        emitLatency("app_scoped_tap_install_begin")
        let expectedTapFormat = StreamingMicAudioFormatFingerprint(hwFormat)
        let tapEngineGeneration = engineGeneration
        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, when in
            guard let self else { return }
            guard self.recoveryLock.withLock({ $0.accepts(captureToken) }) else { return }
            guard StreamingMicAudioFormatFingerprint(buffer.format) == expectedTapFormat else {
                // A route can still move after start's postflight check. Do not
                // let a differently formatted callback prove recovery.
                self.engineControlQueue.async { [weak self] in
                    self?.handleEngineConfigurationChangeOnEngineQueue(
                        observedEngineGeneration: tapEngineGeneration
                    )
                }
                return
            }

            let monoBuffer: AVAudioPCMBuffer
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                    self.reportRecordingFailure(
                        Self.runtimeError(code: 4, message: "Could not allocate converted microphone buffer"),
                        captureToken: captureToken
                    )
                    return
                }
                var error: NSError?
                var didProvideInput = false
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    guard !didProvideInput else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    didProvideInput = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
                if let error {
                    self.reportRecordingFailure(error, captureToken: captureToken)
                    return
                }
                monoBuffer = converted
            } else {
                monoBuffer = buffer
            }

            guard let floatData = monoBuffer.floatChannelData?[0] else {
                self.reportRecordingFailure(
                    Self.runtimeError(code: 5, message: "Microphone buffer did not contain float channel data"),
                    captureToken: captureToken
                )
                return
            }
            let frameCount = Int(monoBuffer.frameLength)
            guard frameCount > 0 else { return }
            let floatSamples = Array(
                UnsafeBufferPointer(start: floatData, count: frameCount)
            )

            // Write Int16 PCM to file
            let int16Samples: [Int16] = {
                var samples = [Int16](repeating: 0, count: frameCount)
                for i in 0..<frameCount {
                    let clamped = max(-1.0, min(1.0, floatData[i]))
                    samples[i] = Int16(clamped * 32767)
                }
                return samples
            }()
            let pcmData = int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }
            let powerDB: Float = {
                guard frameCount > 0 else { return -160 }
                var sumSquares: Float = 0
                for i in 0..<frameCount {
                    let sample = floatData[i]
                    sumSquares += sample * sample
                }
                let rms = sqrt(sumSquares / Float(frameCount))
                let rawDB = rms > 0.000_001 ? 20 * log10(rms) : -160
                return max(-160, min(0, rawDB))
            }()

            let audioStartTime = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                : nil
            // Commit coordinator state and the proving file write under one
            // recovery-lock epoch. A stop or a second route notification can
            // linearize before or after this buffer, never between a recovered
            // event and the audio that proved it.
            let decision = self.recoveryLock.withLock { coordinator -> StreamingMicRecoveryCoordinator.BufferDecision in
                let decision = coordinator.noteBuffer(
                    token: captureToken,
                    callbackTime: ProcessInfo.processInfo.systemUptime,
                    audioStartTime: audioStartTime,
                    sampleCount: frameCount,
                    sampleRate: Self.sampleRate
                )
                guard decision != .rejected else { return .rejected }
                let shouldEmit = self.lock.withLock { state -> Bool in
                    guard !state.isPaused else {
                        state.latestPowerDB = -160
                        return false
                    }
                    state.fileHandle?.write(pcmData)
                    state.bytesWritten += pcmData.count
                    state.latestPowerDB = powerDB
                    return true
                }
                let recoveryEvent: StreamingMicCaptureEvent?
                if case .recovered(let discontinuity) = decision {
                    recoveryEvent = .recovered(discontinuity)
                } else {
                    recoveryEvent = nil
                }
                if recoveryEvent != nil || shouldEmit {
                    let floats = shouldEmit ? floatSamples : []
                    // Bind handlers to this run as well as gating execution.
                    // Even an already-running callback can never read handlers
                    // installed later by a new recording.
                    let captureHandler = self.onCaptureEvent
                    let pcmHandler = self.onPCMSamples
                    let audioHandler = self.onAudioBuffer
                    let recordingID = captureToken.recordingID
                    let delivery = self.callbackDelivery
                    delivery.enqueue(recordingID: recordingID) {
                        if let recoveryEvent {
                            captureHandler?(recoveryEvent)
                        }
                        guard shouldEmit else { return }
                        guard delivery.accepts(recordingID) else { return }
                        pcmHandler?(int16Samples)
                        guard delivery.accepts(recordingID) else { return }
                        audioHandler?(floats)
                    }
                }
                return decision
            }
            guard decision != .rejected else { return }
            if case .recovered(let discontinuity) = decision {
                self.emitLatency("engine_config_change_first_buffer")
                fputs(
                    "[streaming-mic] microphone capture recovered generation=\(discontinuity.generation) " +
                    "attempt=\(discontinuity.restartAttemptCount) gap_samples=\(discontinuity.missingSampleCount)\n",
                    stderr
                )
            }
        }
        if let error = MuesliAudioGraphInstallInputTap(
            engine,
            0,
            Self.bufferSize,
            hwFormat,
            tapBlock
        ) {
            throw error
        }
        tapInstalled = true
        emitLatency("app_scoped_tap_install_end")

        // Prepare after the tap has configured the candidate graph. This call
        // is deliberately inside the Objective-C exception boundary too.
        if let error = MuesliAudioGraphPrepareEngine(engine) {
            throw error
        }
        emitLatency("app_scoped_engine_start_begin")
        if let error = MuesliAudioGraphStartEngine(engine) {
            throw error
        }
        emitLatency("app_scoped_engine_start_end")
    }

    // MARK: - Input Configuration Changes

    /// AVAudioEngine stops delivering input buffers when its I/O configuration
    /// changes mid-recording (e.g. AirPods connect and become the default input).
    /// Without handling this, the microphone side of a meeting recording dies
    /// silently while system audio keeps flowing. Rebuild the tap and restart
    /// the engine so capture continues into the same file.
    private func installConfigurationChangeObserverIfNeeded() {
        guard configurationChangeObserver == nil else { return }
        let observedEngineGeneration = engineGeneration
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.engineControlQueue.async { [weak self] in
                self?.handleEngineConfigurationChangeOnEngineQueue(
                    observedEngineGeneration: observedEngineGeneration
                )
            }
        }
    }

    private func removeConfigurationChangeObserverIfNeeded() {
        guard let observer = configurationChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        configurationChangeObserver = nil
    }

    private func handleEngineConfigurationChangeOnEngineQueue(
        observedEngineGeneration: UInt64
    ) {
        guard isRunning, observedEngineGeneration == engineGeneration else { return }
        let decision = recoveryLock.withLock {
            $0.noteConfigurationChange(now: ProcessInfo.processInfo.systemUptime)
        }
        switch decision {
        case .ignored:
            return
        case .coalesced:
            // Yield the device immediately. The current rebuild will observe
            // the newer coordinator generation and schedule a fresh graph.
            teardownCurrentEngineGraphOnEngineQueue()
        case .schedule(let token, let delay):
            // AVAudioEngine has already stopped its callbacks at this point.
            // Explicitly release Muesli's tap while the meeting client settles.
            teardownCurrentEngineGraphOnEngineQueue()
            emitLatency("engine_config_change_settling")
            scheduleSettlement(token, delay: delay)
        case .failed(let failure):
            replaceAudioEngineOnEngineQueue()
            handleRecoveryFailureOnEngineQueue(
                .failed(failure),
                error: Self.runtimeError(code: 9, message: failure.message)
            )
        }
    }

    private func scheduleSettlement(
        _ token: StreamingMicRecoveryCoordinator.SettlementToken,
        delay: TimeInterval
    ) {
        engineControlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performSettlementOnEngineQueue(token)
        }
    }

    private func performSettlementOnEngineQueue(
        _ token: StreamingMicRecoveryCoordinator.SettlementToken
    ) {
        guard isRunning else { return }
        let decision = recoveryLock.withLock { $0.settlementElapsed(token) }
        guard case .rebuild(let request) = decision else { return }

        emitLatency("engine_config_change_restart_begin")
        beginStableRouteRecoveryOnEngineQueue(request)
    }

    private func beginStableRouteRecoveryOnEngineQueue(
        _ request: StreamingMicRecoveryCoordinator.RestartRequest
    ) {
        // Never rebuild on the AVAudioEngine that observed the route change.
        // AVFAudio retains its previous node formats across stop/reset.
        replaceAudioEngineOnEngineQueue()

        let now = ProcessInfo.processInfo.systemUptime
        let window: RouteSettlementWindow
        if let existing = routeSettlementWindow, existing.matches(request) {
            window = existing
        } else {
            window = RouteSettlementWindow(
                recordingID: request.settlementToken.recordingID,
                recoveryGeneration: request.settlementToken.recoveryGeneration,
                hardDeadline: now + Self.routeStabilityHardTimeout
            )
            routeSettlementWindow = window
        }

        do {
            try AudioInputDeviceSelection.applyPreferredInputDeviceID(
                preferredInputDeviceID,
                to: engine,
                logPrefix: "streaming-mic-recovery"
            )
            pollStableRouteOnEngineQueue(
                request: request,
                engineGeneration: engineGeneration,
                gate: StreamingMicRouteStabilityGate(),
                deadline: min(now + Self.routeStabilityTimeout, window.hardDeadline),
                hardDeadline: window.hardDeadline,
                lastWaitReason: "Waiting for the microphone route"
            )
        } catch {
            deferUnstableRouteOnEngineQueue(
                request: request,
                hardDeadline: window.hardDeadline,
                error: error
            )
        }
    }

    private func pollStableRouteOnEngineQueue(
        request: StreamingMicRecoveryCoordinator.RestartRequest,
        engineGeneration expectedEngineGeneration: UInt64,
        gate incomingGate: StreamingMicRouteStabilityGate,
        deadline: TimeInterval,
        hardDeadline: TimeInterval,
        lastWaitReason: String
    ) {
        guard isRunning, engineGeneration == expectedEngineGeneration else { return }

        var gate = incomingGate
        let observation: RouteObservation
        do {
            observation = try currentRouteObservationOnEngineQueue()
        } catch {
            deferUnstableRouteOnEngineQueue(
                request: request,
                hardDeadline: hardDeadline,
                error: error
            )
            return
        }
        switch gate.observe(observation.fingerprint) {
        case .ready(let stableRoute):
            finishStableRouteRecoveryOnEngineQueue(
                request: request,
                expectedEngineGeneration: expectedEngineGeneration,
                stableRoute: stableRoute
            )

        case .waiting(let reason):
            let now = ProcessInfo.processInfo.systemUptime
            guard now < deadline else {
                deferUnstableRouteOnEngineQueue(
                    request: request,
                    hardDeadline: hardDeadline,
                    error: Self.runtimeError(
                        code: 15,
                        message: "Microphone route did not stabilize: \(reason.isEmpty ? lastWaitReason : reason)"
                    )
                )
                return
            }
            let nextGate = gate
            engineControlQueue.asyncAfter(deadline: .now() + Self.routeStabilityPollDelay) { [weak self] in
                self?.pollStableRouteOnEngineQueue(
                    request: request,
                    engineGeneration: expectedEngineGeneration,
                    gate: nextGate,
                    deadline: deadline,
                    hardDeadline: hardDeadline,
                    lastWaitReason: reason
                )
            }
        }
    }

    private func deferUnstableRouteOnEngineQueue(
        request: StreamingMicRecoveryCoordinator.RestartRequest,
        hardDeadline: TimeInterval,
        error: Error
    ) {
        guard ProcessInfo.processInfo.systemUptime < hardDeadline else {
            routeSettlementWindow = nil
            failRecoveryGraphOnEngineQueue(request: request, error: error)
            return
        }

        // Reading input-node state can itself raise while CoreAudio changes
        // routes. Since no graph mutation has occurred, discard the candidate
        // and defer without spending the graph-start retry budget.
        replaceAudioEngineOnEngineQueue()
        let settlementDecision = recoveryLock.withLock {
            $0.routeStillSettling(for: request)
        }
        handleRecoveryFailureOnEngineQueue(settlementDecision, error: error)
    }

    private func finishStableRouteRecoveryOnEngineQueue(
        request: StreamingMicRecoveryCoordinator.RestartRequest,
        expectedEngineGeneration: UInt64,
        stableRoute: StreamingMicRouteFingerprint
    ) {
        guard isRunning, engineGeneration == expectedEngineGeneration else { return }

        let preparedDecision = recoveryLock.withLock {
            $0.graphPrepared(for: request, input: inputSnapshot(from: stableRoute))
        }
        switch preparedDecision {
        case .ignored:
            routeSettlementWindow = nil
            replaceAudioEngineOnEngineQueue()
            return
        case .scheduleTrailing(let trailingToken, let delay):
            replaceAudioEngineOnEngineQueue()
            scheduleSettlement(trailingToken, delay: delay)
            return
        case .startGraph:
            routeSettlementWindow = nil
            break
        }

        do {
            // Observe changes on the candidate before graph mutation. A
            // notification racing with setup is serialized behind this work;
            // the explicit post-start validation closes the remaining window.
            installConfigurationChangeObserverIfNeeded()
            try startEngineWithTapOnEngineQueue(
                captureToken: request.captureToken,
                expectedRoute: stableRoute
            )

            let postStartRoute = try currentRouteObservationOnEngineQueue().fingerprint
            guard postStartRoute.validationFailure == nil,
                  postStartRoute == stableRoute else {
                throw Self.runtimeError(
                    code: 16,
                    message: "The microphone route changed while its replacement graph was starting"
                )
            }

            isGraphPrepared = true
            graphPreparedInputDeviceID = preferredInputDeviceID
            graphPreparedRouteFingerprint = postStartRoute
            emitLatency("engine_config_change_engine_started")
            let startedDecision = recoveryLock.withLock {
                $0.recoveryGraphStarted(
                    for: request,
                    input: inputSnapshot(from: postStartRoute)
                )
            }
            switch startedDecision {
            case .ignored:
                replaceAudioEngineOnEngineQueue()
            case .scheduleTrailing(let trailingToken, let delay):
                replaceAudioEngineOnEngineQueue()
                scheduleSettlement(trailingToken, delay: delay)
            case .awaitFirstBuffer(let timeoutToken, let delay):
                scheduleFirstBufferTimeout(timeoutToken, delay: delay)
            }
        } catch {
            failRecoveryGraphOnEngineQueue(request: request, error: error)
        }
    }

    private func failRecoveryGraphOnEngineQueue(
        request: StreamingMicRecoveryCoordinator.RestartRequest,
        error: Error
    ) {
        // An exception or format mismatch poisons this graph identity. Retire
        // it before asking the coordinator whether a bounded retry is allowed.
        replaceAudioEngineOnEngineQueue()
        handleRecoveryFailureOnEngineQueue(
            recoveryLock.withLock {
                $0.graphStartFailed(request: request, message: error.localizedDescription)
            },
            error: error
        )
    }

    private func scheduleFirstBufferTimeout(
        _ token: StreamingMicRecoveryCoordinator.FirstBufferTimeoutToken,
        delay: TimeInterval
    ) {
        engineControlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let decision = self.recoveryLock.withLock {
                $0.firstBufferTimedOut(token, now: ProcessInfo.processInfo.systemUptime)
            }
            guard decision != .ignored else { return }
            self.replaceAudioEngineOnEngineQueue()
            self.handleRecoveryFailureOnEngineQueue(
                decision,
                error: Self.runtimeError(
                    code: 6,
                    message: "Microphone capture started but did not deliver audio buffers"
                )
            )
        }
    }

    private func handleRecoveryFailureOnEngineQueue(
        _ decision: StreamingMicRecoveryCoordinator.RecoveryFailureDecision,
        error: Error
    ) {
        switch decision {
        case .ignored:
            return
        case .retry(let token, let delay):
            emitLatency("engine_config_change_retry_scheduled")
            scheduleSettlement(token, delay: delay)
        case .failed(let failure):
            isRunning = false
            routeSettlementWindow = nil
            replaceAudioEngineOnEngineQueue()
            emitLatency("engine_config_change_failed")
            guard let recordingID = failureLock.withLock({ $0.activeRecordingID }),
                  claimFailureDelivery(recordingID: recordingID) else { return }
            let captureHandler = onCaptureEvent
            let failureHandler = onRecordingFailed
            callbackDelivery.enqueueControl(recordingID: recordingID) {
                if let captureHandler {
                    captureHandler(.failed(failure))
                } else {
                    failureHandler?(error)
                }
            }
        }
    }

    /// Rotate to a new file. Returns the completed WAV URL. No audio gap.
    func rotateFile() -> URL? {
        guard recoveryLock.withLock({ $0.hasActiveRecording }) else { return nil }

        let newState: FileState
        do {
            newState = try createNewFile()
        } catch {
            fputs("[streaming-mic] failed to create new file during rotation: \(error)\n", stderr)
            return nil
        }

        let completed = lock.withLock { state -> FileState in
            let old = state
            state = newState
            return old
        }

        return finalizeFile(completed)
    }

    /// Stop recording. Returns the final WAV URL.
    func stop() -> URL? {
        callbackDrainFence.withLock { $0.begin() }
        // Invalidate audio callbacks and every delayed recovery action before
        // waiting behind a potentially slow CoreAudio graph mutation.
        let earlyInvalidatedRun = failureLock.withLock { $0.activeRecordingID }
            .flatMap { invalidateCapture(recordingID: $0) }

        let teardown = engineControlQueue.sync {
            () -> (result: URL?, invalidatedRun: UUID?) in
            let recordingID = failureLock.withLock { $0.activeRecordingID }
            let hasFile = lock.withLock { $0.fileURL != nil }
            guard recordingID != nil || hasFile || isRunning else { return (nil, nil) }
            let invalidatedRun = invalidateCapture(recordingID: recordingID)
            isRunning = false
            routeSettlementWindow = nil
            replaceAudioEngineOnEngineQueue()

            let finalState = takeCurrentFile()
            return (finalizeFile(finalState), invalidatedRun)
        }
        let callbackRunsToDrain = Set(
            [earlyInvalidatedRun, teardown.invalidatedRun].compactMap { $0 }
        )
        finishCallbackDrain(recordingIDs: callbackRunsToDrain)
        return teardown.result
    }

    func pause() {
        guard let recordingID = failureLock.withLock({ $0.activeRecordingID }) else { return }
        let didPause = recoveryLock.withLock { coordinator -> Bool in
            guard coordinator.pauseRecording(recordingID) else { return false }
            lock.withLock { state in
                state.isPaused = true
                state.latestPowerDB = -160
            }
            return true
        }
        guard didPause else { return }
        callbackDelivery.pause(recordingID)
    }

    func resume() {
        guard let recordingID = failureLock.withLock({ $0.activeRecordingID }) else { return }
        callbackDelivery.resume(recordingID)
        let didResume = recoveryLock.withLock { coordinator -> Bool in
            guard coordinator.resumeRecording(
                recordingID,
                now: ProcessInfo.processInfo.systemUptime,
                audioClockTime: AVAudioTime.seconds(forHostTime: mach_absolute_time())
            ) else { return false }
            lock.withLock { state in
                state.isPaused = false
            }
            return true
        }
        if !didResume {
            callbackDelivery.pause(recordingID)
        }
    }

    func cancel() {
        callbackDrainFence.withLock { $0.begin() }
        let earlyInvalidatedRun = failureLock.withLock { $0.activeRecordingID }
            .flatMap { invalidateCapture(recordingID: $0) }

        // This wait is intentionally outside UI-owned lifecycle code. The
        // meeting layer runs discard teardown off MainActor and retains its
        // capture lease until this serialized graph cleanup completes.
        let invalidatedRun = engineControlQueue.sync { () -> UUID? in
            let invalidatedRun = invalidateCapture(
                recordingID: failureLock.withLock { $0.activeRecordingID }
            )
            isRunning = false
            routeSettlementWindow = nil
            replaceAudioEngineOnEngineQueue()
            removeCurrentFile()
            return invalidatedRun
        }
        let callbackRunsToDrain = Set(
            [earlyInvalidatedRun, invalidatedRun].compactMap { $0 }
        )
        finishCallbackDrain(recordingIDs: callbackRunsToDrain)
    }

    /// Approximate current power level (dB) from recent samples.
    func currentPower() -> Float {
        lock.withLock { $0.latestPowerDB }
    }

    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        tapInstalled = false
        if let error = MuesliAudioGraphRemoveInputTap(engine, 0) {
            fputs("[streaming-mic] safe tap removal failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func teardownCurrentEngineGraphOnEngineQueue() {
        removeTapIfNeeded()
        if let error = MuesliAudioGraphStopEngine(engine) {
            fputs("[streaming-mic] safe engine stop failed: \(error.localizedDescription)\n", stderr)
        }
        isGraphPrepared = false
        graphPreparedInputDeviceID = nil
        graphPreparedRouteFingerprint = nil
    }

    private func replaceAudioEngineOnEngineQueue() {
        removeConfigurationChangeObserverIfNeeded()
        teardownCurrentEngineGraphOnEngineQueue()
        engine = engineFactory()
        engineGeneration &+= 1
    }

    private func clearFailureState(recordingID: UUID?) {
        failureLock.withLock {
            guard recordingID == nil || $0.activeRecordingID == recordingID else { return }
            $0.activeRecordingID = nil
            $0.hasReportedFailure = true
        }
    }

    private func finishCallbackDrain(recordingIDs: Set<UUID>) {
        let drainedSynchronously = callbackDelivery.drain(
            recordingIDs: recordingIDs,
            onReentrantCompletion: { [self] in
                callbackDrainFence.withLock { $0.end() }
            }
        )
        if drainedSynchronously {
            callbackDrainFence.withLock { $0.end() }
        }
    }

    @discardableResult
    private func invalidateCapture(recordingID: UUID?) -> UUID? {
        recoveryLock.withLock { $0.endRecording(recordingID) }
        let invalidatedRecordingID = callbackDelivery.invalidate(recordingID)
        clearFailureState(recordingID: recordingID)
        return invalidatedRecordingID
    }

    private func emitLatency(_ event: String, at date: Date = Date()) {
        onLatencyEvent?(event, date)
    }

    private func reportRecordingFailure(
        _ error: Error,
        captureToken: StreamingMicRecoveryCoordinator.CaptureToken
    ) {
        // A tap can already be inside its callback when a replacement graph
        // invalidates it. Claim failure while the exact tap generation is
        // still accepted, so a late error from that old callback cannot poison
        // the healthy replacement capture.
        let shouldReport = recoveryLock.withLock { coordinator in
            guard coordinator.accepts(captureToken) else { return false }
            return claimFailureDelivery(recordingID: captureToken.recordingID)
        }
        guard shouldReport else { return }
        let recordingID = captureToken.recordingID
        let failureHandler = onRecordingFailed
        callbackDelivery.enqueueControl(recordingID: recordingID) { [weak self] in
            guard let self else { return }
            let remainsCurrent = self.failureLock.withLock {
                $0.activeRecordingID == recordingID && $0.hasReportedFailure
            }
            guard remainsCurrent else { return }
            failureHandler?(error)
        }
    }

    private func claimFailureDelivery(recordingID: UUID) -> Bool {
        failureLock.withLock { state -> Bool in
            guard state.activeRecordingID == recordingID,
                  !state.hasReportedFailure else { return false }
            state.hasReportedFailure = true
            return true
        }
    }

    private func currentInputSnapshot() throws -> StreamingMicInputSnapshot {
        inputSnapshot(from: try currentRouteObservationOnEngineQueue().fingerprint)
    }

    private func inputSnapshot(
        from fingerprint: StreamingMicRouteFingerprint
    ) -> StreamingMicInputSnapshot {
        StreamingMicInputSnapshot(
            requestedDeviceID: fingerprint.requestedDeviceID,
            actualDeviceID: fingerprint.actualDeviceID,
            sampleRate: fingerprint.outputFormat.sampleRate,
            channelCount: fingerprint.outputFormat.channelsPerFrame
        )
    }

    private func fallbackInputSnapshot() -> StreamingMicInputSnapshot {
        let defaultDeviceID = audioDeviceInspector.defaultInputDeviceID()
        return StreamingMicInputSnapshot(
            requestedDeviceID: preferredInputDeviceID,
            actualDeviceID: defaultDeviceID,
            sampleRate: defaultDeviceID.flatMap {
                audioDeviceInspector.nominalSampleRate(for: $0)
            } ?? 0,
            channelCount: 0
        )
    }

    private func currentRouteObservationOnEngineQueue() throws -> RouteObservation {
        let inputState = MuesliAudioGraphReadInputState(engine)
        if let error = inputState.error {
            throw error
        }
        guard let outputFormat = inputState.outputFormat,
              inputState.inputFormat != nil else {
            throw Self.runtimeError(code: 17, message: "The microphone input format is unavailable")
        }
        let actualDeviceID = inputState.hasCurrentDevice
            ? inputState.currentDeviceID
            : nil
        let actualDeviceIsAvailable = actualDeviceID.map {
            audioDeviceInspector.isDeviceAvailable($0)
        } ?? false
        let nominalSampleRate = actualDeviceID.flatMap {
            audioDeviceInspector.nominalSampleRate(for: $0)
        }
        return RouteObservation(
            fingerprint: StreamingMicRouteFingerprint(
                requestedDeviceID: preferredInputDeviceID,
                defaultInputDeviceID: audioDeviceInspector.defaultInputDeviceID(),
                actualDeviceID: actualDeviceID,
                actualDeviceIsAvailable: actualDeviceIsAvailable,
                actualDeviceIsSystemDefaultAggregate: actualDeviceID.map {
                    audioDeviceInspector.isSystemDefaultAggregateDevice($0)
                } ?? false,
                actualNominalSampleRate: nominalSampleRate,
                inputFormat: StreamingMicAudioFormatFingerprint(inputState.inputDescription),
                outputFormat: StreamingMicAudioFormatFingerprint(inputState.outputDescription)
            ),
            outputFormat: outputFormat
        )
    }

    private func takeCurrentFile() -> FileState {
        lock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
    }

    private func removeCurrentFile() {
        let state = takeCurrentFile()
        state.fileHandle?.closeFile()
        if let url = state.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func runtimeError(code: Int, message: String) -> NSError {
        NSError(domain: "StreamingMicRecorder", code: code, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }

    // MARK: - File Management

    private func createNewFile() throws -> FileState {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw NSError(domain: "StreamingMicRecorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not open file for writing",
            ])
        }
        // Write placeholder WAV header (will be finalized on close)
        handle.write(WavWriter.header(dataSize: 0))
        return FileState(fileHandle: handle, fileURL: url, bytesWritten: 0)
    }

    private func finalizeFile(_ state: FileState) -> URL? {
        guard let handle = state.fileHandle, let url = state.fileURL else { return nil }

        // Rewrite WAV header with correct data size
        handle.seek(toFileOffset: 0)
        handle.write(WavWriter.header(dataSize: UInt32(state.bytesWritten)))
        handle.closeFile()

        if state.bytesWritten == 0 {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

}
