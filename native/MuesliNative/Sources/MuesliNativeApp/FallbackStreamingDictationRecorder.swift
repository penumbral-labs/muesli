import CoreAudio
import Foundation

final class FallbackStreamingDictationRecorder: StreamingDictationRecording, StreamingDictationLatencyReporting, PausableStreamingDictationRecording, StreamingMicCaptureEventReporting {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?
    var onCaptureEvent: ((StreamingMicCaptureEvent) -> Void)?
    var captureRecoveryDiagnostics: StreamingMicRecoveryDiagnosticsSnapshot {
        lock.lock()
        let recorder = activeRecorderLocked()
        lock.unlock()
        return (recorder as? StreamingMicCaptureEventReporting)?.captureRecoveryDiagnostics ?? .empty
    }
    var preferredInputDeviceID: AudioObjectID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return preferredInputDeviceIDStorage
        }
        set {
            lock.lock()
            preferredInputDeviceIDStorage = newValue
            lock.unlock()
            // Child recorders own their own lifecycle synchronization. Never
            // enter them while holding the wrapper lock: a child can deliver a
            // synchronous callback which needs this lock to determine whether
            // it is still the selected recorder.
            primary.preferredInputDeviceID = newValue
            fallback.preferredInputDeviceID = newValue
        }
    }

    private enum ActiveRecorder {
        case primary
        case fallback
    }

    private enum LifecyclePhase: Equatable {
        case idle
        case preparing
        case starting
        case stopping
        case cancelling
    }

    private struct OperationContext {
        let token: UInt64
        let activeRecorder: ActiveRecorder
        let preferredInputDeviceID: AudioObjectID?
    }

    private let primary: StreamingDictationRecording
    private let fallback: StreamingDictationRecording
    private let lock = NSRecursiveLock()
    private var activeRecorder: ActiveRecorder = .primary
    private var preferredInputDeviceIDStorage: AudioObjectID?
    private var lifecyclePhase: LifecyclePhase = .idle
    private var nextOperationToken: UInt64 = 0
    private var activeOperationToken: UInt64?
    /// A cancellation which interrupts prepare/start has two independent
    /// owners: the operation unwinding from the child call and the teardown
    /// caller invoking child cancellation. The wrapper remains closed until
    /// both have completed, without either side waiting while holding `lock`.
    private var interruptedOperationToken: UInt64?
    private var interruptedOperationFinished = false
    private var interruptedTeardownFinished = false
    private var cancelRequestedDuringStop = false

    init(
        primary: StreamingDictationRecording,
        fallback: StreamingDictationRecording
    ) {
        self.primary = primary
        self.fallback = fallback
        wireCallbacks()
    }

    func prepare() throws {
        let operation = try beginOperation(.preparing)
        primary.preferredInputDeviceID = operation.preferredInputDeviceID

        let primaryError: Error?
        do {
            try primary.prepare()
            primaryError = nil
        } catch {
            primaryError = error
        }

        guard operationIsCurrent(operation.token, phase: .preparing) else {
            try finishInterruptedOperation(operation.token)
        }

        if primaryError == nil {
            guard completeOperation(
                operation.token,
                phase: .preparing,
                selecting: .primary
            ) else {
                try finishInterruptedOperation(operation.token)
            }
            emitRecorderSelection(
                slot: .primary,
                recorder: primary,
                preferredInputDeviceID: operation.preferredInputDeviceID
            )
            return
        }

        emitLatency("streaming_recorder_primary_prepare_failed")
        guard operationIsCurrent(operation.token, phase: .preparing) else {
            try finishInterruptedOperation(operation.token)
        }
        primary.cancel()
        wireCallbacks()
        guard operationIsCurrent(operation.token, phase: .preparing) else {
            try finishInterruptedOperation(operation.token)
        }

        fallback.preferredInputDeviceID = operation.preferredInputDeviceID
        emitLatency("streaming_recorder_fallback_prepare_begin")
        guard operationIsCurrent(operation.token, phase: .preparing) else {
            try finishInterruptedOperation(operation.token)
        }
        let fallbackError: Error?
        do {
            try fallback.prepare()
            fallbackError = nil
        } catch {
            fallbackError = error
        }

        guard operationIsCurrent(operation.token, phase: .preparing) else {
            try finishInterruptedOperation(operation.token)
        }

        if let fallbackError {
            fallback.cancel()
            wireCallbacks()
            guard operationIsCurrent(operation.token, phase: .preparing) else {
                try finishInterruptedOperation(operation.token)
            }
            finishFailedOperation(operation.token, phase: .preparing)
            throw fallbackError
        }

        guard completeOperation(
            operation.token,
            phase: .preparing,
            selecting: .fallback
        ) else {
            try finishInterruptedOperation(operation.token)
        }
        emitRecorderSelection(
            slot: .fallback,
            recorder: fallback,
            preferredInputDeviceID: operation.preferredInputDeviceID
        )
        emitLatency("streaming_recorder_fallback_prepare_end")
    }

    func start() throws {
        let operation = try beginOperation(.starting)

        switch operation.activeRecorder {
        case .primary:
            let primaryError: Error?
            do {
                try primary.start()
                primaryError = nil
            } catch {
                primaryError = error
            }

            guard operationIsCurrent(operation.token, phase: .starting) else {
                try finishInterruptedOperation(operation.token)
            }

            if primaryError == nil {
                guard completeOperation(operation.token, phase: .starting) else {
                    try finishInterruptedOperation(operation.token)
                }
                return
            }

            emitLatency("streaming_recorder_primary_start_failed")
            guard operationIsCurrent(operation.token, phase: .starting) else {
                try finishInterruptedOperation(operation.token)
            }
            primary.cancel()
            wireCallbacks()
            guard operationIsCurrent(operation.token, phase: .starting) else {
                try finishInterruptedOperation(operation.token)
            }

            fallback.preferredInputDeviceID = operation.preferredInputDeviceID
            emitLatency("streaming_recorder_fallback_prepare_begin")
            guard operationIsCurrent(operation.token, phase: .starting) else {
                try finishInterruptedOperation(operation.token)
            }
            let fallbackPrepareError: Error?
            do {
                try fallback.prepare()
                fallbackPrepareError = nil
            } catch {
                fallbackPrepareError = error
            }

            guard operationIsCurrent(operation.token, phase: .starting) else {
                try finishInterruptedOperation(operation.token)
            }
            if let fallbackPrepareError {
                fallback.cancel()
                wireCallbacks()
                guard operationIsCurrent(operation.token, phase: .starting) else {
                    try finishInterruptedOperation(operation.token)
                }
                finishFailedOperation(operation.token, phase: .starting)
                throw fallbackPrepareError
            }

            guard selectFallbackDuringStart(operation.token) else {
                try finishInterruptedOperation(operation.token)
            }
            emitRecorderSelection(
                slot: .fallback,
                recorder: fallback,
                preferredInputDeviceID: operation.preferredInputDeviceID
            )
            emitLatency("streaming_recorder_fallback_prepare_end")
            guard operationIsCurrent(operation.token, phase: .starting) else {
                try finishInterruptedOperation(operation.token)
            }

            let fallbackStartError: Error?
            do {
                try fallback.start()
                fallbackStartError = nil
            } catch {
                fallbackStartError = error
            }

            guard operationIsCurrent(operation.token, phase: .starting) else {
                try finishInterruptedOperation(operation.token)
            }
            if let fallbackStartError {
                fallback.cancel()
                wireCallbacks()
                guard operationIsCurrent(operation.token, phase: .starting) else {
                    try finishInterruptedOperation(operation.token)
                }
                finishFailedOperation(operation.token, phase: .starting)
                throw fallbackStartError
            }
            guard completeOperation(operation.token, phase: .starting) else {
                try finishInterruptedOperation(operation.token)
            }
        case .fallback:
            let fallbackError: Error?
            do {
                try fallback.start()
                fallbackError = nil
            } catch {
                fallbackError = error
            }

            guard operationIsCurrent(operation.token, phase: .starting) else {
                try finishInterruptedOperation(operation.token)
            }
            if let fallbackError {
                fallback.cancel()
                wireCallbacks()
                guard operationIsCurrent(operation.token, phase: .starting) else {
                    try finishInterruptedOperation(operation.token)
                }
                finishFailedOperation(operation.token, phase: .starting)
                throw fallbackError
            }
            guard completeOperation(operation.token, phase: .starting) else {
                try finishInterruptedOperation(operation.token)
            }
        }
    }

    func stop() -> URL? {
        lock.lock()
        switch lifecyclePhase {
        case .preparing, .starting:
            let token = beginInterruptedCancellationLocked()
            lock.unlock()
            cancelChildrenAndRewire()
            finishCancellationTeardown(token: token)
            return nil
        case .idle:
            lifecyclePhase = .stopping
            cancelRequestedDuringStop = false
        case .stopping, .cancelling:
            lock.unlock()
            return nil
        }
        let recorder = activeRecorderLocked()
        let inactive = inactiveRecorderLocked()
        lock.unlock()

        let url = recorder.stop()
        inactive.cancel()
        wireCallbacks()

        lock.lock()
        let shouldCancel = cancelRequestedDuringStop
        if shouldCancel {
            lifecyclePhase = .cancelling
            activeRecorder = .primary
        } else if lifecyclePhase == .stopping {
            lifecyclePhase = .idle
        }
        cancelRequestedDuringStop = false
        lock.unlock()

        guard shouldCancel else { return url }
        cancelChildrenAndRewire()
        lock.lock()
        if lifecyclePhase == .cancelling {
            lifecyclePhase = .idle
        }
        lock.unlock()
        return nil
    }

    func cancel() {
        lock.lock()
        let interruptedToken: UInt64?
        switch lifecyclePhase {
        case .preparing, .starting:
            interruptedToken = beginInterruptedCancellationLocked()
        case .idle:
            lifecyclePhase = .cancelling
            activeRecorder = .primary
            interruptedToken = nil
        case .stopping:
            cancelRequestedDuringStop = true
            lock.unlock()
            return
        case .cancelling:
            lock.unlock()
            return
        }
        lock.unlock()

        cancelChildrenAndRewire()
        finishCancellationTeardown(token: interruptedToken)
    }

    func pause() {
        lock.lock()
        let recorder = activeRecorderLocked()
        lock.unlock()
        (recorder as? PausableStreamingDictationRecording)?.pause()
    }

    func resume() {
        lock.lock()
        let recorder = activeRecorderLocked()
        lock.unlock()
        (recorder as? PausableStreamingDictationRecording)?.resume()
    }

    func currentPower() -> Float {
        lock.lock()
        let recorder = activeRecorderLocked()
        lock.unlock()
        return recorder.currentPower()
    }

    private func emitRecorderSelection(
        slot: ActiveRecorder,
        recorder: StreamingDictationRecording,
        preferredInputDeviceID: AudioObjectID?
    ) {
        let slotName = slot == .primary ? "primary" : "fallback"
        let preferredInput = preferredInputDeviceID.map(String.init) ?? "default"
        emitLatency(
            "streaming_recorder_selected slot=\(slotName) recorder=\(String(describing: type(of: recorder))) preferredInput=\(preferredInput)"
        )
    }

    private func beginOperation(_ phase: LifecyclePhase) throws -> OperationContext {
        lock.lock()
        guard lifecyclePhase == .idle else {
            lock.unlock()
            throw Self.lifecycleError("Recorder lifecycle transition is already in progress")
        }
        nextOperationToken &+= 1
        let operation = OperationContext(
            token: nextOperationToken,
            activeRecorder: activeRecorder,
            preferredInputDeviceID: preferredInputDeviceIDStorage
        )
        activeOperationToken = operation.token
        lifecyclePhase = phase
        lock.unlock()
        return operation
    }

    private func operationIsCurrent(_ token: UInt64, phase: LifecyclePhase) -> Bool {
        lock.lock()
        let isCurrent = lifecyclePhase == phase && activeOperationToken == token
        lock.unlock()
        return isCurrent
    }

    private func completeOperation(
        _ token: UInt64,
        phase: LifecyclePhase,
        selecting recorder: ActiveRecorder? = nil
    ) -> Bool {
        lock.lock()
        guard lifecyclePhase == phase, activeOperationToken == token else {
            lock.unlock()
            return false
        }
        if let recorder {
            activeRecorder = recorder
        }
        lifecyclePhase = .idle
        activeOperationToken = nil
        lock.unlock()
        return true
    }

    private func selectFallbackDuringStart(_ token: UInt64) -> Bool {
        lock.lock()
        guard lifecyclePhase == .starting, activeOperationToken == token else {
            lock.unlock()
            return false
        }
        activeRecorder = .fallback
        lock.unlock()
        return true
    }

    private func finishFailedOperation(_ token: UInt64, phase: LifecyclePhase) {
        lock.lock()
        if lifecyclePhase == phase, activeOperationToken == token {
            lifecyclePhase = .idle
            activeOperationToken = nil
        }
        lock.unlock()
    }

    private func beginInterruptedCancellationLocked() -> UInt64? {
        let token = activeOperationToken
        lifecyclePhase = .cancelling
        interruptedOperationToken = token
        interruptedOperationFinished = false
        interruptedTeardownFinished = false
        activeRecorder = .primary
        return token
    }

    private func finishInterruptedOperation(_ token: UInt64) throws -> Never {
        lock.lock()
        let teardownAlreadyReturned = lifecyclePhase == .cancelling
            && interruptedOperationToken == token
            && interruptedTeardownFinished
        lock.unlock()

        if teardownAlreadyReturned {
            // A simple child may accept cancellation and return before its
            // in-flight start call unwinds. In that ordering, cancel once more
            // after start returns. If teardown is still running, it already
            // owns this cleanup and must not be raced by a duplicate call.
            cancelChildrenAndRewire()
        }

        lock.lock()
        if lifecyclePhase == .cancelling, interruptedOperationToken == token {
            interruptedOperationFinished = true
            finishInterruptedCancellationIfReadyLocked()
        }
        lock.unlock()
        throw Self.lifecycleError("Recorder lifecycle operation was cancelled")
    }

    private func finishCancellationTeardown(token: UInt64?) {
        lock.lock()
        guard lifecyclePhase == .cancelling else {
            lock.unlock()
            return
        }
        if let token {
            guard interruptedOperationToken == token else {
                lock.unlock()
                return
            }
            interruptedTeardownFinished = true
            finishInterruptedCancellationIfReadyLocked()
        } else {
            resetLifecycleLocked()
        }
        lock.unlock()
    }

    private func finishInterruptedCancellationIfReadyLocked() {
        guard interruptedOperationFinished, interruptedTeardownFinished else { return }
        resetLifecycleLocked()
    }

    private func resetLifecycleLocked() {
        lifecyclePhase = .idle
        activeOperationToken = nil
        interruptedOperationToken = nil
        interruptedOperationFinished = false
        interruptedTeardownFinished = false
        cancelRequestedDuringStop = false
    }

    private func cancelChildrenAndRewire() {
        primary.cancel()
        fallback.cancel()
        wireCallbacks()
    }

    private func wireCallbacks() {
        primary.onAudioBuffer = { [weak self] samples in
            self?.forwardAudioBuffer(samples, from: .primary)
        }
        fallback.onAudioBuffer = { [weak self] samples in
            self?.forwardAudioBuffer(samples, from: .fallback)
        }
        primary.onRecordingFailed = { [weak self] error in
            self?.forwardRecordingFailure(error, from: .primary)
        }
        fallback.onRecordingFailed = { [weak self] error in
            self?.forwardRecordingFailure(error, from: .fallback)
        }
        (primary as? StreamingDictationLatencyReporting)?.onLatencyEvent = { [weak self] event, date in
            self?.onLatencyEvent?(event, date)
        }
        (fallback as? StreamingDictationLatencyReporting)?.onLatencyEvent = { [weak self] event, date in
            self?.onLatencyEvent?(event, date)
        }
        (primary as? StreamingMicCaptureEventReporting)?.onCaptureEvent = { [weak self] event in
            self?.forwardCaptureEvent(event, from: .primary)
        }
        (fallback as? StreamingMicCaptureEventReporting)?.onCaptureEvent = { [weak self] event in
            self?.forwardCaptureEvent(event, from: .fallback)
        }
    }

    private func forwardAudioBuffer(_ samples: [Float], from recorder: ActiveRecorder) {
        lock.lock()
        let shouldForward = activeRecorder == recorder
        lock.unlock()
        guard shouldForward else { return }
        onAudioBuffer?(samples)
    }

    private func forwardRecordingFailure(_ error: Error, from recorder: ActiveRecorder) {
        lock.lock()
        let shouldForward = activeRecorder == recorder
        lock.unlock()
        guard shouldForward else { return }
        onRecordingFailed?(error)
    }

    private func forwardCaptureEvent(_ event: StreamingMicCaptureEvent, from recorder: ActiveRecorder) {
        lock.lock()
        let shouldForward = activeRecorder == recorder
        lock.unlock()
        guard shouldForward else { return }
        if let onCaptureEvent {
            onCaptureEvent(event)
        } else if case .failed(let failure) = event {
            onRecordingFailed?(failure.legacyError)
        }
    }

    private func activeRecorderLocked() -> StreamingDictationRecording {
        switch activeRecorder {
        case .primary:
            return primary
        case .fallback:
            return fallback
        }
    }

    private func inactiveRecorderLocked() -> StreamingDictationRecording {
        switch activeRecorder {
        case .primary:
            return fallback
        case .fallback:
            return primary
        }
    }

    private func emitLatency(_ event: String, at date: Date = Date()) {
        onLatencyEvent?(event, date)
    }

    private static func lifecycleError(_ message: String) -> NSError {
        NSError(
            domain: "FallbackStreamingDictationRecorder.Lifecycle",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
