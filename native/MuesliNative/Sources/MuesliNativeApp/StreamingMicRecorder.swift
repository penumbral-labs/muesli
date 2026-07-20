import AVFoundation
import AudioToolbox
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

    private let engine = AVAudioEngine()
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
    private var isGraphPrepared = false
    private var configurationChangeObserver: (any NSObjectProtocol)?

    private struct FailureState {
        var activeRecordingID: UUID?
        var hasReportedFailure = false
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

    init(
        directoryName: String = "muesli-meeting-mic",
        recoveryPolicy: StreamingMicRecoveryCoordinator.Policy = .production,
        callbackDelivery: StreamingMicCallbackDeliveryGate = StreamingMicCallbackDeliveryGate()
    ) {
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
           graphPreparedInputDeviceID == requestedDeviceID {
            emitLatency("app_scoped_prepare_reused")
            return
        }

        emitLatency("app_scoped_prepare_begin")
        AudioInputDeviceSelection.applyPreferredInputDeviceID(
            requestedDeviceID,
            to: engine,
            logPrefix: "streaming-mic"
        )
        emitLatency("app_scoped_preferred_input_applied")

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            isGraphPrepared = false
            graphPreparedInputDeviceID = nil
            throw NSError(domain: "StreamingMicRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input available",
            ])
        }
        engine.prepare()
        isGraphPrepared = true
        graphPreparedInputDeviceID = requestedDeviceID
        emitLatency("app_scoped_prepare_end")
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
                try prepareOnEngineQueue()

                // File creation precedes run activation. A filesystem failure must
                // not leave a phantom active recording/failure generation behind.
                let fileState = try createNewFile()
                let recordingID = UUID()
                let input = currentInputSnapshot()
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

                installConfigurationChangeObserverIfNeeded()
                do {
                    try startEngineWithTapOnEngineQueue(captureToken: captureToken)
                    let startedDecision = recoveryLock.withLock {
                        $0.initialGraphStarted(token: captureToken, input: currentInputSnapshot())
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
                    recoveryLock.withLock { $0.endRecording(recordingID) }
                    removeTapIfNeeded()
                    engine.stop()
                    removeConfigurationChangeObserverIfNeeded()
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

    /// Installs the input tap (with conversion to 16kHz mono) and starts the engine.
    /// Called only on `engineControlQueue`; restart taps keep appending to the
    /// same file while capture generations reject in-flight callbacks from the
    /// graph they replaced.
    private func startEngineWithTapOnEngineQueue(
        captureToken: StreamingMicRecoveryCoordinator.CaptureToken
    ) throws {
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

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
        let converter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: hwFormat, to: targetFormat)
            : nil

        emitLatency("app_scoped_tap_install_begin")
        inputNode.installTap(onBus: 0, bufferSize: Self.bufferSize, format: nil) { [weak self] buffer, when in
            guard let self else { return }
            guard self.recoveryLock.withLock({ $0.accepts(captureToken) }) else { return }

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
                    let floats = shouldEmit
                        ? Array(UnsafeBufferPointer(start: floatData, count: frameCount))
                        : []
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
        tapInstalled = true
        emitLatency("app_scoped_tap_install_end")

        emitLatency("app_scoped_engine_start_begin")
        try engine.start()
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
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.engineControlQueue.async { [weak self] in
                self?.handleEngineConfigurationChangeOnEngineQueue()
            }
        }
    }

    private func removeConfigurationChangeObserverIfNeeded() {
        guard let observer = configurationChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        configurationChangeObserver = nil
    }

    private func handleEngineConfigurationChangeOnEngineQueue() {
        guard isRunning else { return }
        let decision = recoveryLock.withLock {
            $0.noteConfigurationChange(now: ProcessInfo.processInfo.systemUptime)
        }
        switch decision {
        case .ignored, .coalesced:
            return
        case .schedule(let token, let delay):
            emitLatency("engine_config_change_settling")
            scheduleSettlement(token, delay: delay)
        case .failed(let failure):
            removeTapIfNeeded()
            engine.stop()
            isGraphPrepared = false
            graphPreparedInputDeviceID = nil
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
        removeTapIfNeeded()
        engine.stop()
        isGraphPrepared = false
        graphPreparedInputDeviceID = nil

        do {
            try prepareOnEngineQueue()
            let input = currentInputSnapshot()
            let preparedDecision = recoveryLock.withLock {
                $0.graphPrepared(for: request, input: input)
            }
            switch preparedDecision {
            case .ignored:
                return
            case .scheduleTrailing(let trailingToken, let delay):
                scheduleSettlement(trailingToken, delay: delay)
                return
            case .startGraph:
                try startEngineWithTapOnEngineQueue(captureToken: request.captureToken)
                emitLatency("engine_config_change_engine_started")
                let startedInput = currentInputSnapshot()
                let startedDecision = recoveryLock.withLock {
                    $0.recoveryGraphStarted(for: request, input: startedInput)
                }
                switch startedDecision {
                case .ignored:
                    return
                case .scheduleTrailing(let trailingToken, let delay):
                    scheduleSettlement(trailingToken, delay: delay)
                case .awaitFirstBuffer(let timeoutToken, let delay):
                    scheduleFirstBufferTimeout(timeoutToken, delay: delay)
                }
            }
        } catch {
            removeTapIfNeeded()
            engine.stop()
            isGraphPrepared = false
            graphPreparedInputDeviceID = nil
            handleRecoveryFailureOnEngineQueue(
                recoveryLock.withLock {
                    $0.graphStartFailed(request: request, message: error.localizedDescription)
                },
                error: error
            )
        }
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
            self.removeTapIfNeeded()
            self.engine.stop()
            self.isGraphPrepared = false
            self.graphPreparedInputDeviceID = nil
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
            removeConfigurationChangeObserverIfNeeded()
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
            removeConfigurationChangeObserverIfNeeded()
            removeTapIfNeeded()
            engine.stop()

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
            removeConfigurationChangeObserverIfNeeded()
            removeTapIfNeeded()
            engine.stop()
            isGraphPrepared = false
            graphPreparedInputDeviceID = nil
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
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
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

    private func currentInputSnapshot() -> StreamingMicInputSnapshot {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return StreamingMicInputSnapshot(
            requestedDeviceID: preferredInputDeviceID,
            actualDeviceID: currentInputDeviceID(),
            sampleRate: format.sampleRate,
            channelCount: UInt32(format.channelCount)
        )
    }

    private func currentInputDeviceID() -> AudioObjectID? {
        guard let audioUnit = engine.inputNode.audioUnit else { return preferredInputDeviceID }
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &dataSize
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return preferredInputDeviceID
        }
        return deviceID
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
