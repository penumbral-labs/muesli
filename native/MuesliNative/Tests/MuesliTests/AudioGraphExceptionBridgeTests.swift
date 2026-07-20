import AVFoundation
import AudioGraphExceptionBridge
import Testing

@Suite("AVFAudio exception boundary")
struct AudioGraphExceptionBridgeTests {
    @Test("duplicate tap installation becomes an error instead of aborting the process")
    func duplicateTapIsCaught() {
        let engine = AVAudioEngine()
        let node = engine.mainMixerNode
        let block: AVAudioNodeTapBlock = { _, _ in }

        let firstError = MuesliAudioGraphInstallTap(node, 0, 512, nil, block)
        #expect(firstError == nil)

        let secondError = MuesliAudioGraphInstallTap(node, 0, 512, nil, block)
        #expect(secondError != nil)
        #expect((secondError as NSError?)?.domain == "MuesliAudioGraph")

        _ = MuesliAudioGraphRemoveTap(node, 0)
    }
}
