import Testing
@testable import MuesliNativeApp

@Suite("AudioQueue processing admission")
struct AudioQueueProcessingAdmissionStateTests {
    @Test("reentrant pause invalidates work queued behind the current callback")
    func pauseBoundaryInvalidatesQueuedTickets() {
        var state = AudioQueueProcessingAdmissionState()
        state.beginCapture()
        let queuedBeforePause = state.ticket
        #expect(state.accepts(queuedBeforePause))

        state.advancePauseBoundary()

        #expect(!state.accepts(queuedBeforePause))
        #expect(state.accepts(state.ticket))
    }

    @Test("capture invalidation rejects every prior pause epoch")
    func captureInvalidationRejectsOldTickets() {
        var state = AudioQueueProcessingAdmissionState()
        state.beginCapture()
        let firstRun = state.ticket
        state.advancePauseBoundary()
        let resumedFirstRun = state.ticket

        state.invalidateCapture(ifCurrent: firstRun.captureGeneration)

        #expect(!state.accepts(firstRun))
        #expect(!state.accepts(resumedFirstRun))
        #expect(state.accepts(state.ticket))
    }

    @Test("stale teardown cannot invalidate a newer capture")
    func conditionalInvalidationPreservesNewerCapture() {
        var state = AudioQueueProcessingAdmissionState()
        state.beginCapture()
        let staleGeneration = state.captureGeneration
        state.beginCapture()
        let current = state.ticket

        state.invalidateCapture(ifCurrent: staleGeneration)

        #expect(state.accepts(current))
    }

    @Test("reentrant cancel during stop cannot reopen teardown early")
    func cancelDuringStopIsDeferredToTransitionOwner() {
        var state = AudioQueueTeardownState()
        let beganStop = state.beginStop()
        #expect(beganStop)
        #expect(!state.permitsGraphMutation)

        // Models an owner callback reentering cancel while an external stop is
        // draining that callback: it records intent and returns immediately.
        let beganReentrantCancel = state.beginCancel()
        #expect(!beganReentrantCancel)
        #expect(!state.permitsGraphMutation)

        let cancelOwnsCompletion = state.finishStop()
        #expect(cancelOwnsCompletion)
        #expect(!state.permitsGraphMutation)
        state.finishCancel()
        #expect(state.permitsGraphMutation)
    }

    @Test("duplicate teardown remains owned by the first caller")
    func duplicateTeardownIsIdempotent() {
        var state = AudioQueueTeardownState()
        let beganCancel = state.beginCancel()
        let beganDuplicateStop = state.beginStop()
        let beganDuplicateCancel = state.beginCancel()
        #expect(beganCancel)
        #expect(!beganDuplicateStop)
        #expect(!beganDuplicateCancel)
        state.finishCancel()
        #expect(state.permitsGraphMutation)
    }

    @Test("stop during preparation leaves graph disposal with preparation owner")
    func stopDuringPreparationDefersGraphDisposal() {
        var state = AudioQueueTeardownState()
        let beganPreparation = state.beginPreparation()
        let stopOwnsTeardown = state.beginStop()
        #expect(beganPreparation)
        #expect(!stopOwnsTeardown)
        #expect(!state.permitsGraphMutation)

        let completion = state.finishPreparation(succeeded: true)
        #expect(completion == .discard)
        #expect(state.transition == .cancelling)
        state.finishCancel()
        #expect(state.permitsGraphMutation)
    }

    @Test("stop during AudioQueueStart is resolved by the startup owner")
    func stopDuringStartDefersGraphDisposal() {
        var state = AudioQueueTeardownState()
        let beganStart = state.beginStart()
        #expect(beganStart)
        #expect(state.permitsStartCall)

        let stopOwnsTeardown = state.beginStop()
        #expect(!stopOwnsTeardown)
        #expect(!state.permitsStartCall)
        let completion = state.finishStart(succeeded: true)
        #expect(completion == .tearDown)
        #expect(state.transition == .cancelling)
        state.finishCancel()
        #expect(state.permitsGraphMutation)
    }

    @Test("cancel during failed AudioQueueStart still has one teardown owner")
    func cancelDuringFailedStartHasSingleOwner() {
        var state = AudioQueueTeardownState()
        let beganStart = state.beginStart()
        let cancelOwnsTeardown = state.beginCancel()
        #expect(beganStart)
        #expect(!cancelOwnsTeardown)

        let completion = state.finishStart(succeeded: false)
        let duplicateCancelOwnsTeardown = state.beginCancel()
        #expect(completion == .tearDown)
        #expect(!duplicateCancelOwnsTeardown)
        state.finishCancel()
        #expect(state.permitsGraphMutation)
    }

    @Test("successful AudioQueueStart reopens ordinary stop ownership")
    func successfulStartReopensStopOwnership() {
        var state = AudioQueueTeardownState()
        let beganStart = state.beginStart()
        let startCompletion = state.finishStart(succeeded: true)
        #expect(beganStart)
        #expect(startCompletion == .active)
        #expect(state.permitsGraphMutation)

        let beganStop = state.beginStop()
        let cancelOwnsCompletion = state.finishStop()
        #expect(beganStop)
        #expect(!cancelOwnsCompletion)
        #expect(state.permitsGraphMutation)
    }
}
