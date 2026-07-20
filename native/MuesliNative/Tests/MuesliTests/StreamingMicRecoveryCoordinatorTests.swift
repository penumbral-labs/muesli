import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Streaming microphone recovery coordinator")
struct StreamingMicRecoveryCoordinatorTests {
    private let policy = StreamingMicRecoveryCoordinator.Policy(
        settlementDelay: 0.2,
        retryDelay: 0.25,
        firstBufferTimeout: 1.5,
        maxGraphStartAttempts: 2
    )

    private var builtIn: StreamingMicInputSnapshot {
        StreamingMicInputSnapshot(
            requestedDeviceID: nil,
            actualDeviceID: AudioObjectID(10),
            sampleRate: 48_000,
            channelCount: 1
        )
    }

    private var airPods: StreamingMicInputSnapshot {
        StreamingMicInputSnapshot(
            requestedDeviceID: nil,
            actualDeviceID: AudioObjectID(20),
            sampleRate: 24_000,
            channelCount: 1
        )
    }

    @Test("rapid configuration notifications coalesce into one graph rebuild")
    func rapidNotificationsCoalesce() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let initialTap = try startInitialCapture(&coordinator, now: 0)
        let initialBuffer = coordinator.noteBuffer(
            token: initialTap,
            callbackTime: 1,
            audioStartTime: 100,
            sampleCount: 4_096
        )
        #expect(initialBuffer == .accepted)

        let firstSettlement = try settlement(from: coordinator.noteConfigurationChange(now: 1.1))
        let secondSettlement = try settlement(from: coordinator.noteConfigurationChange(now: 1.15))

        let staleSettlement = coordinator.settlementElapsed(firstSettlement)
        #expect(staleSettlement == .ignored)
        let request = try restart(from: coordinator.settlementElapsed(secondSettlement))
        #expect(request.attempt == 1)
        #expect(coordinator.diagnosticsSnapshot.configurationChangeCount == 2)
        #expect(coordinator.diagnosticsSnapshot.coalescedConfigurationChangeCount == 1)
        #expect(coordinator.diagnosticsSnapshot.graphRestartAttemptCount == 1)
    }

    @Test("a change during rebuild creates at most one trailing rebuild")
    func changeDuringRebuildCreatesOneTrailingRestart() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let initialTap = try startInitialCapture(&coordinator, now: 0)
        _ = coordinator.noteBuffer(token: initialTap, callbackTime: 1, sampleCount: 4_096)

        let settlement = try settlement(from: coordinator.noteConfigurationChange(now: 1.1))
        let firstRequest = try restart(from: coordinator.settlementElapsed(settlement))
        let coalesced = coordinator.noteConfigurationChange(now: 1.2)
        #expect(coalesced == .coalesced)

        let trailing = try trailingSettlement(
            from: coordinator.graphPrepared(for: firstRequest, input: airPods)
        )
        let secondRequest = try restart(from: coordinator.settlementElapsed(trailing))
        let timeout = try prepareAndStartGraph(&coordinator, request: secondRequest, input: airPods)
        #expect(timeout.captureToken == secondRequest.captureToken)

        guard case .recovered(let discontinuity) = coordinator.noteBuffer(
            token: secondRequest.captureToken,
            callbackTime: 2,
            sampleCount: 4_096
        ) else {
            Issue.record("Expected final trailing rebuild to recover")
            return
        }
        #expect(discontinuity.restartAttemptCount == 2)
        #expect(coordinator.diagnosticsSnapshot.graphRestartAttemptCount == 2)
        #expect(coordinator.diagnosticsSnapshot.successfulRecoveryCount == 1)
    }

    @Test("configuration changes on the final attempt fail instead of accepting a stale graph")
    func finalAttemptRouteChangeFailsBoundedRecovery() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let initialTap = try startInitialCapture(&coordinator, now: 0)
        _ = coordinator.noteBuffer(token: initialTap, callbackTime: 1, sampleCount: 1_600)

        let firstSettlement = try settlement(from: coordinator.noteConfigurationChange(now: 1.1))
        let firstRequest = try restart(from: coordinator.settlementElapsed(firstSettlement))
        let firstTimeout = try prepareAndStartGraph(&coordinator, request: firstRequest, input: airPods)
        let retrySettlement = try retry(from: coordinator.firstBufferTimedOut(firstTimeout, now: 2.7))
        let finalRequest = try restart(from: coordinator.settlementElapsed(retrySettlement))
        _ = try prepareAndStartGraph(&coordinator, request: finalRequest, input: airPods)

        guard case .failed(let failure) = coordinator.noteConfigurationChange(now: 3) else {
            Issue.record("Expected a final-attempt route change to fail bounded recovery")
            return
        }
        #expect(failure.restartAttemptCount == 2)
        let staleBuffer = coordinator.noteBuffer(
            token: finalRequest.captureToken,
            callbackTime: 3.2,
            sampleCount: 1_600
        )
        #expect(staleBuffer == .rejected)
        #expect(coordinator.diagnosticsSnapshot.graphRestartAttemptCount == 2)
        #expect(coordinator.diagnosticsSnapshot.failedRecoveryCount == 1)
    }

    @Test("a route change during the final rebuild fails before graph preparation")
    func finalAttemptChangeDuringRebuildFails() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let initialTap = try startInitialCapture(&coordinator, now: 0)
        _ = coordinator.noteBuffer(token: initialTap, callbackTime: 1, sampleCount: 1_600)

        let firstSettlement = try settlement(from: coordinator.noteConfigurationChange(now: 1.1))
        let firstRequest = try restart(from: coordinator.settlementElapsed(firstSettlement))
        let firstTimeout = try prepareAndStartGraph(&coordinator, request: firstRequest, input: airPods)
        let retrySettlement = try retry(from: coordinator.firstBufferTimedOut(firstTimeout, now: 2.7))
        let finalRequest = try restart(from: coordinator.settlementElapsed(retrySettlement))

        guard case .failed(let failure) = coordinator.noteConfigurationChange(now: 3) else {
            Issue.record("Expected the final rebuild to fail on another route change")
            return
        }
        #expect(failure.restartAttemptCount == 2)
        #expect(coordinator.graphPrepared(for: finalRequest, input: airPods) == .ignored)
        #expect(coordinator.diagnosticsSnapshot.failedRecoveryCount == 1)
    }

    @Test("a route change while the final graph starts fails before first-buffer proof")
    func finalAttemptChangeDuringGraphStartFails() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let initialTap = try startInitialCapture(&coordinator, now: 0)
        _ = coordinator.noteBuffer(token: initialTap, callbackTime: 1, sampleCount: 1_600)

        let firstSettlement = try settlement(from: coordinator.noteConfigurationChange(now: 1.1))
        let firstRequest = try restart(from: coordinator.settlementElapsed(firstSettlement))
        let firstTimeout = try prepareAndStartGraph(&coordinator, request: firstRequest, input: airPods)
        let retrySettlement = try retry(from: coordinator.firstBufferTimedOut(firstTimeout, now: 2.7))
        let finalRequest = try restart(from: coordinator.settlementElapsed(retrySettlement))
        #expect(coordinator.graphPrepared(for: finalRequest, input: airPods) == .startGraph)

        guard case .failed(let failure) = coordinator.noteConfigurationChange(now: 3) else {
            Issue.record("Expected the final starting graph to fail on another route change")
            return
        }
        #expect(failure.restartAttemptCount == 2)
        #expect(coordinator.recoveryGraphStarted(for: finalRequest, input: airPods) == .ignored)
        #expect(coordinator.noteBuffer(
            token: finalRequest.captureToken,
            callbackTime: 3.1,
            sampleCount: 1_600
        ) == .rejected)
        #expect(coordinator.diagnosticsSnapshot.failedRecoveryCount == 1)
    }

    @Test("engine start is not recovery until start returns and the exact tap delivers")
    func recoveryRequiresStartedGraphAndMatchingFirstBuffer() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let initialTap = try startInitialCapture(&coordinator, now: 0)
        _ = coordinator.noteBuffer(
            token: initialTap,
            callbackTime: 1,
            audioStartTime: 100,
            sampleCount: 1_600
        )

        let settlement = try settlement(from: coordinator.noteConfigurationChange(now: 1.1))
        let request = try restart(from: coordinator.settlementElapsed(settlement))
        let prepared = coordinator.graphPrepared(for: request, input: airPods)
        #expect(prepared == .startGraph)
        let earlyBuffer = coordinator.noteBuffer(
            token: request.captureToken,
            callbackTime: 1.5,
            audioStartTime: 100.5,
            sampleCount: 1_600
        )
        #expect(earlyBuffer == .rejected)
        _ = try timeout(from: coordinator.recoveryGraphStarted(for: request, input: airPods))
        let staleBuffer = coordinator.noteBuffer(
            token: initialTap,
            callbackTime: 1.6,
            sampleCount: 1_600
        )
        #expect(staleBuffer == .rejected)

        guard case .recovered(let report) = coordinator.noteBuffer(
            token: request.captureToken,
            callbackTime: 8,
            audioStartTime: 101,
            sampleCount: 1_600
        ) else {
            Issue.record("Expected matching replacement tap to establish recovery")
            return
        }

        #expect(report.previousInput == builtIn)
        #expect(report.currentInput == airPods)
        // Host audio time is authoritative; callback scheduling was delayed by
        // seven seconds but the actual capture gap was 0.9 seconds.
        #expect(report.missingSampleCount == 14_400)
        #expect(abs(report.downtimeSeconds - 6.9) < 0.000_1)
    }

    @Test("a missing host timestamp falls back to the latest callback instead of recording start")
    func mixedHostTimestampValidityUsesRecentFallback() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let initialTap = try startInitialCapture(&coordinator, now: 0)
        _ = coordinator.noteBuffer(
            token: initialTap,
            callbackTime: 1,
            audioStartTime: 100,
            sampleCount: 1_600
        )
        _ = coordinator.noteBuffer(
            token: initialTap,
            callbackTime: 2,
            audioStartTime: nil,
            sampleCount: 1_600
        )

        let settlement = try settlement(from: coordinator.noteConfigurationChange(now: 2.1))
        let request = try restart(from: coordinator.settlementElapsed(settlement))
        _ = try prepareAndStartGraph(&coordinator, request: request, input: airPods)
        guard case .recovered(let report) = coordinator.noteBuffer(
            token: request.captureToken,
            callbackTime: 3,
            audioStartTime: 102,
            sampleCount: 1_600
        ) else {
            Issue.record("Expected recovery after the mixed timestamp sequence")
            return
        }

        #expect(report.missingSampleCount == 14_400)
    }

    @Test("first-buffer timeout retries once and the second timeout fails exactly once")
    func timeoutRetriesOnceThenFails() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let initialTap = try startInitialCapture(&coordinator, now: 0)
        _ = coordinator.noteBuffer(token: initialTap, callbackTime: 1, sampleCount: 4_096)

        let settlement = try settlement(from: coordinator.noteConfigurationChange(now: 1.1))
        let firstRequest = try restart(from: coordinator.settlementElapsed(settlement))
        let firstTimeout = try prepareAndStartGraph(&coordinator, request: firstRequest, input: airPods)
        let retrySettlement = try retry(
            from: coordinator.firstBufferTimedOut(firstTimeout, now: 2.7)
        )

        let secondRequest = try restart(from: coordinator.settlementElapsed(retrySettlement))
        let secondTimeout = try prepareAndStartGraph(&coordinator, request: secondRequest, input: airPods)
        guard case .failed(let failure) = coordinator.firstBufferTimedOut(secondTimeout, now: 4.3) else {
            Issue.record("Expected retry exhaustion to fail")
            return
        }

        #expect(failure.restartAttemptCount == 2)
        #expect(coordinator.diagnosticsSnapshot.failedRecoveryCount == 1)
        let duplicateTimeout = coordinator.firstBufferTimedOut(secondTimeout, now: 5)
        #expect(duplicateTimeout == .ignored)
        #expect(coordinator.diagnosticsSnapshot.failedRecoveryCount == 1)
    }

    @Test("initial no-buffer recovery advances from recording start")
    func initialBufferTimeoutPreservesElapsedTimeline() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let recordingID = UUID()
        let initialTap = coordinator.beginRecording(
            recordingID: recordingID,
            input: builtIn,
            now: 10,
            audioClockTime: 100
        )
        let initialTimeout = try timeout(
            from: coordinator.initialGraphStarted(token: initialTap, input: builtIn)
        )
        let retrySettlement = try retry(
            from: coordinator.firstBufferTimedOut(initialTimeout, now: 11.5)
        )
        let request = try restart(from: coordinator.settlementElapsed(retrySettlement))
        _ = try prepareAndStartGraph(&coordinator, request: request, input: builtIn)

        guard case .recovered(let report) = coordinator.noteBuffer(
            token: request.captureToken,
            callbackTime: 12.2,
            audioStartTime: 102,
            sampleCount: 4_096
        ) else {
            Issue.record("Expected retry buffer to recover initial capture")
            return
        }
        #expect(report.reason == .initialBufferTimeout)
        #expect(report.missingSampleCount == 32_000)
        #expect(abs(report.downtimeSeconds - 2.2) < 0.000_1)
    }

    @Test("recovery spanning pause reports only the post-resume gap")
    func recoveryAcrossPauseRebasesTimeline() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let recordingID = UUID()
        let initialTap = coordinator.beginRecording(
            recordingID: recordingID,
            input: builtIn,
            now: 0,
            audioClockTime: 100
        )
        _ = try timeout(from: coordinator.initialGraphStarted(token: initialTap, input: builtIn))
        _ = coordinator.noteBuffer(
            token: initialTap,
            callbackTime: 1,
            audioStartTime: 100,
            sampleCount: 1_600
        )

        let firstSettlement = try settlement(from: coordinator.noteConfigurationChange(now: 1.1))
        let request = try restart(from: coordinator.settlementElapsed(firstSettlement))
        _ = try prepareAndStartGraph(&coordinator, request: request, input: airPods)

        let didPause = coordinator.pauseRecording(recordingID)
        let didResume = coordinator.resumeRecording(recordingID, now: 10, audioClockTime: 200)
        #expect(didPause)
        #expect(didResume)
        guard case .recovered(let resumedRecovery) = coordinator.noteBuffer(
            token: request.captureToken,
            callbackTime: 11.6,
            audioStartTime: 201.5,
            sampleCount: 1_600
        ) else {
            Issue.record("Expected recovery to retain only its post-resume gap")
            return
        }
        #expect(resumedRecovery.missingSampleCount == 24_000)
        #expect(abs(resumedRecovery.downtimeSeconds - 1.6) < 0.000_1)
        #expect(coordinator.diagnosticsSnapshot.successfulRecoveryCount == 1)
        #expect(coordinator.diagnosticsSnapshot.discontinuities == [resumedRecovery])

        // The proving buffer becomes the new baseline. A later recovery in
        // the resumed epoch reports only its real post-resume gap.
        let resumedSettlement = try settlement(
            from: coordinator.noteConfigurationChange(now: 11.7)
        )
        let resumedRequest = try restart(
            from: coordinator.settlementElapsed(resumedSettlement)
        )
        _ = try prepareAndStartGraph(&coordinator, request: resumedRequest, input: builtIn)
        guard case .recovered(let discontinuity) = coordinator.noteBuffer(
            token: resumedRequest.captureToken,
            callbackTime: 12.2,
            audioStartTime: 202,
            sampleCount: 1_600
        ) else {
            Issue.record("Expected recovery wholly inside the resumed epoch")
            return
        }
        #expect(discontinuity.missingSampleCount == 6_400)
    }

    @Test("recovery proved while paused becomes a fresh resume baseline")
    func recoveryWhilePausedDoesNotAdvanceRecordingClock() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let recordingID = UUID()
        let initialTap = coordinator.beginRecording(
            recordingID: recordingID,
            input: builtIn,
            now: 0,
            audioClockTime: 100
        )
        _ = try timeout(from: coordinator.initialGraphStarted(token: initialTap, input: builtIn))
        _ = coordinator.noteBuffer(
            token: initialTap,
            callbackTime: 1,
            audioStartTime: 100,
            sampleCount: 1_600
        )

        let didPause = coordinator.pauseRecording(recordingID)
        #expect(didPause)
        let pauseSettlement = try settlement(from: coordinator.noteConfigurationChange(now: 20))
        let request = try restart(from: coordinator.settlementElapsed(pauseSettlement))
        _ = try prepareAndStartGraph(&coordinator, request: request, input: airPods)
        let restoredWhilePaused = coordinator.noteBuffer(
            token: request.captureToken,
            callbackTime: 21,
            audioStartTime: 300,
            sampleCount: 1_600
        )
        #expect(restoredWhilePaused == .restoredAcrossTimelineBoundary)

        let didResume = coordinator.resumeRecording(recordingID, now: 30, audioClockTime: 400)
        #expect(didResume)
        let resumedBuffer = coordinator.noteBuffer(
            token: request.captureToken,
            callbackTime: 30.1,
            audioStartTime: 400,
            sampleCount: 1_600
        )
        #expect(resumedBuffer == .accepted)
        #expect(coordinator.diagnosticsSnapshot.discontinuities.isEmpty)
    }

    @Test("stop invalidates callbacks, settlement timers, retries, and timeouts")
    func stopInvalidatesAllQueuedWork() throws {
        var coordinator = StreamingMicRecoveryCoordinator(policy: policy)
        let recordingID = UUID()
        let initialTap = coordinator.beginRecording(
            recordingID: recordingID,
            input: builtIn,
            now: 0
        )
        let initialTimeout = try timeout(
            from: coordinator.initialGraphStarted(token: initialTap, input: builtIn)
        )
        _ = coordinator.noteBuffer(token: initialTap, callbackTime: 1, sampleCount: 4_096)
        let settlement = try settlement(from: coordinator.noteConfigurationChange(now: 1.1))

        coordinator.endRecording(recordingID)

        #expect(!coordinator.hasActiveRecording)
        let staleBuffer = coordinator.noteBuffer(
            token: initialTap,
            callbackTime: 2,
            sampleCount: 4_096
        )
        let staleSettlement = coordinator.settlementElapsed(settlement)
        let staleTimeout = coordinator.firstBufferTimedOut(initialTimeout, now: 2)
        let staleChange = coordinator.noteConfigurationChange(now: 2)
        #expect(staleBuffer == .rejected)
        #expect(staleSettlement == .ignored)
        #expect(staleTimeout == .ignored)
        #expect(staleChange == .ignored)
    }

    private func startInitialCapture(
        _ coordinator: inout StreamingMicRecoveryCoordinator,
        now: TimeInterval
    ) throws -> StreamingMicRecoveryCoordinator.CaptureToken {
        let token = coordinator.beginRecording(
            recordingID: UUID(),
            input: builtIn,
            now: now
        )
        _ = try timeout(from: coordinator.initialGraphStarted(token: token, input: builtIn))
        return token
    }

    private func prepareAndStartGraph(
        _ coordinator: inout StreamingMicRecoveryCoordinator,
        request: StreamingMicRecoveryCoordinator.RestartRequest,
        input: StreamingMicInputSnapshot
    ) throws -> StreamingMicRecoveryCoordinator.FirstBufferTimeoutToken {
        guard coordinator.graphPrepared(for: request, input: input) == .startGraph else {
            throw TestError.unexpectedDecision
        }
        return try timeout(from: coordinator.recoveryGraphStarted(for: request, input: input))
    }

    private func settlement(
        from decision: StreamingMicRecoveryCoordinator.ConfigurationChangeDecision
    ) throws -> StreamingMicRecoveryCoordinator.SettlementToken {
        guard case .schedule(let token, _) = decision else {
            throw TestError.unexpectedDecision
        }
        return token
    }

    private func restart(
        from decision: StreamingMicRecoveryCoordinator.SettlementDecision
    ) throws -> StreamingMicRecoveryCoordinator.RestartRequest {
        guard case .rebuild(let request) = decision else {
            throw TestError.unexpectedDecision
        }
        return request
    }

    private func timeout(
        from decision: StreamingMicRecoveryCoordinator.GraphStartedDecision
    ) throws -> StreamingMicRecoveryCoordinator.FirstBufferTimeoutToken {
        guard case .awaitFirstBuffer(let token, _) = decision else {
            throw TestError.unexpectedDecision
        }
        return token
    }

    private func trailingSettlement(
        from decision: StreamingMicRecoveryCoordinator.GraphPreparedDecision
    ) throws -> StreamingMicRecoveryCoordinator.SettlementToken {
        guard case .scheduleTrailing(let token, _) = decision else {
            throw TestError.unexpectedDecision
        }
        return token
    }

    private func retry(
        from decision: StreamingMicRecoveryCoordinator.RecoveryFailureDecision
    ) throws -> StreamingMicRecoveryCoordinator.SettlementToken {
        guard case .retry(let token, _) = decision else {
            throw TestError.unexpectedDecision
        }
        return token
    }

    private enum TestError: Error {
        case unexpectedDecision
    }
}
