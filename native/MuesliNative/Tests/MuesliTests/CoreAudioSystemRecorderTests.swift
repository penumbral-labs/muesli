import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("CoreAudioSystemRecorder")
struct CoreAudioSystemRecorderTests {

    @Test("device tap description excludes Muesli process audio")
    func deviceTapDescriptionExcludesSelfAudio() {
        let tapDescription = CoreAudioSystemRecorder.makeOutputDeviceTapDescription(
            deviceUID: "test-output-device",
            excludingProcessID: 123,
            name: "Muesli Test Tap"
        )

        #expect(tapDescription.name == "Muesli Test Tap")
        #expect(tapDescription.deviceUID == "test-output-device")
        #expect(tapDescription.stream == 0)
        #expect(tapDescription.processes == [123])
    }
}
