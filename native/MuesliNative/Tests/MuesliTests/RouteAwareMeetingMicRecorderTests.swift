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

    init(kind: MeetingMicRecorderKind) {
        self.kind = kind
    }

    func prepare() throws {
        prepareCalls += 1
    }

    func start() throws {
        startCalls += 1
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
