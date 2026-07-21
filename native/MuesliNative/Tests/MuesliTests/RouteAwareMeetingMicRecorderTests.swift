import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("RouteAwareMeetingMicRecorder")
struct RouteAwareMeetingMicRecorderTests {
    @Test("default input uses system default recorder")
    func defaultInputUsesSystemDefaultRecorder() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        try recorder.prepare()
        try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.prepareCalls == 1)
        #expect(system.startCalls == 1)
        #expect(appScoped.prepareCalls == 0)
        #expect(appScoped.startCalls == 0)
    }

    @Test("preferred input uses app scoped recorder")
    func preferredInputUsesAppScopedRecorder() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        recorder.preferredInputDeviceID = 82
        try recorder.prepare()
        try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(system.prepareCalls == 0)
        #expect(system.startCalls == 0)
        #expect(appScoped.prepareCalls == 1)
        #expect(appScoped.startCalls == 1)
        #expect(appScoped.preferredInputDeviceID == 82)
    }

    @Test("callbacks from inactive recorder are ignored")
    func callbacksFromInactiveRecorderAreIgnored() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)
        var forwardedSamples: [[Int16]] = []
        var failureCount = 0
        recorder.onRawPCMSamples = { forwardedSamples.append($0) }
        recorder.onRecordingFailed = { _ in failureCount += 1 }

        try recorder.start()
        appScoped.onRawPCMSamples?([1, 2, 3])
        appScoped.onRecordingFailed?(NSError(domain: "RouteAwareMeetingMicRecorderTests", code: 1))
        system.onRawPCMSamples?([4, 5])

        #expect(forwardedSamples == [[4, 5]])
        #expect(failureCount == 0)
    }

    @Test("lifecycle delegates to active recorder and cancels inactive recorder on stop")
    func lifecycleDelegatesToActiveRecorderAndCancelsInactiveRecorderOnStop() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let inactiveCancelled = DispatchSemaphore(value: 0)
        system.onCancel = { inactiveCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)
        recorder.preferredInputDeviceID = 91

        try recorder.start()
        recorder.pause()
        recorder.resume()
        _ = recorder.stop()

        #expect(appScoped.startCalls == 1)
        #expect(appScoped.pauseCalls == 1)
        #expect(appScoped.resumeCalls == 1)
        #expect(appScoped.stopCalls == 1)
        #expect(inactiveCancelled.wait(timeout: .now() + 1) == .success)
    }

    @Test("diagnostics include active recorder kind and route snapshot")
    func diagnosticsIncludeActiveRecorderKindAndRouteSnapshot() throws {
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let route = MeetingMicRouteDiagnosticsSnapshot(
            outputRouteKind: "headphone-like",
            outputIsAmbiguousBluetooth: false,
            selectedInputDeviceUID: "built-in",
            selectedInputDeviceResolved: true,
            preferredInputDeviceID: 82,
            preferredInputDeviceName: "MacBook Microphone",
            defaultInputDeviceID: 90,
            defaultInputDeviceName: "Headset Mic",
            builtInInputDeviceID: 82,
            systemDefaultInputIsBuiltIn: false
        )
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorder: appScoped,
            routeSnapshotProvider: { route }
        )
        recorder.preferredInputDeviceID = 82
        try recorder.start()

        let diagnostics = recorder.diagnosticsSnapshot()

        #expect(diagnostics.recorderKind == .appScopedAudioQueue)
        #expect(diagnostics.preferredInputDeviceID == 82)
        #expect(diagnostics.route == route)
    }

    @Test("live route change keeps old recorder until replacement produces audio")
    func liveRouteChangeWaitsForFirstBuffer() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: appScoped,
            handoffTimeout: 1
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { appScoped.startCalls == 1 }

        system.onRawPCMSamples?([1])
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.stopCalls == 0)

        appScoped.onRawPCMSamples?([2])
        try await waitUntil { recorder.activeRecorderKindForDebug() == .appScoped }

        #expect(samples == [[1], [2]])
        #expect(system.stopCalls == 1)
        #expect(system.cancelCalls == 1)
    }

    @Test("failed live route change preserves current capture")
    func failedLiveRouteChangePreservesCurrentCapture() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        appScoped.startError = NSError(domain: "test", code: 1)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: appScoped,
            handoffTimeout: 1
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { appScoped.cancelCalls == 1 }
        system.onRawPCMSamples?([7])

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.stopCalls == 0)
        #expect(samples == [[7]])
    }

    @Test("active recorder failure rebuilds the same route and recovers on first buffer")
    func activeFailureRebuildsSameRoute() async throws {
        let failed = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: failed,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            systemDefaultRecorderFactory: { replacement },
            handoffTimeout: 1
        )
        var failures = 0
        var samples: [[Int16]] = []
        recorder.onRecordingFailed = { _ in failures += 1 }
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        failed.onRecordingFailed?(NSError(domain: "test", code: 2))

        try await waitUntil { replacement.startCalls == 1 }
        #expect(recorder.isTerminallyFailedForDebug())
        #expect(failures == 1)

        replacement.onRawPCMSamples?([8, 9])
        try await waitUntil { !recorder.isTerminallyFailedForDebug() }

        #expect(samples == [[8, 9]])
        #expect(failed.stopCalls == 1)
    }

    @Test("same route can retry after a terminal recovery failure")
    func sameRouteRetriesAfterTerminalFailure() async throws {
        let initial = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let failedReplacement = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        failedReplacement.startError = NSError(domain: "test", code: 3)
        let recoveredReplacement = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        var replacements = [failedReplacement, recoveredReplacement]
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: initial,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            systemDefaultRecorderFactory: { replacements.removeFirst() },
            handoffTimeout: 1
        )

        try recorder.start()
        initial.onRecordingFailed?(NSError(domain: "test", code: 2))
        try await waitUntil { failedReplacement.cancelCalls == 1 }

        #expect(recorder.isTerminallyFailedForDebug())
        recorder.preferredInputDeviceID = nil
        try await waitUntil { recoveredReplacement.startCalls == 1 }
        recoveredReplacement.onRawPCMSamples?([3, 2, 0])
        try await waitUntil { !recorder.isTerminallyFailedForDebug() }

        #expect(recoveredReplacement.startCalls == 1)
        #expect(initial.stopCalls == 1)
    }

    @Test("discard returns while a replacement start is blocked")
    func discardDoesNotWaitForBlockedReplacementStart() throws {
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 2)
        }
        replacement.onCancel = { replacementCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            handoffTimeout: 1
        )
        var deliveredSamples: [[Int16]] = []
        recorder.onRawPCMSamples = { deliveredSamples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        #expect(startEntered.wait(timeout: .now() + 1) == .success)

        let startedAt = Date()
        recorder.cancel()
        let elapsed = Date().timeIntervalSince(startedAt)
        allowStart.signal()

        #expect(elapsed < 0.2)
        #expect(replacementCancelled.wait(timeout: .now() + 1) == .success)
        replacement.onRawPCMSamples?([4, 2])
        #expect(deliveredSamples.isEmpty)
    }

    @Test("stop returns while a replacement start is blocked")
    func stopDoesNotWaitForBlockedReplacementStart() throws {
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 2)
        }
        replacement.onCancel = { replacementCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            handoffTimeout: 1
        )

        try recorder.start()
        recorder.preferredInputDeviceID = 93
        #expect(startEntered.wait(timeout: .now() + 1) == .success)

        let startedAt = Date()
        _ = recorder.stop()
        let elapsed = Date().timeIntervalSince(startedAt)
        allowStart.signal()

        #expect(elapsed < 0.2)
        #expect(system.stopCalls == 1)
        #expect(replacementCancelled.wait(timeout: .now() + 1) == .success)
    }

    @Test("handoff timeout runs while replacement start is blocked")
    func handoffTimeoutBoundsBlockedReplacementStart() throws {
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 2)
        }
        replacement.onCancel = { replacementCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            handoffTimeout: 0.05
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 92
        #expect(startEntered.wait(timeout: .now() + 1) == .success)
        #expect(replacementCancelled.wait(timeout: .now() + 1) == .success)

        system.onRawPCMSamples?([7])
        allowStart.signal()
        replacement.onRawPCMSamples?([9])

        #expect(samples == [[7]])
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for asynchronous recorder state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class FakeMeetingMicRecorder: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?

    let kind: MeetingMicRecorderKind
    var prepareCalls = 0
    var startCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var startError: Error?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?

    init(kind: MeetingMicRecorderKind) {
        self.kind = kind
    }

    func prepare() throws {
        prepareCalls += 1
    }

    func start() throws {
        startCalls += 1
        onStart?()
        if let startError { throw startError }
    }

    func pause() {
        pauseCalls += 1
    }

    func resume() {
        resumeCalls += 1
    }

    func stop() -> URL? {
        stopCalls += 1
        return nil
    }

    func cancel() {
        cancelCalls += 1
        onCancel?()
    }

    func currentPower() -> Float {
        -80
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: kind,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
    }
}
