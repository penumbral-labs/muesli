import Testing
@testable import MuesliNativeApp

@Suite("Meeting capture lifecycle")
struct MeetingCaptureLifecycleCoordinatorTests {
    @Test("capture remains exclusive through startup, activity, and quiescence")
    func exclusiveLifecycle() throws {
        var coordinator = MeetingCaptureLifecycleCoordinator()
        let acquired = coordinator.beginCapture()
        let lease = try #require(acquired)

        let overlappingStart = coordinator.beginCapture()
        #expect(overlappingStart == nil)
        let activated = coordinator.markActive(lease)
        #expect(activated)
        let activeOverlap = coordinator.beginCapture()
        #expect(activeOverlap == nil)
        let quiescing = coordinator.beginQuiescing(lease)
        #expect(quiescing == .acquired)
        let teardownOverlap = coordinator.beginCapture()
        #expect(teardownOverlap == nil)
        let completed = coordinator.completeQuiescence(lease)
        #expect(completed)
        #expect(!coordinator.isCaptureOccupied)
        let next = coordinator.beginCapture()
        #expect(next != nil)
    }

    @Test("cancelled startup holds its lease until cleanup completes")
    func cancelledStartupWaitsForCleanup() throws {
        var coordinator = MeetingCaptureLifecycleCoordinator()
        let acquired = coordinator.beginCapture()
        let lease = try #require(acquired)

        let quiescing = coordinator.beginQuiescing(lease)
        #expect(quiescing == .acquired)
        let overlap = coordinator.beginCapture()
        #expect(overlap == nil)
        let completed = coordinator.completeQuiescence(lease)
        #expect(completed)
        let next = coordinator.beginCapture()
        #expect(next != nil)
    }

    @Test("a stale completion cannot release a newer generation")
    func staleCompletionCannotReleaseNewerCapture() throws {
        var coordinator = MeetingCaptureLifecycleCoordinator()
        let firstAcquired = coordinator.beginCapture()
        let first = try #require(firstAcquired)
        let firstQuiescing = coordinator.beginQuiescing(first)
        let firstCompleted = coordinator.completeQuiescence(first)
        #expect(firstQuiescing == .acquired)
        #expect(firstCompleted)

        let secondAcquired = coordinator.beginCapture()
        let second = try #require(secondAcquired)
        let secondActivated = coordinator.markActive(second)
        #expect(secondActivated)
        let staleCompletion = coordinator.completeQuiescence(first)
        #expect(!staleCompletion)
        #expect(coordinator.owns(second))
    }

    @Test("a stale generation cannot activate or quiesce the current capture")
    func staleGenerationCannotMutateCurrentCapture() throws {
        var coordinator = MeetingCaptureLifecycleCoordinator()
        let firstAcquired = coordinator.beginCapture()
        let first = try #require(firstAcquired)
        let firstQuiescing = coordinator.beginQuiescing(first)
        let firstCompleted = coordinator.completeQuiescence(first)
        #expect(firstQuiescing == .acquired)
        #expect(firstCompleted)

        let secondAcquired = coordinator.beginCapture()
        let second = try #require(secondAcquired)
        let staleActivation = coordinator.markActive(first)
        let staleQuiescence = coordinator.beginQuiescing(first)
        #expect(!staleActivation)
        #expect(staleQuiescence == .rejected)
        let secondActivated = coordinator.markActive(second)
        #expect(secondActivated)
    }

    @Test("termination cannot claim teardown while stop already quiesces the meeting")
    func terminationDoesNotDuplicateStopTeardown() throws {
        var coordinator = MeetingCaptureLifecycleCoordinator()
        let acquired = coordinator.beginCapture()
        let lease = try #require(acquired)
        let activated = coordinator.markActive(lease)
        #expect(activated)

        let firstQuiescence = coordinator.beginQuiescing(lease)
        let terminationQuiescence = coordinator.beginQuiescing(lease)
        let shutdownQuiescence = coordinator.beginQuiescing(lease)
        let completed = coordinator.completeQuiescence(lease)
        let repeatedCompletion = coordinator.completeQuiescence(lease)
        #expect(firstQuiescence == .acquired)
        #expect(terminationQuiescence == .alreadyQuiescing)
        #expect(shutdownQuiescence == .alreadyQuiescing)
        #expect(completed)
        #expect(!repeatedCompletion)
    }
}
