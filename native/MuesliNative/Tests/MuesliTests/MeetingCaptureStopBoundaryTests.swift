import Foundation
import os
import Testing
@testable import MuesliNativeApp

@Suite("Meeting capture stop boundary")
struct MeetingCaptureStopBoundaryTests {
    @Test("admitted source tails are finalized exactly once before graphs stop")
    func admittedTailsAreFinalizedExactlyOnce() {
        let ownerQueue = DispatchQueue(label: "MeetingCaptureStopBoundaryTests.owner")
        let captured = OSAllocatedUnfairLock(initialState: (mic: [Int](), system: [Int]()))
        let lifecycle = OSAllocatedUnfairLock(initialState: [String]())
        let mic = StopBoundarySource(label: "mic")
        let system = StopBoundarySource(label: "system")

        mic.onSample = { value in
            ownerQueue.async {
                captured.withLock { $0.mic.append(value) }
            }
        }
        system.onSample = { value in
            ownerQueue.async {
                captured.withLock { $0.system.append(value) }
            }
        }

        // These callbacks are already admitted by each source when stop begins,
        // but have not crossed the meeting owner queue yet.
        mic.admit(11)
        system.admit(22)

        let result = MeetingCaptureStopBoundary.quiesce(
            pauseSources: {
                lifecycle.withLock { $0.append("pause") }
                mic.pauseAndDrain()
                system.pauseAndDrain()
            },
            disconnectSourceCallbacks: {
                lifecycle.withLock { $0.append("disconnect") }
                mic.onSample = nil
                system.onSample = nil
            },
            drainOwnerAndFinalizeChunks: {
                let snapshot: (mic: [Int], system: [Int]) = ownerQueue.sync {
                    () -> (mic: [Int], system: [Int]) in
                    lifecycle.withLock { $0.append("finalize-chunks") }
                    return captured.withLock { state in
                        (mic: state.mic, system: state.system)
                    }
                }
                return snapshot
            },
            finalizeWriter: {
                lifecycle.withLock { $0.append("finalize-writer") }
                return captured.withLock { $0.mic.count + $0.system.count }
            },
            stopGraphs: {
                lifecycle.withLock { $0.append("stop-graphs") }
                // Model a backend that attempts one last delivery from stop.
                // The callback disconnect must prevent a duplicate tail.
                mic.stopGraph(attemptedFinalSample: 11)
                system.stopGraph(attemptedFinalSample: 22)
            }
        )

        ownerQueue.sync {}
        #expect(result.owner.mic == [11])
        #expect(result.owner.system == [22])
        #expect(result.writer == 2)
        #expect(captured.withLock { $0.mic } == [11])
        #expect(captured.withLock { $0.system } == [22])
        #expect(lifecycle.withLock { $0 } == [
            "pause",
            "disconnect",
            "finalize-chunks",
            "finalize-writer",
            "stop-graphs",
        ])
    }

    @Test("stop and drain fences but does not await an in-flight context capture")
    func screenContextDrainFencesWithoutBlockingOnInFlightCapture() async {
        let gate = ScreenCaptureReleaseGate()
        let captureStarted = OSAllocatedUnfairLock(initialState: false)
        let captureCancelled = OSAllocatedUnfairLock(initialState: false)
        let collector = MeetingScreenContextCollector { _ in
            captureStarted.withLock { $0 = true }
            return await withTaskCancellationHandler {
                await gate.wait()
                return MeetingScreenContextCaptureSample(
                    timestamp: Date(timeIntervalSince1970: 1),
                    appName: "Late App",
                    contextText: "must not escape the stop boundary",
                    ocrCharCount: 0,
                    appContextCharCount: 33
                )
            } onCancel: {
                captureCancelled.withLock { $0 = true }
            }
        }

        await collector.startPeriodicCapture(interval: 60)
        #expect(await waitForCaptureBoundary { captureStarted.withLock { $0 } })

        let drainFinished = OSAllocatedUnfairLock(initialState: false)
        let drainTask = Task {
            let value = await collector.stopAndDrain()
            drainFinished.withLock { $0 = true }
            return value
        }
        #expect(await waitForCaptureBoundary { captureCancelled.withLock { $0 } })
        #expect(await waitForCaptureBoundary { drainFinished.withLock { $0 } })

        let drained = await drainTask.value
        #expect(drained.isEmpty)
        await gate.release()
        // Let the cancellation-ignoring operation return. Its obsolete
        // generation must still be unable to append after the first drain.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let secondDrain = await collector.stopAndDrain()
        #expect(secondDrain.isEmpty)
    }

    @Test("newest screen pause command wins when actor delivery is reordered")
    func newestScreenPauseCommandWins() async {
        let collector = MeetingScreenContextCollector { _ in nil }

        await collector.startPeriodicCapture(interval: 60)
        await collector.setPaused(false, commandGeneration: 2)
        await collector.setPaused(true, commandGeneration: 1)

        #expect(await collector.pausedStateForTesting() == false)
        // Stopping also cleans up the periodic task in this state-only test.
        let drained = await collector.stopAndDrain()
        #expect(drained.isEmpty)
    }
}

private final class StopBoundarySource: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler = OSAllocatedUnfairLock<((Int) -> Void)?>(initialState: nil)

    var onSample: ((Int) -> Void)? {
        get { handler.withLock { $0 } }
        set { handler.withLock { $0 = newValue } }
    }

    init(label: String) {
        queue = DispatchQueue(label: "MeetingCaptureStopBoundaryTests.\(label)")
    }

    func admit(_ value: Int) {
        queue.async { [handler] in
            handler.withLock { $0 }?(value)
        }
    }

    func pauseAndDrain() {
        queue.sync {}
    }

    func stopGraph(attemptedFinalSample value: Int) {
        handler.withLock { $0 }?(value)
    }
}

private actor ScreenCaptureReleaseGate {
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }

    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }
}

private func waitForCaptureBoundary(
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
