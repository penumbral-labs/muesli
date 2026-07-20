import AudioToolbox
import CoreAudio
import Foundation
import os

struct AudioQueueProcessingAdmissionTicket: Equatable, Sendable {
    let captureGeneration: UInt64
    let pauseEpoch: UInt64
}

/// Generation state shared by AudioQueue callback admission and the processing
/// queue. Kept independent from CoreAudio so pause/stop invalidation semantics
/// can be exercised deterministically without opening a hardware device.
struct AudioQueueProcessingAdmissionState: Equatable, Sendable {
    private(set) var captureGeneration: UInt64 = 0
    private(set) var pauseEpoch: UInt64 = 0

    mutating func beginCapture() {
        captureGeneration &+= 1
        pauseEpoch &+= 1
    }

    mutating func invalidateCapture() {
        captureGeneration &+= 1
        pauseEpoch &+= 1
    }

    mutating func invalidateCapture(ifCurrent generation: UInt64) {
        guard captureGeneration == generation else { return }
        invalidateCapture()
    }

    mutating func advancePauseBoundary() {
        pauseEpoch &+= 1
    }

    var ticket: AudioQueueProcessingAdmissionTicket {
        AudioQueueProcessingAdmissionTicket(
            captureGeneration: captureGeneration,
            pauseEpoch: pauseEpoch
        )
    }

    func accepts(_ ticket: AudioQueueProcessingAdmissionTicket) -> Bool {
        ticket.captureGeneration == captureGeneration
            && ticket.pauseEpoch == pauseEpoch
    }
}

struct AudioQueueTeardownState: Equatable, Sendable {
    enum Transition: Equatable, Sendable {
        case idle
        case preparing
        case starting
        case stopping
        case cancelling
    }

    enum PreparationCompletion: Equatable, Sendable {
        case install
        case discard
    }

    enum StartCompletion: Equatable, Sendable {
        case active
        case tearDown
    }

    private(set) var transition: Transition = .idle
    private(set) var cancelRequestedDuringStop = false
    private var teardownRequestedDuringPreparation = false
    private var teardownRequestedDuringStart = false

    var permitsGraphMutation: Bool { transition == .idle }
    var permitsStartCall: Bool {
        transition == .starting && !teardownRequestedDuringStart
    }

    mutating func beginPreparation() -> Bool {
        guard transition == .idle else { return false }
        transition = .preparing
        teardownRequestedDuringPreparation = false
        return true
    }

    /// The preparation owner remains responsible for disposing its local graph.
    /// A racing stop/cancel only records intent and never seizes that graph.
    mutating func finishPreparation(succeeded: Bool) -> PreparationCompletion {
        guard transition == .preparing else { return .discard }
        let shouldInstall = succeeded && !teardownRequestedDuringPreparation
        transition = shouldInstall ? .idle : .cancelling
        teardownRequestedDuringPreparation = false
        return shouldInstall ? .install : .discard
    }

    mutating func beginStart() -> Bool {
        guard transition == .idle else { return false }
        transition = .starting
        teardownRequestedDuringStart = false
        return true
    }

    /// AudioQueueStart runs without the state lock. Its owner resolves every
    /// stop/cancel request that arrived meanwhile before reopening admission.
    mutating func finishStart(succeeded: Bool) -> StartCompletion {
        guard transition == .starting else { return .tearDown }
        let shouldRemainActive = succeeded && !teardownRequestedDuringStart
        transition = shouldRemainActive ? .idle : .cancelling
        teardownRequestedDuringStart = false
        return shouldRemainActive ? .active : .tearDown
    }

    mutating func beginStop() -> Bool {
        switch transition {
        case .idle:
            transition = .stopping
            cancelRequestedDuringStop = false
            return true
        case .preparing:
            teardownRequestedDuringPreparation = true
            return false
        case .starting:
            teardownRequestedDuringStart = true
            return false
        case .stopping, .cancelling:
            return false
        }
    }

    mutating func beginCancel() -> Bool {
        switch transition {
        case .idle:
            transition = .cancelling
            cancelRequestedDuringStop = false
            return true
        case .preparing:
            teardownRequestedDuringPreparation = true
            return false
        case .starting:
            teardownRequestedDuringStart = true
            return false
        case .stopping:
            cancelRequestedDuringStop = true
            return false
        case .cancelling:
            return false
        }
    }

    /// Returns whether a cancel raced with stop. In that case ownership moves
    /// directly to a cancel transition so the prepared CoreAudio graph is also
    /// disposed before a later start is admitted.
    mutating func finishStop() -> Bool {
        guard transition == .stopping else { return false }
        let shouldCancel = cancelRequestedDuringStop
        transition = shouldCancel ? .cancelling : .idle
        cancelRequestedDuringStop = false
        return shouldCancel
    }

    mutating func finishCancel() {
        guard transition == .cancelling else { return }
        transition = .idle
        cancelRequestedDuringStop = false
        teardownRequestedDuringPreparation = false
        teardownRequestedDuringStart = false
    }
}

final class AudioQueueInputRecorder: StreamingDictationRecording, StreamingDictationLatencyReporting, PausableStreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?
    var preferredInputDeviceID: AudioObjectID? {
        get {
            queueLock.lock()
            defer { queueLock.unlock() }
            return preferredInputDeviceIDStorage
        }
        set {
            queueLock.lock()
            preferredInputDeviceIDStorage = newValue
            queueLock.unlock()
        }
    }

    private static let sampleRate: Double = 16_000
    private static let framesPerBuffer: UInt32 = 4096
    private static let bufferCount = 3

    private let directoryName: String
    private let queueLock = NSRecursiveLock()
    private let stateLock = OSAllocatedUnfairLock(initialState: FileState())
    private let processingQueue = DispatchQueue(label: "com.muesli.audio-queue-input-recorder-processing")
    private let processingQueueKey = DispatchSpecificKey<UInt8>()
    private let failureCallbackQueue = DispatchQueue(label: "com.muesli.audio-queue-input-recorder-failures")

    private var audioQueue: AudioQueueRef?
    private var queueCallbackUserData: UnsafeMutableRawPointer?
    private var buffers: [AudioQueueBufferRef] = []
    private var preferredInputDeviceIDStorage: AudioObjectID?
    private var preparedInputDeviceID: AudioObjectID?
    private var isPrepared = false
    private var isRunning = false
    private var isPaused = false
    private var processingAdmission = AudioQueueProcessingAdmissionState()
    private var teardownState = AudioQueueTeardownState()
    private var pauseTransitionGeneration: UInt64?
    private var resumeRequestedForPauseGeneration: UInt64?

    private struct FileState {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten = 0
        var latestPowerDB: Float = -160
    }

    private struct PreparedQueueGraph {
        let queue: AudioQueueRef
        let callbackUserData: UnsafeMutableRawPointer
        let buffers: [AudioQueueBufferRef]
        let inputDeviceID: AudioObjectID?
    }

    private struct DetachedQueueGraph {
        let queue: AudioQueueRef?
        let callbackUserData: UnsafeMutableRawPointer?
    }

    init(directoryName: String = "muesli-native-dictation") {
        self.directoryName = directoryName
        processingQueue.setSpecific(key: processingQueueKey, value: 1)
    }

    deinit {
        cancel()
    }

    func prepare() throws {
        queueLock.lock()
        guard teardownState.permitsGraphMutation else {
            queueLock.unlock()
            throw Self.runtimeError(code: 10, message: "Microphone teardown is still completing")
        }
        let preferredInputDeviceID = preferredInputDeviceIDStorage
        if isPrepared, preparedInputDeviceID == preferredInputDeviceID {
            queueLock.unlock()
            emitLatency("audio_queue_prepare_reused")
            return
        }
        guard !isRunning, teardownState.beginPreparation() else {
            queueLock.unlock()
            throw Self.runtimeError(code: 10, message: "Microphone lifecycle transition is already in progress")
        }
        let previousGraph = detachQueueLocked(invalidateCapture: false)
        queueLock.unlock()

        // CoreAudio can synchronously wait for its callback while disposing a
        // queue. The callback also needs `queueLock`, so graph ownership is
        // always detached under the lock and destroyed only after unlocking.
        disposeDetachedGraph(previousGraph, stopFirst: false)
        emitLatency("audio_queue_prepare_begin")

        let graph: PreparedQueueGraph
        do {
            graph = try makePreparedQueueGraph(preferredInputDeviceID: preferredInputDeviceID)
        } catch {
            queueLock.lock()
            _ = teardownState.finishPreparation(succeeded: false)
            teardownState.finishCancel()
            queueLock.unlock()
            throw error
        }

        queueLock.lock()
        let completion = teardownState.finishPreparation(succeeded: true)
        if completion == .install {
            installPreparedGraphLocked(graph)
            queueLock.unlock()
            emitLatency("audio_queue_prepare_end")
            return
        }
        queueLock.unlock()

        disposePreparedGraph(graph)
        queueLock.lock()
        teardownState.finishCancel()
        queueLock.unlock()
        throw Self.runtimeError(code: 11, message: "Microphone preparation was cancelled")
    }

    func start() throws {
        queueLock.lock()
        if isRunning {
            queueLock.unlock()
            return
        }
        queueLock.unlock()

        try prepare()

        queueLock.lock()
        guard !isRunning else {
            queueLock.unlock()
            return
        }
        guard teardownState.beginStart() else {
            queueLock.unlock()
            throw Self.runtimeError(code: 10, message: "Microphone lifecycle transition is already in progress")
        }
        guard let audioQueue else {
            _ = teardownState.finishStart(succeeded: false)
            teardownState.finishCancel()
            queueLock.unlock()
            throw Self.runtimeError(code: 1, message: "Audio queue was not initialized")
        }
        let buffers = buffers
        queueLock.unlock()

        let fileState: FileState
        do {
            fileState = try createNewFile()
        } catch {
            tearDownFailedStart(queueMayHaveStarted: false)
            throw error
        }
        stateLock.withLock { $0 = fileState }

        for buffer in buffers {
            let status = AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil)
            guard status == noErr else {
                tearDownFailedStart(queueMayHaveStarted: false)
                throw Self.runtimeError(code: 2, message: "AudioQueueEnqueueBuffer failed: \(status)")
            }
        }

        queueLock.lock()
        guard teardownState.permitsStartCall else {
            _ = teardownState.finishStart(succeeded: false)
            isRunning = false
            processingAdmission.invalidateCapture()
            let graph = detachQueueLocked(invalidateCapture: false)
            queueLock.unlock()
            finishCancelledStart(graph: graph, queueMayHaveStarted: false)
            throw Self.runtimeError(code: 11, message: "Microphone startup was cancelled")
        }
        processingAdmission.beginCapture()
        pauseTransitionGeneration = nil
        resumeRequestedForPauseGeneration = nil
        isPaused = false
        isRunning = true
        queueLock.unlock()

        emitLatency("audio_queue_start_begin")
        let status = AudioQueueStart(audioQueue, nil)
        emitLatency("audio_queue_start_end")

        queueLock.lock()
        let completion = teardownState.finishStart(succeeded: status == noErr)
        if completion == .active {
            queueLock.unlock()
            return
        }
        isRunning = false
        processingAdmission.invalidateCapture()
        pauseTransitionGeneration = nil
        resumeRequestedForPauseGeneration = nil
        let graph = detachQueueLocked(invalidateCapture: false)
        queueLock.unlock()

        finishCancelledStart(graph: graph, queueMayHaveStarted: true)
        guard status == noErr else {
            throw Self.runtimeError(code: 3, message: "AudioQueueStart failed: \(status)")
        }
        throw Self.runtimeError(code: 11, message: "Microphone startup was cancelled")
    }

    func stop() -> URL? {
        queueLock.lock()
        if teardownState.transition == .preparing || teardownState.transition == .starting {
            let interruptedStart = teardownState.transition == .starting
            _ = teardownState.beginStop()
            if interruptedStart {
                isRunning = false
                isPaused = false
                processingAdmission.invalidateCapture()
                pauseTransitionGeneration = nil
                resumeRequestedForPauseGeneration = nil
            }
            queueLock.unlock()
            return nil
        }
        guard isRunning, teardownState.beginStop() else {
            queueLock.unlock()
            return nil
        }
        isRunning = false
        let generationToFinish = processingAdmission.captureGeneration
        let queueToStop = audioQueue
        queueLock.unlock()

        if let queueToStop {
            emitLatency("audio_queue_stop_begin")
            AudioQueueStop(queueToStop, true)
            emitLatency("audio_queue_stop_end")
        }

        emitLatency("audio_queue_processing_drain_begin")
        let drainedSynchronously = drainProcessingQueue()
        emitLatency("audio_queue_processing_drain_end")

        queueLock.lock()
        processingAdmission.invalidateCapture(ifCurrent: generationToFinish)
        isPaused = false
        if pauseTransitionGeneration == generationToFinish {
            pauseTransitionGeneration = nil
            resumeRequestedForPauseGeneration = nil
        }
        queueLock.unlock()

        emitLatency("audio_queue_finalize_begin")
        let finalState = stateLock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
        let url = finalizeFile(finalState)
        emitLatency("audio_queue_finalize_end")

        if !drainedSynchronously {
            // A callback cannot wait for its own queue. Keep teardown owned
            // until that callback and all older work return, then honor any
            // cancel that raced with this stop.
            processingQueue.async { [self] in
                _ = finishStopTransition(outputURL: url)
            }
            return url
        }
        return finishStopTransition(outputURL: url) ? nil : url
    }

    func cancel() {
        queueLock.lock()
        let interruptedTransition = teardownState.transition
        guard teardownState.beginCancel() else {
            if interruptedTransition == .starting {
                isRunning = false
                isPaused = false
                processingAdmission.invalidateCapture()
                pauseTransitionGeneration = nil
                resumeRequestedForPauseGeneration = nil
            }
            queueLock.unlock()
            return
        }
        isRunning = false
        isPaused = false
        processingAdmission.invalidateCapture()
        pauseTransitionGeneration = nil
        resumeRequestedForPauseGeneration = nil
        let graph = detachQueueLocked(invalidateCapture: false)
        queueLock.unlock()

        disposeDetachedGraph(graph, stopFirst: true, latencyPrefix: "audio_queue_cancel")

        let drainedSynchronously = drainProcessingQueue()
        discardCurrentFile()
        finishCancelTransition(afterSynchronousDrain: drainedSynchronously)
    }

    func currentPower() -> Float {
        stateLock.withLock { $0.latestPowerDB }
    }

    func pause() {
        let isReentrant = DispatchQueue.getSpecific(key: processingQueueKey) != nil
        queueLock.lock()
        let pauseGeneration = processingAdmission.captureGeneration
        guard isRunning,
              teardownState.permitsGraphMutation,
              pauseTransitionGeneration != pauseGeneration else {
            queueLock.unlock()
            return
        }
        pauseTransitionGeneration = pauseGeneration
        resumeRequestedForPauseGeneration = nil
        isPaused = true
        if isReentrant {
            processingAdmission.advancePauseBoundary()
        }
        queueLock.unlock()
        // Every data block admitted before the paused flag was installed is
        // already queued while holding queueLock. Drain those blocks before
        // exposing the meeting-level pause boundary.
        if !isReentrant {
            drainProcessingQueue()
            queueLock.lock()
            if processingAdmission.captureGeneration == pauseGeneration,
               pauseTransitionGeneration == pauseGeneration {
                // No new work can be admitted while paused. Advancing after
                // the drain makes the completed boundary explicit for resume.
                processingAdmission.advancePauseBoundary()
            }
            queueLock.unlock()
        }
        queueLock.lock()
        if pauseTransitionGeneration == pauseGeneration {
            if processingAdmission.captureGeneration == pauseGeneration,
               resumeRequestedForPauseGeneration == pauseGeneration {
                isPaused = false
            }
            pauseTransitionGeneration = nil
            resumeRequestedForPauseGeneration = nil
        }
        queueLock.unlock()
        stateLock.withLock { $0.latestPowerDB = -160 }
    }

    func resume() {
        queueLock.lock()
        guard isRunning, teardownState.permitsGraphMutation else {
            queueLock.unlock()
            return
        }
        let generation = processingAdmission.captureGeneration
        if pauseTransitionGeneration == generation {
            resumeRequestedForPauseGeneration = generation
            queueLock.unlock()
            return
        }
        isPaused = false
        queueLock.unlock()
    }

    private func makePreparedQueueGraph(
        preferredInputDeviceID: AudioObjectID?
    ) throws -> PreparedQueueGraph {
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var queue: AudioQueueRef?
        let callbackUserData = Unmanaged.passRetained(self).toOpaque()
        emitLatency("audio_queue_new_input_begin")
        let newInputStatus = AudioQueueNewInput(
            &format,
            Self.inputCallback,
            callbackUserData,
            nil,
            nil,
            0,
            &queue
        )
        emitLatency("audio_queue_new_input_end")
        guard newInputStatus == noErr, let queue else {
            Self.releaseCallbackUserData(callbackUserData)
            throw Self.runtimeError(code: 4, message: "AudioQueueNewInput failed: \(newInputStatus)")
        }

        var allocatedBuffers: [AudioQueueBufferRef] = []
        do {
            if let preferredInputDeviceID {
                try applyPreferredInputDeviceID(preferredInputDeviceID, to: queue)
            } else {
                emitLatency("audio_queue_preferred_input_default_route")
            }

            let bytesPerBuffer = Self.framesPerBuffer * format.mBytesPerFrame
            emitLatency("audio_queue_allocate_buffers_begin")
            for _ in 0..<Self.bufferCount {
                var buffer: AudioQueueBufferRef?
                let status = AudioQueueAllocateBuffer(queue, bytesPerBuffer, &buffer)
                guard status == noErr, let buffer else {
                    throw Self.runtimeError(code: 5, message: "AudioQueueAllocateBuffer failed: \(status)")
                }
                allocatedBuffers.append(buffer)
            }
            emitLatency("audio_queue_allocate_buffers_end")
        } catch {
            // This queue is still local to the preparation owner; no other
            // lifecycle method can observe or seize it.
            AudioQueueDispose(queue, true)
            Self.releaseCallbackUserData(callbackUserData)
            throw error
        }

        return PreparedQueueGraph(
            queue: queue,
            callbackUserData: callbackUserData,
            buffers: allocatedBuffers,
            inputDeviceID: preferredInputDeviceID
        )
    }

    private func applyPreferredInputDeviceID(_ deviceID: AudioObjectID, to queue: AudioQueueRef) throws {
        emitLatency("audio_queue_device_uid_lookup_begin")
        guard var deviceUID = Self.deviceUID(for: deviceID) as CFString? else {
            throw Self.runtimeError(code: 6, message: "Could not resolve device UID for \(deviceID)")
        }
        emitLatency("audio_queue_device_uid_lookup_end")

        emitLatency("audio_queue_set_current_device_begin")
        let status = withUnsafePointer(to: &deviceUID) { pointer in
            AudioQueueSetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                pointer,
                UInt32(MemoryLayout<CFString>.size)
            )
        }
        emitLatency("audio_queue_set_current_device_end")
        guard status == noErr else {
            throw Self.runtimeError(code: 7, message: "AudioQueueSetProperty current device failed: \(status)")
        }
    }

    private static let inputCallback: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
        guard let userData else { return }
        let recorder = Unmanaged<AudioQueueInputRecorder>.fromOpaque(userData).takeUnretainedValue()
        recorder.handleInputBuffer(queue: queue, buffer: buffer)
    }

    private func handleInputBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        queueLock.lock()
        let shouldProcess = isRunning
        queueLock.unlock()
        guard shouldProcess else { return }

        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        guard byteCount > 0 else {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            return
        }

        let audioData = Data(bytes: buffer.pointee.mAudioData, count: byteCount)
        let enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if enqueueStatus != noErr {
            reportFailure(Self.runtimeError(code: 8, message: "AudioQueueEnqueueBuffer failed: \(enqueueStatus)"))
            return
        }

        queueLock.lock()
        guard isRunning, !isPaused else {
            queueLock.unlock()
            return
        }
        let admissionTicket = processingAdmission.ticket
        // Queue admission linearizes with pause while the same lock is held.
        processingQueue.async { [weak self] in
            self?.processAudioData(
                audioData,
                admissionTicket: admissionTicket
            )
        }
        queueLock.unlock()
    }

    private func processAudioData(
        _ data: Data,
        admissionTicket: AudioQueueProcessingAdmissionTicket
    ) {
        queueLock.lock()
        let shouldProcess = processingAdmission.accepts(admissionTicket)
        queueLock.unlock()
        guard shouldProcess else { return }

        let sampleCount = data.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return }

        let samples = data.withUnsafeBytes { rawBuffer -> [Float] in
            var decoded = [Float]()
            decoded.reserveCapacity(sampleCount)
            for offset in stride(from: 0, to: sampleCount * MemoryLayout<Float>.size, by: MemoryLayout<Float>.size) {
                decoded.append(rawBuffer.loadUnaligned(fromByteOffset: offset, as: Float.self))
            }
            return decoded
        }
        guard !samples.isEmpty else { return }

        var int16Samples = [Int16](repeating: 0, count: sampleCount)
        var sumSquares: Float = 0
        for index in samples.indices {
            let sample = samples[index]
            let clamped = max(-1.0, min(1.0, sample))
            int16Samples[index] = Int16(clamped * 32767)
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(sampleCount))
        let rawDB = rms > 0.000_001 ? 20 * log10(rms) : -160
        let powerDB = max(-160, min(0, rawDB))
        let pcmData = int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }

        stateLock.withLock { state in
            state.fileHandle?.write(pcmData)
            state.bytesWritten += pcmData.count
            state.latestPowerDB = powerDB
        }
        onAudioBuffer?(samples)
    }

    private func installPreparedGraphLocked(_ graph: PreparedQueueGraph) {
        audioQueue = graph.queue
        queueCallbackUserData = graph.callbackUserData
        buffers = graph.buffers
        preparedInputDeviceID = graph.inputDeviceID
        isPrepared = true
    }

    /// Removes every shared reference to a queue while `queueLock` is held.
    /// The returned graph must be stopped/disposed only after unlocking.
    private func detachQueueLocked(invalidateCapture: Bool) -> DetachedQueueGraph? {
        let graph = DetachedQueueGraph(
            queue: audioQueue,
            callbackUserData: queueCallbackUserData
        )
        if invalidateCapture {
            processingAdmission.invalidateCapture()
        }
        isRunning = false
        isPaused = false
        audioQueue = nil
        queueCallbackUserData = nil
        buffers.removeAll()
        preparedInputDeviceID = nil
        isPrepared = false
        guard graph.queue != nil || graph.callbackUserData != nil else { return nil }
        return graph
    }

    private func disposePreparedGraph(_ graph: PreparedQueueGraph) {
        disposeDetachedGraph(
            DetachedQueueGraph(
                queue: graph.queue,
                callbackUserData: graph.callbackUserData
            ),
            stopFirst: false
        )
    }

    private func disposeDetachedGraph(
        _ graph: DetachedQueueGraph?,
        stopFirst: Bool,
        latencyPrefix: String? = nil
    ) {
        guard let graph else { return }
        if let queue = graph.queue {
            if stopFirst {
                if let latencyPrefix {
                    emitLatency("\(latencyPrefix)_stop_begin")
                }
                AudioQueueStop(queue, true)
                if let latencyPrefix {
                    emitLatency("\(latencyPrefix)_stop_end")
                }
            }
            AudioQueueDispose(queue, true)
        }
        Self.releaseCallbackUserData(graph.callbackUserData)
    }

    private func tearDownFailedStart(queueMayHaveStarted: Bool) {
        queueLock.lock()
        _ = teardownState.finishStart(succeeded: false)
        processingAdmission.invalidateCapture()
        isRunning = false
        isPaused = false
        pauseTransitionGeneration = nil
        resumeRequestedForPauseGeneration = nil
        let graph = detachQueueLocked(invalidateCapture: false)
        queueLock.unlock()
        finishCancelledStart(graph: graph, queueMayHaveStarted: queueMayHaveStarted)
    }

    private func finishCancelledStart(
        graph: DetachedQueueGraph?,
        queueMayHaveStarted: Bool
    ) {
        disposeDetachedGraph(
            graph,
            stopFirst: queueMayHaveStarted,
            latencyPrefix: "audio_queue_start_cleanup"
        )
        let drainedSynchronously = drainProcessingQueue()
        discardCurrentFile()
        finishCancelTransition(afterSynchronousDrain: drainedSynchronously)
    }

    private func discardCurrentFile() {
        let state = stateLock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
        state.fileHandle?.closeFile()
        if let url = state.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func finishCancelTransition(afterSynchronousDrain drainedSynchronously: Bool) {
        if drainedSynchronously {
            queueLock.lock()
            teardownState.finishCancel()
            queueLock.unlock()
        } else {
            processingQueue.async { [self] in
                queueLock.lock()
                teardownState.finishCancel()
                queueLock.unlock()
            }
        }
    }

    private func reportFailure(_ error: Error) {
        failureCallbackQueue.async { [onRecordingFailed] in
            onRecordingFailed?(error)
        }
    }

    @discardableResult
    private func drainProcessingQueue() -> Bool {
        guard DispatchQueue.getSpecific(key: processingQueueKey) == nil else { return false }
        processingQueue.sync {}
        return true
    }

    /// Completes a stop transition after its processing-queue barrier. Returns
    /// true when a concurrent cancel took ownership and discarded the output.
    private func finishStopTransition(outputURL: URL?) -> Bool {
        queueLock.lock()
        let shouldCancel = teardownState.finishStop()
        let graph = shouldCancel ? detachQueueLocked(invalidateCapture: false) : nil
        queueLock.unlock()
        guard shouldCancel else { return false }

        // The normal stop owner already stopped this queue before its drain.
        disposeDetachedGraph(graph, stopFirst: false)
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        queueLock.lock()
        teardownState.finishCancel()
        queueLock.unlock()
        return true
    }

    private func emitLatency(_ event: String, at date: Date = Date()) {
        onLatencyEvent?(event, date)
    }

    private static func runtimeError(code: Int, message: String) -> NSError {
        NSError(domain: "AudioQueueInputRecorder", code: code, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }

    private static func releaseCallbackUserData(_ userData: UnsafeMutableRawPointer?) {
        guard let userData else { return }
        Unmanaged<AudioQueueInputRecorder>.fromOpaque(userData).release()
    }

    private static func deviceUID(for deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &uid) == noErr,
              let uid else {
            return nil
        }
        return uid.takeRetainedValue() as String
    }

    private func createNewFile() throws -> FileState {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw Self.runtimeError(code: 9, message: "Could not open file for writing")
        }
        handle.write(WavWriter.header(dataSize: 0))
        return FileState(fileHandle: handle, fileURL: url, bytesWritten: 0)
    }

    private func finalizeFile(_ state: FileState) -> URL? {
        guard let handle = state.fileHandle, let url = state.fileURL else { return nil }
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
