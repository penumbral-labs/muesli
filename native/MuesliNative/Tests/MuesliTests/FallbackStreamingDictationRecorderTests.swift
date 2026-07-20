import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("FallbackStreamingDictationRecorder")
struct FallbackStreamingDictationRecorderTests {
    @Test("prepare falls back when primary prepare fails")
    func prepareFallsBackWhenPrimaryPrepareFails() throws {
        let error = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 1)
        let primary = FakeFallbackStreamingRecorder()
        primary.prepareResults = [.failure(error)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        recorder.preferredInputDeviceID = 82
        var latencyEvents: [String] = []
        recorder.onLatencyEvent = { event, _ in latencyEvents.append(event) }

        try recorder.prepare()

        #expect(primary.prepareCalls == 1)
        #expect(primary.cancelCalls == 1)
        #expect(fallback.prepareCalls == 1)
        #expect(primary.preparedInputDeviceIDs == [82])
        #expect(fallback.preparedInputDeviceIDs == [82])
        #expect(latencyEvents.contains("streaming_recorder_primary_prepare_failed"))
        #expect(latencyEvents.contains("streaming_recorder_selected slot=fallback recorder=FakeFallbackStreamingRecorder preferredInput=82"))
        #expect(latencyEvents.contains("streaming_recorder_fallback_prepare_end"))
    }

    @Test("prepare emits selected primary recorder latency event")
    func prepareEmitsSelectedPrimaryRecorderLatencyEvent() throws {
        let primary = FakeFallbackStreamingRecorder()
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        var latencyEvents: [String] = []
        recorder.onLatencyEvent = { event, _ in latencyEvents.append(event) }

        try recorder.prepare()

        #expect(latencyEvents == [
            "streaming_recorder_selected slot=primary recorder=FakeFallbackStreamingRecorder preferredInput=default",
        ])
    }

    @Test("start falls back when prepared primary start fails")
    func startFallsBackWhenPreparedPrimaryStartFails() throws {
        let error = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 2)
        let primary = FakeFallbackStreamingRecorder()
        primary.startResults = [.failure(error)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        recorder.preferredInputDeviceID = 82

        try recorder.prepare()
        try recorder.start()

        #expect(primary.prepareCalls == 1)
        #expect(primary.startCalls == 1)
        #expect(primary.cancelCalls == 1)
        #expect(fallback.prepareCalls == 1)
        #expect(fallback.startCalls == 1)
        #expect(fallback.startedInputDeviceID == 82)
    }

    @Test("fallback start failure cleans up fallback recorder")
    func fallbackStartFailureCleansUpFallbackRecorder() throws {
        let primaryError = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 20)
        let fallbackError = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 21)
        let primary = FakeFallbackStreamingRecorder()
        primary.startResults = [.failure(primaryError)]
        let fallback = FakeFallbackStreamingRecorder()
        fallback.startResults = [.failure(fallbackError)]
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)

        try recorder.prepare()
        #expect(throws: Error.self) {
            try recorder.start()
        }

        #expect(primary.cancelCalls == 1)
        #expect(fallback.prepareCalls == 1)
        #expect(fallback.startCalls == 1)
        #expect(fallback.cancelCalls == 1)
    }

    @Test("callbacks are rewired after child cancel")
    func callbacksAreRewiredAfterChildCancel() throws {
        let error = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 4)
        let primary = FakeFallbackStreamingRecorder()
        primary.startResults = [.failure(error)]
        let fallback = FakeFallbackStreamingRecorder()
        fallback.clearsCallbacksOnCancel = true
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        var bufferCount = 0
        recorder.onAudioBuffer = { _ in bufferCount += 1 }

        recorder.cancel()
        try recorder.prepare()
        try recorder.start()
        fallback.onAudioBuffer?([0.3])

        #expect(fallback.cancelCalls == 1)
        #expect(fallback.startCalls == 1)
        #expect(bufferCount == 1)
    }

    @Test("callbacks from inactive recorder are ignored after fallback")
    func callbacksFromInactiveRecorderAreIgnoredAfterFallback() throws {
        let error = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 3)
        let primary = FakeFallbackStreamingRecorder()
        primary.prepareResults = [.failure(error)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        var bufferCount = 0
        var failureCount = 0
        recorder.onAudioBuffer = { _ in bufferCount += 1 }
        recorder.onRecordingFailed = { _ in failureCount += 1 }

        try recorder.prepare()
        primary.onAudioBuffer?([0.1])
        primary.onRecordingFailed?(error)
        fallback.onAudioBuffer?([0.2])

        #expect(bufferCount == 1)
        #expect(failureCount == 0)
    }

    @Test("capture recovery events and diagnostics follow the selected recorder")
    func captureRecoveryFollowsSelectedRecorder() throws {
        let prepareError = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 30)
        let primary = FakeFallbackStreamingRecorder()
        primary.prepareResults = [.failure(prepareError)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        var events: [StreamingMicCaptureEvent] = []
        recorder.onCaptureEvent = { events.append($0) }

        try recorder.prepare()
        let input = StreamingMicInputSnapshot(
            requestedDeviceID: nil,
            actualDeviceID: 42,
            sampleRate: 16_000,
            channelCount: 1
        )
        let discontinuity = StreamingMicDiscontinuity(
            generation: 1,
            reason: .inputConfigurationChanged,
            missingSampleCount: 320,
            downtimeSeconds: 0.02,
            restartAttemptCount: 1,
            previousInput: input,
            currentInput: input
        )
        fallback.recoveryDiagnostics = StreamingMicRecoveryDiagnosticsSnapshot(
            configurationChangeCount: 1,
            coalescedConfigurationChangeCount: 0,
            graphRestartAttemptCount: 1,
            successfulRecoveryCount: 1,
            failedRecoveryCount: 0,
            discontinuities: [discontinuity],
            failures: []
        )

        primary.onCaptureEvent?(.recovered(discontinuity))
        fallback.onCaptureEvent?(.recovered(discontinuity))

        #expect(events == [.recovered(discontinuity)])
        #expect(recorder.captureRecoveryDiagnostics == fallback.recoveryDiagnostics)
    }

    @Test("typed fallback failures preserve the legacy failure callback")
    func typedFailureBridgesToLegacyCaller() throws {
        let prepareError = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 31)
        let primary = FakeFallbackStreamingRecorder()
        primary.prepareResults = [.failure(prepareError)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        var deliveredError: Error?
        recorder.onRecordingFailed = { deliveredError = $0 }

        try recorder.prepare()
        let input = StreamingMicInputSnapshot(
            requestedDeviceID: nil,
            actualDeviceID: 42,
            sampleRate: 16_000,
            channelCount: 1
        )
        let failure = StreamingMicCaptureFailure(
            generation: 7,
            reason: .inputConfigurationChanged,
            restartAttemptCount: 2,
            previousInput: input,
            message: "replacement graph failed"
        )

        fallback.onCaptureEvent?(.failed(failure))

        #expect((deliveredError as NSError?)?.domain == "StreamingMicRecorder.Recovery")
        #expect(deliveredError?.localizedDescription == "replacement graph failed")
    }

    @Test("typed capture consumers receive each event without duplicate legacy failures")
    func typedConsumerSuppressesLegacyDuplicate() throws {
        let primary = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(
            primary: primary,
            fallback: FakeFallbackStreamingRecorder()
        )
        var events: [StreamingMicCaptureEvent] = []
        var legacyFailureCount = 0
        recorder.onCaptureEvent = { events.append($0) }
        recorder.onRecordingFailed = { _ in legacyFailureCount += 1 }
        try recorder.prepare()

        let (recovered, failed) = captureEvents()
        primary.onCaptureEvent?(recovered)
        primary.onCaptureEvent?(failed)

        #expect(events == [recovered, failed])
        #expect(legacyFailureCount == 0)
    }

    @Test("nested route adapter and fallback chain delivers typed events exactly once")
    func nestedTypedCaptureChainIsExactlyOnce() throws {
        let selectedChild = FakeFallbackStreamingRecorder()
        let fallback = FallbackStreamingDictationRecorder(
            primary: selectedChild,
            fallback: FakeFallbackStreamingRecorder()
        )
        let selectedAdapter = StreamingMeetingMicRecorderAdapter(
            recorder: fallback,
            kind: .systemDefaultStreaming
        )
        let inactiveChild = FakeFallbackStreamingRecorder()
        let inactiveAdapter = StreamingMeetingMicRecorderAdapter(
            recorder: inactiveChild,
            kind: .appScopedAudioQueue
        )
        let route = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: selectedAdapter,
            appScopedRecorder: inactiveAdapter
        )
        var events: [StreamingMicCaptureEvent] = []
        var legacyFailureCount = 0
        route.onCaptureEvent = { events.append($0) }
        route.onRecordingFailed = { _ in legacyFailureCount += 1 }
        try route.start()
        selectedChild.onAudioBuffer?([0.1])

        let (_, failure) = captureEvents()
        inactiveChild.onCaptureEvent?(failure)
        selectedChild.onCaptureEvent?(failure)

        #expect(events == [failure])
        #expect(legacyFailureCount == 0)
    }

    @Test("pause and resume delegate to active recorder")
    func pauseAndResumeDelegateToActiveRecorder() throws {
        let error = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 5)
        let primary = FakeFallbackStreamingRecorder()
        primary.prepareResults = [.failure(error)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)

        try recorder.prepare()
        recorder.pause()
        recorder.resume()

        #expect(primary.pauseCalls == 0)
        #expect(primary.resumeCalls == 0)
        #expect(fallback.pauseCalls == 1)
        #expect(fallback.resumeCalls == 1)
    }

    @Test("child start can synchronously wait for a forwarded callback")
    func childStartDoesNotRunUnderWrapperLock() throws {
        let primary = FakeFallbackStreamingRecorder()
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        let callbackReturned = DispatchSemaphore(value: 0)
        var deliveredBufferCount = 0
        recorder.onAudioBuffer = { _ in
            deliveredBufferCount += 1
        }
        primary.onStartStarted = {
            DispatchQueue.global(qos: .userInitiated).async {
                primary.onAudioBuffer?([0.25])
                callbackReturned.signal()
            }
            guard callbackReturned.wait(timeout: .now() + 1) == .success else {
                throw NSError(
                    domain: "FallbackStreamingDictationRecorderTests.CallbackRoundTrip",
                    code: 1
                )
            }
        }

        try recorder.prepare()
        try recorder.start()

        #expect(primary.startCalls == 1)
        #expect(fallback.startCalls == 0)
        #expect(deliveredBufferCount == 1)
    }

    @Test("child prepare can synchronously wait for a forwarded callback")
    func childPrepareDoesNotRunUnderWrapperLock() throws {
        let primary = FakeFallbackStreamingRecorder()
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        let callbackReturned = DispatchSemaphore(value: 0)
        var deliveredBufferCount = 0
        recorder.onAudioBuffer = { _ in
            deliveredBufferCount += 1
        }
        primary.onPrepareStarted = {
            DispatchQueue.global(qos: .userInitiated).async {
                primary.onAudioBuffer?([0.125])
                callbackReturned.signal()
            }
            guard callbackReturned.wait(timeout: .now() + 1) == .success else {
                throw NSError(
                    domain: "FallbackStreamingDictationRecorderTests.CallbackRoundTrip",
                    code: 2
                )
            }
        }

        try recorder.prepare()

        #expect(primary.prepareCalls == 1)
        #expect(fallback.prepareCalls == 0)
        #expect(deliveredBufferCount == 1)
    }

    @Test("child cancel can synchronously wait for a forwarded callback")
    func childCancelDoesNotRunUnderWrapperLock() throws {
        let prepareError = NSError(domain: "FallbackStreamingDictationRecorderTests", code: 40)
        let primary = FakeFallbackStreamingRecorder()
        primary.prepareResults = [.failure(prepareError)]
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        let callbackReturned = DispatchSemaphore(value: 0)
        recorder.onAudioBuffer = { _ in }
        primary.onCancel = {
            DispatchQueue.global(qos: .userInitiated).async {
                primary.onAudioBuffer?([0.5])
                callbackReturned.signal()
            }
            return callbackReturned.wait(timeout: .now() + 1) == .success
        }

        try recorder.prepare()

        #expect(primary.cancelCallbackRoundTripSucceeded == true)
        #expect(fallback.prepareCalls == 1)
    }

    @Test("cancel interrupts blocked startup without starting fallback")
    func cancelInterruptsBlockedStartupWithoutFallback() throws {
        let primary = FakeFallbackStreamingRecorder()
        let fallback = FakeFallbackStreamingRecorder()
        let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)
        let startEntered = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)
        let startReturned = DispatchSemaphore(value: 0)
        primary.onStartStarted = {
            startEntered.signal()
            releaseStart.wait()
        }

        try recorder.prepare()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? recorder.start()
            startReturned.signal()
        }

        #expect(startEntered.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global(qos: .userInitiated).async {
            recorder.cancel()
            cancelReturned.signal()
        }

        #expect(cancelReturned.wait(timeout: .now() + 1) == .success)
        #expect(startReturned.wait(timeout: .now() + 0.05) == .timedOut)
        releaseStart.signal()
        #expect(startReturned.wait(timeout: .now() + 1) == .success)
        #expect(fallback.prepareCalls == 0)
        #expect(fallback.startCalls == 0)
        #expect(primary.cancelCalls >= 1)
    }


    private func captureEvents() -> (StreamingMicCaptureEvent, StreamingMicCaptureEvent) {
        let input = StreamingMicInputSnapshot(
            requestedDeviceID: nil,
            actualDeviceID: 42,
            sampleRate: 16_000,
            channelCount: 1
        )
        let discontinuity = StreamingMicDiscontinuity(
            generation: 11,
            reason: .inputConfigurationChanged,
            missingSampleCount: 160,
            downtimeSeconds: 0.01,
            restartAttemptCount: 1,
            previousInput: input,
            currentInput: input
        )
        let failure = StreamingMicCaptureFailure(
            generation: 12,
            reason: .inputConfigurationChanged,
            restartAttemptCount: 2,
            previousInput: input,
            message: "replacement graph failed"
        )
        return (.recovered(discontinuity), .failed(failure))
    }
}

private final class FakeFallbackStreamingRecorder: StreamingDictationRecording, PausableStreamingDictationRecording, StreamingMicCaptureEventReporting {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onCaptureEvent: ((StreamingMicCaptureEvent) -> Void)?
    var recoveryDiagnostics = StreamingMicRecoveryDiagnosticsSnapshot.empty
    var captureRecoveryDiagnostics: StreamingMicRecoveryDiagnosticsSnapshot { recoveryDiagnostics }
    var preferredInputDeviceID: AudioObjectID?

    var prepareResults: [Result<Void, Error>] = []
    var startResults: [Result<Void, Error>] = []
    var preparedInputDeviceIDs: [AudioObjectID?] = []
    var startedInputDeviceID: AudioObjectID?
    var prepareCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var clearsCallbacksOnCancel = false
    var onPrepareStarted: (() throws -> Void)?
    var onStartStarted: (() throws -> Void)?
    var onCancel: (() -> Bool)?
    var cancelCallbackRoundTripSucceeded: Bool?

    func prepare() throws {
        prepareCalls += 1
        preparedInputDeviceIDs.append(preferredInputDeviceID)
        try onPrepareStarted?()
        if !prepareResults.isEmpty {
            try prepareResults.removeFirst().get()
        }
    }

    func start() throws {
        startCalls += 1
        startedInputDeviceID = preferredInputDeviceID
        try onStartStarted?()
        if !startResults.isEmpty {
            try startResults.removeFirst().get()
        }
    }

    func stop() -> URL? {
        stopCalls += 1
        return nil
    }

    func cancel() {
        cancelCalls += 1
        cancelCallbackRoundTripSucceeded = onCancel?()
        if clearsCallbacksOnCancel {
            onAudioBuffer = nil
            onRecordingFailed = nil
        }
    }

    func pause() {
        pauseCalls += 1
    }

    func resume() {
        resumeCalls += 1
    }

    func currentPower() -> Float {
        -160
    }
}
