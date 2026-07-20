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

    @Test("meeting startup continues to the real start when microphone prewarm fails")
    func prewarmFailureDoesNotBlockMeetingStart() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        system.prepareError = NSError(
            domain: "AVFAudio",
            code: -10_868,
            userInfo: [NSLocalizedDescriptionKey: "Route is changing"]
        )
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        )

        let prewarmError = MeetingMicStartupPreflight.prepareBestEffort(recorder)
        try recorder.start()

        #expect(prewarmError != nil)
        #expect(system.prepareCalls == 1)
        #expect(system.startCalls == 1)
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

    @Test("typed child failure preserves the route wrapper's legacy callback")
    func typedFailureBridgesToLegacyCaller() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: appScoped
        )
        var deliveredError: Error?
        recorder.onRecordingFailed = { deliveredError = $0 }
        try recorder.start()
        system.onRawPCMSamples?([1])

        let input = StreamingMicInputSnapshot(
            requestedDeviceID: nil,
            actualDeviceID: 42,
            sampleRate: 16_000,
            channelCount: 1
        )
        let failure = StreamingMicCaptureFailure(
            generation: 9,
            reason: .inputConfigurationChanged,
            restartAttemptCount: 2,
            previousInput: input,
            message: "route restart failed"
        )

        appScoped.onCaptureEvent?(.failed(failure))
        #expect(deliveredError == nil)
        system.onCaptureEvent?(.failed(failure))

        #expect((deliveredError as NSError?)?.domain == "StreamingMicRecorder.Recovery")
        #expect(deliveredError?.localizedDescription == "route restart failed")
    }

    @Test("typed route consumer receives recovery and failure without legacy duplicates")
    func typedConsumerSuppressesLegacyDuplicate() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        )
        var events: [StreamingMicCaptureEvent] = []
        var legacyFailureCount = 0
        recorder.onCaptureEvent = { events.append($0) }
        recorder.onRecordingFailed = { _ in legacyFailureCount += 1 }
        try recorder.start()
        system.onRawPCMSamples?([1])

        let input = StreamingMicInputSnapshot(
            requestedDeviceID: nil,
            actualDeviceID: 42,
            sampleRate: 16_000,
            channelCount: 1
        )
        let discontinuity = StreamingMicDiscontinuity(
            generation: 10,
            reason: .inputConfigurationChanged,
            missingSampleCount: 160,
            downtimeSeconds: 0.01,
            restartAttemptCount: 1,
            previousInput: input,
            currentInput: input
        )
        let failure = StreamingMicCaptureFailure(
            generation: 11,
            reason: .inputConfigurationChanged,
            restartAttemptCount: 2,
            previousInput: input,
            message: "route restart failed"
        )

        system.onCaptureEvent?(.recovered(discontinuity))
        system.onCaptureEvent?(.failed(failure))

        #expect(events == [.recovered(discontinuity), .failed(failure)])
        #expect(legacyFailureCount == 0)
    }

    @Test("system to explicit handoff publishes recovery before admitting replacement samples")
    func systemToExplicitHandoffGatesFirstBuffer() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.system-to-explicit")
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let explicit = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: explicit,
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 5
        )
        var deliveryOrder: [String] = []
        var deliveredSamples: [[Int16]] = []
        var events: [StreamingMicCaptureEvent] = []
        recorder.onCaptureEvent = { event in
            events.append(event)
            deliveryOrder.append("event")
        }
        recorder.onRawPCMSamples = { samples in
            deliveredSamples.append(samples)
            deliveryOrder.append("samples")
        }

        try recorder.start()
        let staleSystemCallback = try #require(system.onRawPCMSamples)
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 1, preferredInputDeviceID: 82))
        drain(lifecycleQueue)

        staleSystemCallback([1, 2])
        #expect(deliveredSamples.isEmpty)
        #expect(events.isEmpty)

        explicit.onRawPCMSamples?([3, 4])

        #expect(deliveryOrder == ["event", "samples"])
        #expect(deliveredSamples == [[3, 4]])
        let recovery = try #require(events.first?.recovery)
        #expect(recovery.reason == .inputConfigurationChanged)
        #expect(recovery.previousInput.requestedDeviceID == nil)
        #expect(recovery.currentInput.requestedDeviceID == 82)
        #expect(recovery.currentInput.actualDeviceID == 82)
    }

    @Test("explicit device handoff creates a fresh child and rejects callbacks from the retired child")
    func explicitToExplicitHandoffUsesFreshChild() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.explicit-to-explicit")
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let firstExplicit = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let secondExplicit = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        var factoryCalls = 0
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: firstExplicit,
            appScopedRecorderFactory: {
                factoryCalls += 1
                return secondExplicit
            },
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 5
        )
        recorder.preferredInputDeviceID = 71
        var deliveredSamples: [[Int16]] = []
        var events: [StreamingMicCaptureEvent] = []
        recorder.onRawPCMSamples = { deliveredSamples.append($0) }
        recorder.onCaptureEvent = { events.append($0) }

        try recorder.start()
        let staleSamples = try #require(firstExplicit.onRawPCMSamples)
        let staleEvent = try #require(firstExplicit.onCaptureEvent)
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 1, preferredInputDeviceID: 72))
        drain(lifecycleQueue)

        #expect(factoryCalls == 1)
        #expect(firstExplicit.stopCalls == 1)
        #expect(firstExplicit.cancelCalls >= 1)
        #expect(secondExplicit.startCalls == 1)
        #expect(secondExplicit.preferredInputDeviceID == 72)

        staleSamples([7])
        staleEvent(.recovered(makeDiscontinuity(generation: 500, requestedDeviceID: 71)))
        #expect(deliveredSamples.isEmpty)
        #expect(events.isEmpty)

        secondExplicit.onRawPCMSamples?([8])
        #expect(deliveredSamples == [[8]])
        #expect(events.count == 1)
        #expect(events.first?.recovery?.currentInput.requestedDeviceID == 72)
    }

    @Test("rapid route changes coalesce to the newest device without bypassing first-buffer admission")
    func rapidRouteChangesUseLatestSelection() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.rapid-selection")
        let stopEntered = DispatchSemaphore(value: 0)
        let allowStop = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        system.stopEntered = stopEntered
        system.allowStop = allowStop
        var replacements: [FakeMeetingMicRecorder] = []
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorderFactory: {
                let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
                replacements.append(replacement)
                return replacement
            },
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 5
        )
        var deliveryOrder: [String] = []
        recorder.onCaptureEvent = { _ in deliveryOrder.append("event") }
        recorder.onRawPCMSamples = { _ in deliveryOrder.append("samples") }

        try recorder.start()
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 1, preferredInputDeviceID: 81))
        #expect(stopEntered.wait(timeout: .now() + 1) == .success)
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 2, preferredInputDeviceID: 82))
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 3, preferredInputDeviceID: 83))
        allowStop.signal()
        drain(lifecycleQueue)

        #expect(replacements.count == 1)
        let replacement = try #require(replacements.first)
        #expect(replacement.preferredInputDeviceID == 83)
        #expect(deliveryOrder.isEmpty)

        replacement.onRawPCMSamples?([83])
        #expect(deliveryOrder == ["event", "samples"])
    }

    @Test("stopping during a pending handoff rejects late replacement callbacks")
    func stopDuringPendingHandoffRejectsLateCallback() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.stop-pending")
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorder: replacement,
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 5
        )
        var deliveredSamples: [[Int16]] = []
        var events: [StreamingMicCaptureEvent] = []
        recorder.onRawPCMSamples = { deliveredSamples.append($0) }
        recorder.onCaptureEvent = { events.append($0) }

        try recorder.start()
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 1, preferredInputDeviceID: 92))
        drain(lifecycleQueue)
        let lateSamples = try #require(replacement.onRawPCMSamples)
        let lateEvent = try #require(replacement.onCaptureEvent)

        _ = recorder.stop()
        lateEvent(.recovered(makeDiscontinuity(generation: 1, requestedDeviceID: 92)))
        lateSamples([9, 2])

        #expect(replacement.stopCalls == 1)
        #expect(replacement.cancelCalls >= 1)
        #expect(deliveredSamples.isEmpty)
        #expect(events.isEmpty)
    }

    @Test("replacement first-buffer timeout reports a typed failure then falls back to automatic input")
    func replacementFirstBufferTimeoutFallsBackToSystemRecorder() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.timeout-fallback")
        let fallbackStarted = DispatchSemaphore(value: 0)
        let initialSystem = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let fallbackSystem = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        fallbackSystem.samplesOnStart = [10, 1]
        fallbackSystem.onStart = { fallbackStarted.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: initialSystem,
            appScopedRecorder: replacement,
            systemDefaultRecorderFactory: { fallbackSystem },
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 0.05
        )
        var events: [StreamingMicCaptureEvent] = []
        var deliveredSamples: [[Int16]] = []
        recorder.onCaptureEvent = { events.append($0) }
        recorder.onRawPCMSamples = { deliveredSamples.append($0) }

        try recorder.start()
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 1, preferredInputDeviceID: 101))
        drain(lifecycleQueue)
        #expect(fallbackStarted.wait(timeout: .now() + 1) == .success)
        drain(lifecycleQueue)

        #expect(replacement.stopCalls == 1)
        #expect(replacement.cancelCalls >= 1)
        let failure = try #require(events.first?.failure)
        #expect(failure.reason == .inputConfigurationChanged)
        #expect(failure.message.contains("produced no audio"))

        #expect(events.count == 2)
        #expect(events.last?.recovery?.currentInput.requestedDeviceID == nil)
        #expect(deliveredSamples == [[10, 1]])
    }

    @Test("initial explicit microphone is verified and falls back when it produces no buffer")
    func initialExplicitMicrophoneRequiresFirstBuffer() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.initial-proof")
        let fallbackStarted = DispatchSemaphore(value: 0)
        let explicit = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let fallbackSystem = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        fallbackSystem.samplesOnStart = [4, 2]
        fallbackSystem.onStart = { fallbackStarted.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: fallbackSystem,
            appScopedRecorder: explicit,
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 0.05
        )
        recorder.preferredInputDeviceID = 71
        var events: [StreamingMicCaptureEvent] = []
        var deliveredSamples: [[Int16]] = []
        recorder.onCaptureEvent = { events.append($0) }
        recorder.onRawPCMSamples = { deliveredSamples.append($0) }

        try recorder.start()
        #expect(deliveredSamples.isEmpty)
        #expect(fallbackStarted.wait(timeout: .now() + 1) == .success)
        drain(lifecycleQueue)

        #expect(explicit.stopCalls == 1)
        #expect(events.count == 2)
        #expect(events.first?.failure?.message.contains("produced no audio") == true)
        #expect(events.last?.recovery?.currentInput.requestedDeviceID == nil)
        #expect(deliveredSamples == [[4, 2]])
    }

    @Test("system-default timeout falls back to the built-in microphone")
    func systemDefaultTimeoutFallsBackToBuiltInMicrophone() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.system-timeout-fallback")
        let systemTarget = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let initialExplicit = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let builtInFallback = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let fallbackStarted = DispatchSemaphore(value: 0)
        builtInFallback.samplesOnStart = [8, 2]
        builtInFallback.onStart = { fallbackStarted.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: systemTarget,
            appScopedRecorder: initialExplicit,
            appScopedRecorderFactory: { builtInFallback },
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 0.05
        )
        recorder.preferredInputDeviceID = 71
        var events: [StreamingMicCaptureEvent] = []
        var deliveredSamples: [[Int16]] = []
        recorder.onCaptureEvent = { events.append($0) }
        recorder.onRawPCMSamples = { deliveredSamples.append($0) }

        try recorder.start()
        recorder.requestInputRouteChange(makeMeetingInputSelection(
            revision: 1,
            preferredInputDeviceID: nil,
            defaultInputDeviceID: 91,
            builtInInputDeviceID: 82
        ))
        drain(lifecycleQueue)
        #expect(fallbackStarted.wait(timeout: .now() + 1) == .success)
        drain(lifecycleQueue)

        #expect(systemTarget.stopCalls == 1)
        #expect(builtInFallback.preferredInputDeviceID == 82)
        #expect(events.count == 2)
        #expect(events.first?.failure != nil)
        #expect(events.last?.recovery?.currentInput.requestedDeviceID == 82)
        #expect(deliveredSamples == [[8, 2]])
    }

    @Test("exhausted fallback enters failed state and a new route can recover")
    func exhaustedFallbackCanRecoverOnNewRoute() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.exhausted-fallback")
        let explicit = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let fallbackSystem = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recoveredExplicit = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        recoveredExplicit.samplesOnStart = [12, 3]
        let failureReported = DispatchSemaphore(value: 0)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: fallbackSystem,
            appScopedRecorder: explicit,
            appScopedRecorderFactory: { recoveredExplicit },
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 0.02
        )
        recorder.preferredInputDeviceID = 71
        var deliveredSamples: [[Int16]] = []
        recorder.onCaptureEvent = { event in
            if event.failure != nil {
                failureReported.signal()
            }
        }
        recorder.onRawPCMSamples = { deliveredSamples.append($0) }

        try recorder.start()
        #expect(failureReported.wait(timeout: .now() + 1) == .success)
        #expect(failureReported.wait(timeout: .now() + 1) == .success)
        drain(lifecycleQueue)

        #expect(recorder.isTerminallyFailedForDebug())
        #expect(explicit.stopCalls == 1)
        #expect(fallbackSystem.stopCalls == 1)

        recorder.requestInputRouteChange(makeMeetingInputSelection(
            revision: 1,
            preferredInputDeviceID: 92
        ))
        drain(lifecycleQueue)

        #expect(!recorder.isTerminallyFailedForDebug())
        #expect(recoveredExplicit.startCalls == 1)
        #expect(deliveredSamples == [[12, 3]])
    }

    @Test("route selection while paused is deferred until resume")
    func pausedRouteSelectionIsDeferredUntilResume() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.paused-selection")
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let explicit = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: explicit,
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 5
        )
        var deliveryOrder: [String] = []
        recorder.onCaptureEvent = { _ in deliveryOrder.append("event") }
        recorder.onRawPCMSamples = { _ in deliveryOrder.append("samples") }

        try recorder.start()
        recorder.pause()
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 1, preferredInputDeviceID: 82))
        drain(lifecycleQueue)

        #expect(system.pauseCalls == 1)
        #expect(explicit.startCalls == 0)

        recorder.resume()
        drain(lifecycleQueue)

        #expect(system.stopCalls == 1)
        #expect(explicit.startCalls == 1)
        #expect(deliveryOrder.isEmpty)

        explicit.onRawPCMSamples?([8, 2])
        #expect(deliveryOrder == ["event", "samples"])
    }

    @Test("pause returns while an admitted callback finishes off the caller")
    func pauseDoesNotBlockOnCallbackDelivery() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.nonblocking-pause")
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 5
        )
        let deliveryEntered = DispatchSemaphore(value: 0)
        let allowDelivery = DispatchSemaphore(value: 0)
        let pauseReturned = DispatchSemaphore(value: 0)
        recorder.onRawPCMSamples = { _ in
            deliveryEntered.signal()
            _ = allowDelivery.wait(timeout: .now() + 1)
        }

        try recorder.start()
        DispatchQueue.global().async {
            system.onRawPCMSamples?([1, 2])
        }
        #expect(deliveryEntered.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            recorder.pause()
            pauseReturned.signal()
        }
        let returnedWithoutDraining = pauseReturned.wait(timeout: .now() + 0.2) == .success
        allowDelivery.signal()
        drain(lifecycleQueue)

        #expect(returnedWithoutDraining)
        #expect(system.pauseCalls == 1)
    }

    @Test("new selection while paused supersedes an awaiting fallback")
    func pausedSelectionSupersedesPendingFallback() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.paused-fallback")
        let initialSystem = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let failedExplicit = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        failedExplicit.startError = NSError(domain: "RouteAwareMeetingMicRecorderTests", code: 32)
        let pendingFallback = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let newestExplicit = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: initialSystem,
            appScopedRecorder: failedExplicit,
            systemDefaultRecorderFactory: { pendingFallback },
            appScopedRecorderFactory: { newestExplicit },
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 5
        )
        var deliveredSamples: [[Int16]] = []
        recorder.onRawPCMSamples = { deliveredSamples.append($0) }

        try recorder.start()
        initialSystem.onRawPCMSamples?([1])
        deliveredSamples.removeAll()
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 1, preferredInputDeviceID: 101))
        drain(lifecycleQueue)
        let staleFallbackCallback = try #require(pendingFallback.onRawPCMSamples)

        recorder.pause()
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 2, preferredInputDeviceID: 202))
        recorder.resume()
        drain(lifecycleQueue)

        #expect(pendingFallback.stopCalls == 1)
        #expect(newestExplicit.startCalls == 1)
        #expect(newestExplicit.preferredInputDeviceID == 202)

        staleFallbackCallback([101])
        #expect(deliveredSamples.isEmpty)
        newestExplicit.onRawPCMSamples?([202])
        #expect(deliveredSamples == [[202]])
    }

    @Test("replacement child events are remapped onto one monotonic meeting generation")
    func replacementChildEventsUseMonotonicGeneration() throws {
        let lifecycleQueue = DispatchQueue(label: "RouteAwareMeetingMicRecorderTests.monotonic-generation")
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            lifecycleQueue: lifecycleQueue,
            firstBufferTimeout: 5
        )
        var events: [StreamingMicCaptureEvent] = []
        recorder.onCaptureEvent = { events.append($0) }

        try recorder.start()
        system.onRawPCMSamples?([1])
        system.onCaptureEvent?(.recovered(makeDiscontinuity(generation: 50, requestedDeviceID: nil)))
        recorder.requestInputRouteChange(makeMeetingInputSelection(revision: 1, preferredInputDeviceID: 102))
        drain(lifecycleQueue)

        replacement.onCaptureEvent?(.recovered(makeDiscontinuity(generation: 2, requestedDeviceID: 102)))
        #expect(events.map(\.generation) == [50])
        replacement.onRawPCMSamples?([1])
        replacement.onCaptureEvent?(.recovered(makeDiscontinuity(generation: 1, requestedDeviceID: 102)))

        #expect(events.map(\.generation) == [50, 51, 52])
        #expect(events[1].recovery?.currentInput.requestedDeviceID == 102)
    }

    @Test("lifecycle delegates to active recorder and cancels inactive recorder on stop")
    func lifecycleDelegatesToActiveRecorderAndCancelsInactiveRecorderOnStop() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
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
        #expect(system.cancelCalls >= 1)
    }

    @Test("meeting adapter returns the recording then fully cools the child graph")
    func meetingAdapterCoolsChildGraphAfterStop() throws {
        let child = FakeStreamingMeetingRecorder()
        let expectedURL = URL(fileURLWithPath: "/tmp/meeting-mic.wav")
        child.stopURL = expectedURL
        let adapter = StreamingMeetingMicRecorderAdapter(
            recorder: child,
            kind: .systemDefaultStreaming
        )

        try adapter.start()
        let actualURL = adapter.stop()

        #expect(actualURL == expectedURL)
        #expect(child.stopCalls == 1)
        #expect(child.cancelCalls == 1)
        #expect(child.lifecycle == ["start", "stop", "cancel"])
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
}

private final class FakeStreamingMeetingRecorder: StreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?
    var stopURL: URL?
    var stopCalls = 0
    var cancelCalls = 0
    var lifecycle: [String] = []

    func prepare() throws {}

    func start() throws {
        lifecycle.append("start")
    }

    func stop() -> URL? {
        stopCalls += 1
        lifecycle.append("stop")
        return stopURL
    }

    func cancel() {
        cancelCalls += 1
        lifecycle.append("cancel")
    }

    func currentPower() -> Float { -160 }
}

private final class FakeMeetingMicRecorder: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onCaptureEvent: ((StreamingMicCaptureEvent) -> Void)?

    let kind: MeetingMicRecorderKind
    var prepareCalls = 0
    var startCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var prepareError: Error?
    var startError: Error?
    var stopEntered: DispatchSemaphore?
    var allowStop: DispatchSemaphore?
    var samplesOnStart: [Int16]?
    var onStart: (() -> Void)?

    init(kind: MeetingMicRecorderKind) {
        self.kind = kind
    }

    func prepare() throws {
        prepareCalls += 1
        if let prepareError {
            throw prepareError
        }
    }

    func start() throws {
        startCalls += 1
        if let startError {
            throw startError
        }
        if let samplesOnStart {
            onRawPCMSamples?(samplesOnStart)
        }
        onStart?()
    }

    func pause() {
        pauseCalls += 1
    }

    func resume() {
        resumeCalls += 1
    }

    func stop() -> URL? {
        stopCalls += 1
        stopEntered?.signal()
        if let allowStop {
            _ = allowStop.wait(timeout: .now() + 1)
        }
        return nil
    }

    func cancel() {
        cancelCalls += 1
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

private func drain(_ queue: DispatchQueue) {
    queue.sync {}
}

private func makeMeetingInputSelection(
    revision: UInt64,
    preferredInputDeviceID: AudioObjectID?,
    defaultInputDeviceID: AudioObjectID = 40,
    builtInInputDeviceID: AudioObjectID = 40
) -> MeetingInputRouteSelection {
    MeetingInputRouteSelection(
        revision: revision,
        preferredInputDeviceID: preferredInputDeviceID,
        routeSnapshot: MeetingMicRouteDiagnosticsSnapshot(
            outputRouteKind: "speaker-like",
            outputIsAmbiguousBluetooth: false,
            selectedInputDeviceUID: preferredInputDeviceID.map { "device-\($0)" },
            selectedInputDeviceResolved: true,
            preferredInputDeviceID: preferredInputDeviceID,
            preferredInputDeviceName: preferredInputDeviceID.map { "Microphone \($0)" },
            defaultInputDeviceID: defaultInputDeviceID,
            defaultInputDeviceName: "Default Microphone",
            builtInInputDeviceID: builtInInputDeviceID,
            systemDefaultInputIsBuiltIn: defaultInputDeviceID == builtInInputDeviceID
        )
    )
}

private func makeDiscontinuity(
    generation: UInt64,
    requestedDeviceID: AudioObjectID?
) -> StreamingMicDiscontinuity {
    let input = StreamingMicInputSnapshot(
        requestedDeviceID: requestedDeviceID,
        actualDeviceID: requestedDeviceID ?? 40,
        sampleRate: 16_000,
        channelCount: 1
    )
    return StreamingMicDiscontinuity(
        generation: generation,
        reason: .inputConfigurationChanged,
        missingSampleCount: 160,
        downtimeSeconds: 0.01,
        restartAttemptCount: 1,
        previousInput: input,
        currentInput: input
    )
}

private extension StreamingMicCaptureEvent {
    var generation: UInt64 {
        switch self {
        case .recovered(let discontinuity): discontinuity.generation
        case .failed(let failure): failure.generation
        }
    }

    var recovery: StreamingMicDiscontinuity? {
        guard case .recovered(let discontinuity) = self else { return nil }
        return discontinuity
    }

    var failure: StreamingMicCaptureFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}
