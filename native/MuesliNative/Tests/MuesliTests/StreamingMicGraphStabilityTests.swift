import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("Streaming microphone graph stability")
struct StreamingMicGraphStabilityTests {
    @Test("transient and stale formats cannot authorize an AirPods restart")
    func transientAndStaleFormatsWaitForTwoStableObservations() {
        var gate = StreamingMicRouteStabilityGate()

        #expect(gate.observe(route(deviceID: 10, sampleRate: 48_000)) == .waiting(
            "Waiting for the microphone route to remain stable"
        ))
        #expect(gate.observe(route(
            deviceID: nil,
            sampleRate: 0,
            channels: 0,
            available: false
        )) == .waiting("The audio engine has no current input device"))
        #expect(gate.observe(route(
            deviceID: 20,
            sampleRate: 24_000,
            outputSampleRate: 48_000,
            nominalSampleRate: 24_000
        )) == .waiting("The microphone hardware and tap formats have not settled"))

        let settledAirPods = route(
            deviceID: 20,
            sampleRate: 24_000,
            nominalSampleRate: 24_000
        )
        #expect(gate.observe(settledAirPods) == .waiting(
            "Waiting for the microphone route to remain stable"
        ))
        #expect(gate.observe(settledAirPods) == .ready(settledAirPods))
    }

    @Test("any device or format movement resets the matching observation count")
    func routeMovementResetsSettlement() {
        var gate = StreamingMicRouteStabilityGate()
        let builtIn = route(deviceID: 10, sampleRate: 48_000)
        let airPods = route(deviceID: 20, sampleRate: 24_000, nominalSampleRate: 24_000)

        _ = gate.observe(builtIn)
        #expect(gate.observe(airPods) == .waiting(
            "Waiting for the microphone route to remain stable"
        ))
        #expect(gate.observe(airPods) == .ready(airPods))
    }

    @Test("a new engine generation cannot inherit an earlier stable decision")
    func freshGraphRequiresFreshSettlementProof() {
        let airPods = route(deviceID: 20, sampleRate: 24_000, nominalSampleRate: 24_000)
        var retiredGraphGate = StreamingMicRouteStabilityGate()
        _ = retiredGraphGate.observe(airPods)
        #expect(retiredGraphGate.observe(airPods) == .ready(airPods))

        var replacementGraphGate = StreamingMicRouteStabilityGate()
        #expect(replacementGraphGate.observe(airPods) == .waiting(
            "Waiting for the microphone route to remain stable"
        ))
    }

    @Test("a graph on the old microphone cannot settle after the default changes")
    func actualDeviceMustFollowIntendedRoute() {
        var gate = StreamingMicRouteStabilityGate()
        let staleBuiltIn = StreamingMicRouteFingerprint(
            requestedDeviceID: nil,
            defaultInputDeviceID: 20,
            actualDeviceID: 10,
            actualDeviceIsAvailable: true,
            actualDeviceIsSystemDefaultAggregate: false,
            actualNominalSampleRate: 48_000,
            inputFormat: StreamingMicAudioFormatFingerprint(sampleRate: 48_000),
            outputFormat: StreamingMicAudioFormatFingerprint(sampleRate: 48_000)
        )
        #expect(gate.observe(staleBuiltIn) == .waiting(
            "The audio engine has not switched to the system default microphone"
        ))

        let defaultAggregate = StreamingMicRouteFingerprint(
            requestedDeviceID: nil,
            defaultInputDeviceID: 20,
            actualDeviceID: 21,
            actualDeviceIsAvailable: true,
            actualDeviceIsSystemDefaultAggregate: true,
            actualNominalSampleRate: 24_000,
            inputFormat: StreamingMicAudioFormatFingerprint(sampleRate: 24_000),
            outputFormat: StreamingMicAudioFormatFingerprint(sampleRate: 24_000)
        )
        #expect(gate.observe(defaultAggregate) == .waiting(
            "Waiting for the microphone route to remain stable"
        ))
        #expect(gate.observe(defaultAggregate) == .ready(defaultAggregate))
    }

    @Test("an explicit microphone selection must bind to that exact device")
    func explicitSelectionCannotSettleOnFallbackDevice() {
        var gate = StreamingMicRouteStabilityGate()
        let fallback = StreamingMicRouteFingerprint(
            requestedDeviceID: 20,
            defaultInputDeviceID: 10,
            actualDeviceID: 10,
            actualDeviceIsAvailable: true,
            actualDeviceIsSystemDefaultAggregate: false,
            actualNominalSampleRate: 48_000,
            inputFormat: StreamingMicAudioFormatFingerprint(sampleRate: 48_000),
            outputFormat: StreamingMicAudioFormatFingerprint(sampleRate: 48_000)
        )
        #expect(gate.observe(fallback) == .waiting(
            "The audio engine has not switched to the selected microphone"
        ))
    }

    private func route(
        deviceID: AudioObjectID?,
        sampleRate: Double,
        outputSampleRate: Double? = nil,
        channels: UInt32 = 1,
        available: Bool = true,
        nominalSampleRate: Double? = 48_000
    ) -> StreamingMicRouteFingerprint {
        StreamingMicRouteFingerprint(
            requestedDeviceID: nil,
            defaultInputDeviceID: deviceID,
            actualDeviceID: deviceID,
            actualDeviceIsAvailable: available,
            actualDeviceIsSystemDefaultAggregate: false,
            actualNominalSampleRate: nominalSampleRate,
            inputFormat: StreamingMicAudioFormatFingerprint(
                sampleRate: sampleRate,
                channelsPerFrame: channels
            ),
            outputFormat: StreamingMicAudioFormatFingerprint(
                sampleRate: outputSampleRate ?? sampleRate,
                channelsPerFrame: channels
            )
        )
    }
}
