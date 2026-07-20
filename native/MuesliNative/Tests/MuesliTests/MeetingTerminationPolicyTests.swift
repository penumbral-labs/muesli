import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting termination policy")
struct MeetingTerminationPolicyTests {
    @Test("allows termination when no meeting lifecycle is active")
    func allowsIdleTermination() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: false,
                isRecording: false,
                isStopping: false
            ) == .none
        )
    }

    @Test("warns while a meeting is starting")
    func warnsDuringStart() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: true,
                hasActiveSession: false,
                isRecording: false,
                isStopping: false
            ) == .starting
        )
    }

    @Test("warns while a meeting is recording")
    func warnsDuringRecording() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: true,
                isRecording: true,
                isStopping: false
            ) == .recording
        )
    }

    @Test("warns while a session exists before recording state is visible")
    func warnsForActiveSessionBeforeRecording() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: true,
                isRecording: false,
                isStopping: false
            ) == .processing
        )
    }

    @Test("warns while a stopped meeting is still processing")
    func warnsDuringProcessing() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: true,
                isRecording: false,
                isStopping: true
            ) == .processing
        )
    }

    @Test("warns while stopping even when session is already nil")
    func warnsDuringStopWithNoSession() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: false,
                isRecording: false,
                isStopping: true
            ) == .processing
        )
    }

    @Test("a starting meeting takes priority over older background processing")
    func startingMeetingTakesPriorityOverProcessing() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: true,
                hasActiveSession: false,
                isRecording: false,
                isStopping: true
            ) == .starting
        )
    }

    @Test("an active recording takes priority over older background processing")
    func activeRecordingTakesPriorityOverProcessing() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: true,
                isRecording: true,
                isStopping: true
            ) == .recording
        )
    }

    @Test("out-of-order finalization cannot steal the newer task's UI ownership")
    func finalizationTokensPreserveUIOwnership() {
        var tracker = MeetingFinalizationTracker()
        let older = MeetingFinalizationTracker.Token(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let newer = MeetingFinalizationTracker.Token(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        _ = tracker.begin(token: older, designateAsUIOwner: true)
        _ = tracker.begin(token: newer, designateAsUIOwner: true)
        #expect(tracker.count == 2)
        #expect(!tracker.isUIOwner(older))
        #expect(tracker.isUIOwner(newer))

        tracker.complete(older)
        #expect(tracker.count == 1)
        #expect(tracker.isUIOwner(newer))

        tracker.complete(newer)
        #expect(tracker.count == 0)
        #expect(tracker.uiOwner == nil)
    }

    @Test("an older meeting finalization cannot overwrite a new dictation")
    func dictationOwnsSharedUIAfterMeetingCaptureReleases() {
        // The meeting's audio lease has already been released, allowing a
        // dictation to start while its transcript continues finalizing.
        var tracker = MeetingFinalizationTracker()
        let meeting = tracker.begin(designateAsUIOwner: true)
        tracker.relinquishUIOwnership()

        #expect(!MeetingFinalizationUIUpdatePolicy.canPublishProgress(
            isUIOwner: tracker.isUIOwner(meeting),
            isMeetingRecording: false,
            isStartingMeeting: false
        ))
        let ownedUIBeforeCompletion = tracker.isUIOwner(meeting)
        tracker.complete(meeting)
        #expect(!MeetingFinalizationUIUpdatePolicy.canRestoreIdle(
            ownedUIBeforeCompletion: ownedUIBeforeCompletion,
            isMeetingRecording: false,
            isStartingMeeting: false,
            activeFinalizationCount: tracker.count
        ))
    }

    @Test("meeting finalization owns shared UI only while otherwise idle")
    func idleAppAllowsMeetingFinalizationUIUpdates() {
        var tracker = MeetingFinalizationTracker()
        let meeting = tracker.begin(designateAsUIOwner: true)
        #expect(MeetingFinalizationUIUpdatePolicy.canPublishProgress(
            isUIOwner: tracker.isUIOwner(meeting),
            isMeetingRecording: false,
            isStartingMeeting: false
        ))
        let ownedUIBeforeCompletion = tracker.isUIOwner(meeting)
        tracker.complete(meeting)
        #expect(MeetingFinalizationUIUpdatePolicy.canRestoreIdle(
            ownedUIBeforeCompletion: ownedUIBeforeCompletion,
            isMeetingRecording: false,
            isStartingMeeting: false,
            activeFinalizationCount: tracker.count
        ))
    }

    @Test("streaming prepare no-op preserves meeting finalization UI ownership")
    func streamingPrepareDoesNotClaimForegroundUI() {
        var tracker = MeetingFinalizationTracker()
        let meeting = tracker.begin(designateAsUIOwner: true)

        let shouldClaim = ForegroundActivityUIClaimPolicy.dictationPrepareClaimsUI(
            isStreamingBackend: true,
            hasActiveAudioSession: false
        )
        if shouldClaim {
            tracker.relinquishUIOwnership()
        }

        #expect(!shouldClaim)
        #expect(tracker.isUIOwner(meeting))
    }

    @Test("background meeting finalization does not block foreground capture controls")
    func finalizationDisplayAllowsForegroundCapture() {
        #expect(ForegroundActivityUIClaimPolicy.canBeginCapture(
            sharedState: .transcribing,
            meetingFinalizationOwnsUI: true
        ))
        #expect(!ForegroundActivityUIClaimPolicy.canBeginCapture(
            sharedState: .transcribing,
            meetingFinalizationOwnsUI: false
        ))
    }

    @Test("resuming a meeting relinquishes an older finalization's UI")
    func resumedMeetingClaimsForegroundUI() {
        var tracker = MeetingFinalizationTracker()
        let older = tracker.begin(designateAsUIOwner: true)
        tracker.relinquishUIOwnership()

        #expect(!tracker.isUIOwner(older))
    }
}
