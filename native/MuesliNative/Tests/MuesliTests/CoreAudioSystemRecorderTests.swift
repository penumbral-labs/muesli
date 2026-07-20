import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("CoreAudioSystemRecorder")
struct CoreAudioSystemRecorderTests {
    @Test("pause rejects IO admitted before the boundary after resume")
    func pauseEpochRejectsPrePauseTicketAfterResume() throws {
        var state = CoreAudioCaptureAdmissionState()
        state.activateCapture()
        let graph = state.beginGraph()
        let oldTicket = try #require(state.ticket(forGraph: graph))

        let didPause = state.pause()
        #expect(didPause)
        state.resume()

        #expect(!state.accepts(oldTicket))
        #expect(state.ticket(forGraph: graph) != nil)
    }

    @Test("graph replacement and stop reject callbacks from retired IOProcs")
    func graphGenerationFencesRetiredCallbacks() throws {
        var state = CoreAudioCaptureAdmissionState()
        state.activateCapture()
        let oldGraph = state.beginGraph()
        let oldTicket = try #require(state.ticket(forGraph: oldGraph))

        let replacementGraph = state.beginGraph()
        #expect(!state.accepts(oldTicket))
        let replacementTicket = try #require(state.ticket(forGraph: replacementGraph))
        #expect(state.accepts(replacementTicket))

        state.endCapture()
        #expect(!state.accepts(replacementTicket))
        #expect(state.ticket(forGraph: replacementGraph) == nil)
    }


    @Test("global tap description captures process mix except Muesli")
    func globalTapDescriptionExcludesSelfAudio() {
        let tapDescription = CoreAudioSystemRecorder.makeGlobalTapDescription(
            excludingProcessID: 123,
            name: "Muesli Global Test Tap"
        )

        #expect(tapDescription.name == "Muesli Global Test Tap")
        #expect(tapDescription.deviceUID == nil)
        #expect(tapDescription.stream == nil)
        #expect(tapDescription.processes == [123])
        #expect(tapDescription.isPrivate)
        #expect(tapDescription.muteBehavior == .unmuted)
    }

    @Test("aggregate device description includes tap with drift compensation")
    func aggregateDeviceDescriptionIncludesTap() throws {
        let description = CoreAudioSystemRecorder.makeAggregateDeviceDescription(
            tapUID: "tap-uid",
            aggregateUID: "aggregate-uid"
        )

        #expect(description[kAudioAggregateDeviceNameKey] as? String == "Muesli System Audio")
        #expect(description[kAudioAggregateDeviceUIDKey] as? String == "aggregate-uid")
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)

        let taps = try #require(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        let tap = try #require(taps.first)
        #expect(tap[kAudioSubTapUIDKey] as? String == "tap-uid")
        #expect(tap[kAudioSubTapDriftCompensationKey] as? Bool == true)
    }
}
