import Foundation
import os
import Testing
@testable import MuesliNativeApp

@Suite("Streaming microphone callback delivery")
struct StreamingMicCallbackDeliveryGateTests {
    @Test("nested teardown owners cannot reopen capture early")
    func nestedDrainFenceRemainsClosedUntilLastOwnerCompletes() {
        var fence = StreamingMicCallbackDrainFence()
        #expect(fence.permitsNewCapture)

        fence.begin()
        fence.begin()
        #expect(!fence.permitsNewCapture)

        fence.end()
        #expect(!fence.permitsNewCapture)

        fence.end()
        #expect(fence.permitsNewCapture)
    }

    @Test("queued callbacks from a stopped run cannot enter the next run")
    func staleRunCallbacksAreDiscarded() async throws {
        let queue = DispatchQueue(label: "StreamingMicCallbackDeliveryGateTests.stale")
        let gate = StreamingMicCallbackDeliveryGate(queue: queue)
        let delivered = OSAllocatedUnfairLock(initialState: [UUID]())
        let oldRun = UUID()
        let newRun = UUID()

        queue.suspend()
        gate.begin(oldRun)
        gate.enqueue(recordingID: oldRun) {
            delivered.withLock { $0.append(oldRun) }
        }
        gate.invalidate(oldRun)
        gate.begin(newRun)
        queue.resume()

        gate.enqueue(recordingID: newRun) {
            delivered.withLock { $0.append(newRun) }
        }

        #expect(await waitUntil { delivered.withLock { $0.count == 1 } })
        #expect(delivered.withLock { $0 } == [newRun])
    }

    @Test("matching-run callback payloads retain submission order")
    func matchingRunCallbacksAreFIFO() async throws {
        let queue = DispatchQueue(label: "StreamingMicCallbackDeliveryGateTests.fifo")
        let gate = StreamingMicCallbackDeliveryGate(queue: queue)
        let delivered = OSAllocatedUnfairLock(initialState: [Int]())
        let run = UUID()
        gate.begin(run)

        for value in 0..<4 {
            gate.enqueue(recordingID: run) {
                delivered.withLock { $0.append(value) }
            }
        }

        #expect(await waitUntil { delivered.withLock { $0.count == 4 } })
        #expect(delivered.withLock { $0 } == [0, 1, 2, 3])
    }

    @Test("drain waits for matching in-flight work but not a newer recording")
    func drainWaitsOnlyForInvalidatedRun() throws {
        let queue = DispatchQueue(label: "StreamingMicCallbackDeliveryGateTests.in-flight")
        let gate = StreamingMicCallbackDeliveryGate(queue: queue)
        let oldRun = UUID()
        let newRun = UUID()
        let workStarted = DispatchSemaphore(value: 0)
        let releaseWork = DispatchSemaphore(value: 0)
        let drainFinished = DispatchSemaphore(value: 0)

        gate.begin(oldRun)
        gate.enqueue(recordingID: oldRun) {
            workStarted.signal()
            releaseWork.wait()
        }
        #expect(workStarted.wait(timeout: .now() + 1) == .success)

        let invalidatedRun = gate.invalidate(oldRun)
        gate.begin(newRun)
        DispatchQueue.global(qos: .utility).async {
            gate.drain(recordingID: invalidatedRun)
            drainFinished.signal()
        }

        #expect(drainFinished.wait(timeout: .now() + 0.05) == .timedOut)
        releaseWork.signal()
        #expect(drainFinished.wait(timeout: .now() + 1) == .success)
        #expect(gate.accepts(newRun))
    }

    @Test("a callback can invalidate and drain its own run without deadlocking")
    func reentrantDrainIsNonBlocking() throws {
        let queue = DispatchQueue(label: "StreamingMicCallbackDeliveryGateTests.reentrant")
        let gate = StreamingMicCallbackDeliveryGate(queue: queue)
        let run = UUID()
        let finished = DispatchSemaphore(value: 0)
        gate.begin(run)

        gate.enqueue(recordingID: run) {
            let invalidatedRun = gate.invalidate(run)
            gate.drain(recordingID: invalidatedRun)
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(!gate.accepts(run))
    }

    @Test("reentrant teardown keeps capture fenced until its callback returns")
    func reentrantDrainCompletesFenceAfterOwnerCallback() throws {
        let queue = DispatchQueue(label: "StreamingMicCallbackDeliveryGateTests.reentrant-fence")
        let gate = StreamingMicCallbackDeliveryGate(queue: queue)
        let fence = OSAllocatedUnfairLock(initialState: StreamingMicCallbackDrainFence())
        let run = UUID()
        let teardownReturned = DispatchSemaphore(value: 0)
        let callbackMayReturn = DispatchSemaphore(value: 0)
        let deferredDrainFinished = DispatchSemaphore(value: 0)
        gate.begin(run)
        fence.withLock { $0.begin() }

        gate.enqueue(recordingID: run) {
            gate.invalidate(run)
            let drainedSynchronously = gate.drain(
                recordingIDs: [run],
                onReentrantCompletion: {
                    fence.withLock { $0.end() }
                    deferredDrainFinished.signal()
                }
            )
            #expect(!drainedSynchronously)
            teardownReturned.signal()
            callbackMayReturn.wait()
        }

        #expect(teardownReturned.wait(timeout: .now() + 1) == .success)
        #expect(!fence.withLock { $0.permitsNewCapture })
        callbackMayReturn.signal()
        #expect(deferredDrainFinished.wait(timeout: .now() + 1) == .success)
        #expect(fence.withLock { $0.permitsNewCapture })
    }

    @Test("pause delivers committed payloads before closing the active gate")
    func pauseIsDeliveryBarrier() throws {
        let queue = DispatchQueue(label: "StreamingMicCallbackDeliveryGateTests.pause")
        let gate = StreamingMicCallbackDeliveryGate(queue: queue)
        let run = UUID()
        let workStarted = DispatchSemaphore(value: 0)
        let releaseWork = DispatchSemaphore(value: 0)
        let pauseFinished = DispatchSemaphore(value: 0)
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        gate.begin(run)
        gate.enqueue(recordingID: run) {
            workStarted.signal()
            releaseWork.wait()
            delivered.withLock { $0 += 1 }
        }
        #expect(workStarted.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global(qos: .utility).async {
            gate.pause(run)
            pauseFinished.signal()
        }
        #expect(gate.waitUntilPayloadAdmissionCloses(run, timeout: 1))
        #expect(pauseFinished.wait(timeout: .now() + 0.05) == .timedOut)
        gate.enqueue(recordingID: run) {
            delivered.withLock { $0 += 10 }
        }
        releaseWork.signal()
        #expect(pauseFinished.wait(timeout: .now() + 1) == .success)
        #expect(delivered.withLock { $0 } == 1)
        #expect(!gate.accepts(run))

        gate.resume(run)
        #expect(gate.accepts(run))
    }

    @Test("resume racing an external pause is applied after its drain boundary")
    func resumeDuringPauseIsNotLost() throws {
        let queue = DispatchQueue(label: "StreamingMicCallbackDeliveryGateTests.pause-resume-race")
        let gate = StreamingMicCallbackDeliveryGate(queue: queue)
        let run = UUID()
        let workStarted = DispatchSemaphore(value: 0)
        let releaseWork = DispatchSemaphore(value: 0)
        let pauseFinished = DispatchSemaphore(value: 0)
        gate.begin(run)
        gate.enqueue(recordingID: run) {
            workStarted.signal()
            releaseWork.wait()
        }
        #expect(workStarted.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global(qos: .utility).async {
            gate.pause(run)
            pauseFinished.signal()
        }
        #expect(gate.waitUntilPayloadAdmissionCloses(run, timeout: 1))
        #expect(pauseFinished.wait(timeout: .now() + 0.05) == .timedOut)
        gate.resume(run)
        releaseWork.signal()

        #expect(pauseFinished.wait(timeout: .now() + 1) == .success)
        #expect(gate.accepts(run))
    }

    @Test("reentrant pause closes a compound callback without deadlocking")
    func reentrantPauseStopsRemainingPayloads() throws {
        let queue = DispatchQueue(label: "StreamingMicCallbackDeliveryGateTests.reentrant-pause")
        let gate = StreamingMicCallbackDeliveryGate(queue: queue)
        let run = UUID()
        let finished = DispatchSemaphore(value: 0)
        let delivered = OSAllocatedUnfairLock(initialState: [String]())
        gate.begin(run)

        gate.enqueue(recordingID: run) {
            delivered.withLock { $0.append("event") }
            gate.pause(run)
            if gate.accepts(run) {
                delivered.withLock { $0.append("pcm") }
            }
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(delivered.withLock { $0 } == ["event"])
        #expect(!gate.accepts(run))
    }

    @Test("terminal control events remain deliverable while audio is paused")
    func controlEventsBypassPauseButRemainRunScoped() throws {
        let queue = DispatchQueue(label: "StreamingMicCallbackDeliveryGateTests.paused-control")
        let gate = StreamingMicCallbackDeliveryGate(queue: queue)
        let run = UUID()
        let delivered = DispatchSemaphore(value: 0)
        gate.begin(run)
        gate.pause(run)

        gate.enqueue(recordingID: run) {
            Issue.record("Audio payload crossed the pause boundary")
        }
        gate.enqueueControl(recordingID: run) {
            delivered.signal()
        }

        #expect(delivered.wait(timeout: .now() + 1) == .success)

        let staleDelivered = DispatchSemaphore(value: 0)
        gate.invalidate(run)
        gate.enqueueControl(recordingID: run) {
            staleDelivered.signal()
        }
        #expect(staleDelivered.wait(timeout: .now() + 0.05) == .timedOut)
    }
}

private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
