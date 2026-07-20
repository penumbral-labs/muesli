import CoreAudio
import Foundation

struct StreamingMicInputSnapshot: Codable, Equatable, Sendable {
    let requestedDeviceID: AudioObjectID?
    let actualDeviceID: AudioObjectID?
    let sampleRate: Double
    let channelCount: UInt32
}

enum StreamingMicRecoveryReason: String, Codable, Equatable, Sendable {
    case inputConfigurationChanged
    case initialBufferTimeout
}

struct StreamingMicDiscontinuity: Codable, Equatable, Sendable {
    let generation: UInt64
    let reason: StreamingMicRecoveryReason
    let missingSampleCount: Int64
    let downtimeSeconds: TimeInterval
    let restartAttemptCount: Int
    let previousInput: StreamingMicInputSnapshot
    let currentInput: StreamingMicInputSnapshot
}

struct StreamingMicCaptureFailure: Codable, Equatable, Sendable {
    let generation: UInt64
    let reason: StreamingMicRecoveryReason
    let restartAttemptCount: Int
    let previousInput: StreamingMicInputSnapshot
    let message: String

    var legacyError: NSError {
        NSError(
            domain: "StreamingMicRecorder.Recovery",
            code: Int(truncatingIfNeeded: generation),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum StreamingMicCaptureEvent: Equatable, Sendable {
    case recovered(StreamingMicDiscontinuity)
    case failed(StreamingMicCaptureFailure)
}

struct StreamingMicRecoveryDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let configurationChangeCount: Int
    let coalescedConfigurationChangeCount: Int
    let graphRestartAttemptCount: Int
    let successfulRecoveryCount: Int
    let failedRecoveryCount: Int
    let discontinuities: [StreamingMicDiscontinuity]
    let failures: [StreamingMicCaptureFailure]

    static let empty = StreamingMicRecoveryDiagnosticsSnapshot(
        configurationChangeCount: 0,
        coalescedConfigurationChangeCount: 0,
        graphRestartAttemptCount: 0,
        successfulRecoveryCount: 0,
        failedRecoveryCount: 0,
        discontinuities: [],
        failures: []
    )
}

protocol StreamingMicCaptureEventReporting: AnyObject {
    var onCaptureEvent: ((StreamingMicCaptureEvent) -> Void)? { get set }
    var captureRecoveryDiagnostics: StreamingMicRecoveryDiagnosticsSnapshot { get }
}

/// Pure, token-driven state machine for AVAudioEngine input recovery.
///
/// Cancellation of queued Dispatch work is only an optimization. Correctness
/// comes from revalidating the recording, configuration, recovery, and tap
/// generations carried by every timer, graph completion, and audio callback.
struct StreamingMicRecoveryCoordinator {
    struct Policy: Equatable, Sendable {
        let settlementDelay: TimeInterval
        let retryDelay: TimeInterval
        let firstBufferTimeout: TimeInterval
        let maxGraphStartAttempts: Int

        static let production = Policy(
            settlementDelay: 0.20,
            retryDelay: 0.25,
            firstBufferTimeout: 1.5,
            maxGraphStartAttempts: 2
        )
    }

    struct CaptureToken: Hashable, Sendable {
        let recordingID: UUID
        let tapGeneration: UInt64
    }

    struct SettlementToken: Hashable, Sendable {
        let recordingID: UUID
        let recoveryGeneration: UInt64
        let configurationGeneration: UInt64
    }

    struct RestartRequest: Equatable, Sendable {
        let settlementToken: SettlementToken
        let captureToken: CaptureToken
        let attempt: Int
    }

    struct FirstBufferTimeoutToken: Hashable, Sendable {
        let captureToken: CaptureToken
        let recoveryGeneration: UInt64?
    }

    enum ConfigurationChangeDecision: Equatable, Sendable {
        case ignored
        case coalesced
        case schedule(SettlementToken, delay: TimeInterval)
        case failed(StreamingMicCaptureFailure)
    }

    enum SettlementDecision: Equatable, Sendable {
        case ignored
        case rebuild(RestartRequest)
    }

    enum GraphPreparedDecision: Equatable, Sendable {
        case ignored
        case startGraph
        case scheduleTrailing(SettlementToken, delay: TimeInterval)
    }

    enum GraphStartedDecision: Equatable, Sendable {
        case ignored
        case awaitFirstBuffer(FirstBufferTimeoutToken, delay: TimeInterval)
        case scheduleTrailing(SettlementToken, delay: TimeInterval)
    }

    enum RecoveryFailureDecision: Equatable, Sendable {
        case ignored
        case retry(SettlementToken, delay: TimeInterval)
        case failed(StreamingMicCaptureFailure)
    }

    enum BufferDecision: Equatable, Sendable {
        case rejected
        case accepted
        /// The replacement graph proved that it is live while recording was
        /// paused. Its buffer is intentionally excluded from the retained
        /// timeline; resume will establish a fresh recording baseline.
        case restoredAcrossTimelineBoundary
        case recovered(StreamingMicDiscontinuity)
    }

    private struct Run: Equatable, Sendable {
        let recordingID: UUID
        let startedAt: TimeInterval
        var callbackTimelineAnchor: TimeInterval
        var audioTimelineAnchor: TimeInterval?
        var timelineEpoch: UInt64
        var isPaused: Bool
        var hasAcceptedBuffer: Bool
        var lastAcceptedCallbackEndTime: TimeInterval?
        var lastAcceptedAudioEndTime: TimeInterval?
    }

    private struct LiveCapture: Equatable, Sendable {
        let token: CaptureToken
        let input: StreamingMicInputSnapshot
    }

    private struct RecoveryCycle: Equatable, Sendable {
        let generation: UInt64
        var configurationGeneration: UInt64
        let reason: StreamingMicRecoveryReason
        let startedAt: TimeInterval
        let previousInput: StreamingMicInputSnapshot
        let timelineEpochAtStart: UInt64
        let startedWhilePaused: Bool
        var attemptCount: Int
    }

    private enum Phase: Equatable, Sendable {
        case idle
        case startingInitial(Run, LiveCapture)
        case awaitingInitialBuffer(Run, LiveCapture)
        case active(Run, LiveCapture)
        case settling(Run, RecoveryCycle, LiveCapture?)
        case rebuilding(Run, RecoveryCycle, CaptureToken)
        case startingRecoveryGraph(Run, RecoveryCycle, LiveCapture)
        case awaitingRecoveryBuffer(Run, RecoveryCycle, LiveCapture)
        case failed(UUID)
    }

    private struct MutableDiagnostics: Equatable, Sendable {
        var configurationChangeCount = 0
        var coalescedConfigurationChangeCount = 0
        var graphRestartAttemptCount = 0
        var successfulRecoveryCount = 0
        var failedRecoveryCount = 0
        var discontinuities: [StreamingMicDiscontinuity] = []
        var failures: [StreamingMicCaptureFailure] = []
    }

    private(set) var policy: Policy
    private var phase: Phase = .idle
    private var nextTapGeneration: UInt64 = 0
    private var nextRecoveryGeneration: UInt64 = 0
    private var configurationGeneration: UInt64 = 0
    private var diagnostics = MutableDiagnostics()

    init(policy: Policy = .production) {
        precondition(policy.maxGraphStartAttempts > 0)
        self.policy = policy
    }

    var hasActiveRecording: Bool {
        switch phase {
        case .idle, .failed:
            return false
        default:
            return true
        }
    }

    var diagnosticsSnapshot: StreamingMicRecoveryDiagnosticsSnapshot {
        StreamingMicRecoveryDiagnosticsSnapshot(
            configurationChangeCount: diagnostics.configurationChangeCount,
            coalescedConfigurationChangeCount: diagnostics.coalescedConfigurationChangeCount,
            graphRestartAttemptCount: diagnostics.graphRestartAttemptCount,
            successfulRecoveryCount: diagnostics.successfulRecoveryCount,
            failedRecoveryCount: diagnostics.failedRecoveryCount,
            discontinuities: diagnostics.discontinuities,
            failures: diagnostics.failures
        )
    }

    mutating func beginRecording(
        recordingID: UUID,
        input: StreamingMicInputSnapshot,
        now: TimeInterval,
        audioClockTime: TimeInterval? = nil
    ) -> CaptureToken {
        nextTapGeneration &+= 1
        let token = CaptureToken(recordingID: recordingID, tapGeneration: nextTapGeneration)
        let run = Run(
            recordingID: recordingID,
            startedAt: now,
            callbackTimelineAnchor: now,
            audioTimelineAnchor: audioClockTime,
            timelineEpoch: 0,
            isPaused: false,
            hasAcceptedBuffer: false,
            lastAcceptedCallbackEndTime: nil,
            lastAcceptedAudioEndTime: nil
        )
        phase = .startingInitial(run, LiveCapture(token: token, input: input))
        return token
    }

    mutating func initialGraphStarted(
        token: CaptureToken,
        input: StreamingMicInputSnapshot
    ) -> GraphStartedDecision {
        guard case .startingInitial(let run, let live) = phase,
              live.token == token else { return .ignored }
        let started = LiveCapture(token: token, input: input)
        phase = .awaitingInitialBuffer(run, started)
        return .awaitFirstBuffer(
            FirstBufferTimeoutToken(captureToken: token, recoveryGeneration: nil),
            delay: policy.firstBufferTimeout
        )
    }

    mutating func endRecording(_ recordingID: UUID? = nil) {
        if let recordingID, activeRecordingID != recordingID { return }
        phase = .idle
    }

    /// Starts a new logical recording epoch while leaving the capture graph
    /// alive. Recovery may continue proving graph liveness during the pause,
    /// but paused wall/host time must never become retained-audio silence.
    @discardableResult
    mutating func pauseRecording(_ recordingID: UUID) -> Bool {
        mutateRun(recordingID: recordingID) { run in
            guard !run.isPaused else { return }
            run.timelineEpoch &+= 1
            run.isPaused = true
            run.hasAcceptedBuffer = false
            run.lastAcceptedCallbackEndTime = nil
            run.lastAcceptedAudioEndTime = nil
        }
    }

    /// Rebases gap accounting to the moment recording resumes. A recovery
    /// cycle that began in an earlier epoch can still restore the graph. Once
    /// resumed, only delay after this new anchor is reported as missing audio.
    @discardableResult
    mutating func resumeRecording(
        _ recordingID: UUID,
        now: TimeInterval,
        audioClockTime: TimeInterval? = nil
    ) -> Bool {
        mutateRun(recordingID: recordingID) { run in
            guard run.isPaused else { return }
            run.isPaused = false
            run.callbackTimelineAnchor = now
            run.audioTimelineAnchor = audioClockTime
            run.hasAcceptedBuffer = false
            run.lastAcceptedCallbackEndTime = nil
            run.lastAcceptedAudioEndTime = nil
        }
    }

    func accepts(_ token: CaptureToken) -> Bool {
        switch phase {
        case .awaitingInitialBuffer(_, let live),
             .active(_, let live),
             .awaitingRecoveryBuffer(_, _, let live):
            return live.token == token
        case .settling(_, _, let live):
            return live?.token == token
        case .idle, .startingInitial, .rebuilding, .startingRecoveryGraph, .failed:
            return false
        }
    }

    mutating func noteConfigurationChange(now: TimeInterval) -> ConfigurationChangeDecision {
        guard activeRecordingID != nil else { return .ignored }
        diagnostics.configurationChangeCount += 1
        configurationGeneration &+= 1

        switch phase {
        case .active(let run, let live), .awaitingInitialBuffer(let run, let live):
            nextRecoveryGeneration &+= 1
            let cycle = RecoveryCycle(
                generation: nextRecoveryGeneration,
                configurationGeneration: configurationGeneration,
                reason: .inputConfigurationChanged,
                startedAt: now,
                previousInput: live.input,
                timelineEpochAtStart: run.timelineEpoch,
                startedWhilePaused: run.isPaused,
                attemptCount: 0
            )
            phase = .settling(run, cycle, live)
            return .schedule(settlementToken(for: run, cycle: cycle), delay: policy.settlementDelay)

        case .settling(let run, var cycle, let live):
            diagnostics.coalescedConfigurationChangeCount += 1
            cycle.configurationGeneration = configurationGeneration
            phase = .settling(run, cycle, live)
            return .schedule(settlementToken(for: run, cycle: cycle), delay: policy.settlementDelay)

        case .rebuilding(let run, var cycle, let token):
            diagnostics.coalescedConfigurationChangeCount += 1
            cycle.configurationGeneration = configurationGeneration
            guard cycle.attemptCount < policy.maxGraphStartAttempts else {
                return .failed(recordTerminalFailure(
                    cycle: cycle,
                    run: run,
                    message: "The microphone input changed again during the final graph rebuild."
                ))
            }
            phase = .rebuilding(run, cycle, token)
            return .coalesced

        case .startingRecoveryGraph(let run, var cycle, let live):
            diagnostics.coalescedConfigurationChangeCount += 1
            cycle.configurationGeneration = configurationGeneration
            guard cycle.attemptCount < policy.maxGraphStartAttempts else {
                return .failed(recordTerminalFailure(
                    cycle: cycle,
                    run: run,
                    message: "The microphone input changed again while the final graph was starting."
                ))
            }
            phase = .startingRecoveryGraph(run, cycle, live)
            return .coalesced

        case .awaitingRecoveryBuffer(let run, var cycle, _):
            diagnostics.coalescedConfigurationChangeCount += 1
            cycle.configurationGeneration = configurationGeneration
            if cycle.attemptCount < policy.maxGraphStartAttempts {
                phase = .settling(run, cycle, nil)
                return .schedule(
                    settlementToken(for: run, cycle: cycle),
                    delay: policy.settlementDelay
                )
            }
            // The route changed again before the final graph proved capture.
            // Accepting an in-flight callback here could forget the new route;
            // attempting another graph would make the retry budget unbounded.
            return .failed(recordTerminalFailure(
                cycle: cycle,
                run: run,
                message: "The microphone input changed again before recovery completed."
            ))

        case .idle, .startingInitial, .failed:
            return .ignored
        }
    }

    mutating func settlementElapsed(_ token: SettlementToken) -> SettlementDecision {
        guard case .settling(let run, var cycle, _) = phase,
              token.recordingID == run.recordingID,
              token.recoveryGeneration == cycle.generation,
              token.configurationGeneration == cycle.configurationGeneration,
              cycle.attemptCount < policy.maxGraphStartAttempts else {
            return .ignored
        }

        cycle.attemptCount += 1
        nextTapGeneration &+= 1
        let captureToken = CaptureToken(
            recordingID: run.recordingID,
            tapGeneration: nextTapGeneration
        )
        phase = .rebuilding(run, cycle, captureToken)
        diagnostics.graphRestartAttemptCount += 1
        return .rebuild(RestartRequest(
            settlementToken: token,
            captureToken: captureToken,
            attempt: cycle.attemptCount
        ))
    }

    mutating func graphPrepared(
        for request: RestartRequest,
        input: StreamingMicInputSnapshot
    ) -> GraphPreparedDecision {
        guard case .rebuilding(let run, let cycle, let token) = phase,
              token == request.captureToken,
              request.settlementToken.recordingID == run.recordingID,
              request.settlementToken.recoveryGeneration == cycle.generation else {
            return .ignored
        }

        if cycle.configurationGeneration != request.settlementToken.configurationGeneration,
           cycle.attemptCount < policy.maxGraphStartAttempts {
            phase = .settling(run, cycle, nil)
            return .scheduleTrailing(
                settlementToken(for: run, cycle: cycle),
                delay: policy.settlementDelay
            )
        }

        phase = .startingRecoveryGraph(
            run,
            cycle,
            LiveCapture(token: token, input: input)
        )
        return .startGraph
    }

    /// Route discovery is deliberately outside the graph-start retry budget.
    /// Bluetooth devices can remain transient for seconds without any graph
    /// mutation being attempted. Rewind the provisional attempt allocated by
    /// `settlementElapsed` and return to settlement with the same generation.
    mutating func routeStillSettling(
        for request: RestartRequest
    ) -> RecoveryFailureDecision {
        guard case .rebuilding(let run, var cycle, let token) = phase,
              token == request.captureToken,
              request.settlementToken.recordingID == run.recordingID,
              request.settlementToken.recoveryGeneration == cycle.generation,
              cycle.attemptCount > 0 else {
            return .ignored
        }

        cycle.attemptCount -= 1
        diagnostics.graphRestartAttemptCount = max(0, diagnostics.graphRestartAttemptCount - 1)
        phase = .settling(run, cycle, nil)
        return .retry(
            settlementToken(for: run, cycle: cycle),
            delay: policy.settlementDelay
        )
    }

    mutating func recoveryGraphStarted(
        for request: RestartRequest,
        input: StreamingMicInputSnapshot
    ) -> GraphStartedDecision {
        guard case .startingRecoveryGraph(let run, let cycle, let live) = phase,
              live.token == request.captureToken,
              request.settlementToken.recordingID == run.recordingID,
              request.settlementToken.recoveryGeneration == cycle.generation else {
            return .ignored
        }

        if cycle.configurationGeneration != request.settlementToken.configurationGeneration,
           cycle.attemptCount < policy.maxGraphStartAttempts {
            phase = .settling(run, cycle, nil)
            return .scheduleTrailing(
                settlementToken(for: run, cycle: cycle),
                delay: policy.settlementDelay
            )
        }

        let startedLive = LiveCapture(token: live.token, input: input)
        phase = .awaitingRecoveryBuffer(run, cycle, startedLive)
        return .awaitFirstBuffer(
            FirstBufferTimeoutToken(
                captureToken: startedLive.token,
                recoveryGeneration: cycle.generation
            ),
            delay: policy.firstBufferTimeout
        )
    }

    mutating func graphStartFailed(
        request: RestartRequest,
        message: String
    ) -> RecoveryFailureDecision {
        switch phase {
        case .rebuilding(let run, let cycle, let token) where token == request.captureToken:
            return resolveFailure(cycle: cycle, run: run, message: message)
        case .startingRecoveryGraph(let run, let cycle, let live)
            where live.token == request.captureToken:
            return resolveFailure(cycle: cycle, run: run, message: message)
        case .awaitingRecoveryBuffer(let run, let cycle, let live)
            where live.token == request.captureToken:
            return resolveFailure(cycle: cycle, run: run, message: message)
        default:
            return .ignored
        }
    }

    mutating func firstBufferTimedOut(
        _ token: FirstBufferTimeoutToken,
        now: TimeInterval
    ) -> RecoveryFailureDecision {
        switch phase {
        case .awaitingInitialBuffer(let run, let live) where live.token == token.captureToken:
            nextRecoveryGeneration &+= 1
            let cycle = RecoveryCycle(
                generation: nextRecoveryGeneration,
                configurationGeneration: configurationGeneration,
                reason: .initialBufferTimeout,
                startedAt: run.startedAt,
                previousInput: live.input,
                timelineEpochAtStart: run.timelineEpoch,
                startedWhilePaused: run.isPaused,
                attemptCount: 0
            )
            phase = .settling(run, cycle, nil)
            return .retry(
                settlementToken(for: run, cycle: cycle),
                delay: policy.retryDelay
            )

        case .awaitingRecoveryBuffer(let run, let cycle, let live)
            where live.token == token.captureToken && token.recoveryGeneration == cycle.generation:
            return resolveFailure(
                cycle: cycle,
                run: run,
                message: "Microphone capture restarted but delivered no audio buffers."
            )

        default:
            _ = now
            return .ignored
        }
    }

    /// Linearization point for an accepted audio buffer. The recorder calls
    /// this while it also owns its file-state lock, so a configuration change
    /// cannot commit a discontinuity whose proving buffer is then discarded.
    mutating func noteBuffer(
        token: CaptureToken,
        callbackTime: TimeInterval,
        audioStartTime: TimeInterval? = nil,
        sampleCount: Int,
        sampleRate: Double = 16_000
    ) -> BufferDecision {
        guard sampleCount > 0, sampleRate > 0 else { return .rejected }
        let duration = Double(sampleCount) / sampleRate

        switch phase {
        case .awaitingInitialBuffer(var run, let live) where live.token == token:
            noteAcceptedBuffer(
                run: &run,
                callbackTime: callbackTime,
                audioStartTime: audioStartTime,
                duration: duration
            )
            phase = .active(run, live)
            return .accepted

        case .active(var run, let live) where live.token == token:
            noteAcceptedBuffer(
                run: &run,
                callbackTime: callbackTime,
                audioStartTime: audioStartTime,
                duration: duration
            )
            phase = .active(run, live)
            return .accepted

        case .settling(var run, let cycle, let live?) where live.token == token:
            noteAcceptedBuffer(
                run: &run,
                callbackTime: callbackTime,
                audioStartTime: audioStartTime,
                duration: duration
            )
            phase = .settling(run, cycle, live)
            return .accepted

        case .awaitingRecoveryBuffer(var run, let cycle, let live) where live.token == token:
            let crossedTimelineBoundary = cycle.startedWhilePaused
                || cycle.timelineEpochAtStart != run.timelineEpoch
            if run.isPaused {
                noteAcceptedBuffer(
                    run: &run,
                    callbackTime: callbackTime,
                    audioStartTime: audioStartTime,
                    duration: duration
                )
                phase = .active(run, live)
                return .restoredAcrossTimelineBoundary
            }

            let missingDuration: TimeInterval
            if let audioStartTime,
               let previousAudioEnd = run.lastAcceptedAudioEndTime
                    ?? (run.hasAcceptedBuffer ? nil : run.audioTimelineAnchor) {
                missingDuration = max(0, audioStartTime - previousAudioEnd)
            } else {
                let previousCallbackEnd = run.lastAcceptedCallbackEndTime
                    ?? run.callbackTimelineAnchor
                missingDuration = max(0, callbackTime - previousCallbackEnd - duration)
            }

            let discontinuity = StreamingMicDiscontinuity(
                generation: cycle.generation,
                reason: cycle.reason,
                missingSampleCount: Int64((missingDuration * sampleRate).rounded()),
                downtimeSeconds: crossedTimelineBoundary
                    ? max(0, callbackTime - run.callbackTimelineAnchor)
                    : max(0, callbackTime - cycle.startedAt),
                restartAttemptCount: cycle.attemptCount,
                previousInput: cycle.previousInput,
                currentInput: live.input
            )
            noteAcceptedBuffer(
                run: &run,
                callbackTime: callbackTime,
                audioStartTime: audioStartTime,
                duration: duration
            )
            phase = .active(run, live)
            diagnostics.successfulRecoveryCount += 1
            diagnostics.discontinuities.append(discontinuity)
            trimDiagnosticHistory()
            return .recovered(discontinuity)

        default:
            return .rejected
        }
    }

    private var activeRecordingID: UUID? {
        switch phase {
        case .idle:
            return nil
        case .startingInitial(let run, _),
             .awaitingInitialBuffer(let run, _),
             .active(let run, _),
             .settling(let run, _, _),
             .rebuilding(let run, _, _),
             .startingRecoveryGraph(let run, _, _),
             .awaitingRecoveryBuffer(let run, _, _):
            return run.recordingID
        case .failed(let recordingID):
            return recordingID
        }
    }

    private func settlementToken(
        for run: Run,
        cycle: RecoveryCycle
    ) -> SettlementToken {
        SettlementToken(
            recordingID: run.recordingID,
            recoveryGeneration: cycle.generation,
            configurationGeneration: cycle.configurationGeneration
        )
    }

    private mutating func resolveFailure(
        cycle: RecoveryCycle,
        run: Run,
        message: String
    ) -> RecoveryFailureDecision {
        if cycle.attemptCount < policy.maxGraphStartAttempts {
            phase = .settling(run, cycle, nil)
            return .retry(
                settlementToken(for: run, cycle: cycle),
                delay: policy.retryDelay
            )
        }

        let failure = recordTerminalFailure(cycle: cycle, run: run, message: message)
        return .failed(failure)
    }

    private mutating func recordTerminalFailure(
        cycle: RecoveryCycle,
        run: Run,
        message: String
    ) -> StreamingMicCaptureFailure {
        let failure = StreamingMicCaptureFailure(
            generation: cycle.generation,
            reason: cycle.reason,
            restartAttemptCount: cycle.attemptCount,
            previousInput: cycle.previousInput,
            message: message
        )
        phase = .failed(run.recordingID)
        diagnostics.failedRecoveryCount += 1
        diagnostics.failures.append(failure)
        trimDiagnosticHistory()
        return failure
    }

    private func noteAcceptedBuffer(
        run: inout Run,
        callbackTime: TimeInterval,
        audioStartTime: TimeInterval?,
        duration: TimeInterval
    ) {
        guard !run.isPaused else { return }
        run.hasAcceptedBuffer = true
        run.lastAcceptedCallbackEndTime = callbackTime
        if let audioStartTime {
            run.lastAcceptedAudioEndTime = audioStartTime + duration
        } else {
            run.lastAcceptedAudioEndTime = nil
        }
    }

    /// Rewrites only the `Run` payload while preserving the coordinator's
    /// exact lifecycle phase and all generation tokens.
    @discardableResult
    private mutating func mutateRun(
        recordingID: UUID,
        _ mutation: (inout Run) -> Void
    ) -> Bool {
        switch phase {
        case .startingInitial(var run, let live):
            guard run.recordingID == recordingID else { return false }
            mutation(&run)
            phase = .startingInitial(run, live)
        case .awaitingInitialBuffer(var run, let live):
            guard run.recordingID == recordingID else { return false }
            mutation(&run)
            phase = .awaitingInitialBuffer(run, live)
        case .active(var run, let live):
            guard run.recordingID == recordingID else { return false }
            mutation(&run)
            phase = .active(run, live)
        case .settling(var run, let cycle, let live):
            guard run.recordingID == recordingID else { return false }
            mutation(&run)
            phase = .settling(run, cycle, live)
        case .rebuilding(var run, let cycle, let token):
            guard run.recordingID == recordingID else { return false }
            mutation(&run)
            phase = .rebuilding(run, cycle, token)
        case .startingRecoveryGraph(var run, let cycle, let live):
            guard run.recordingID == recordingID else { return false }
            mutation(&run)
            phase = .startingRecoveryGraph(run, cycle, live)
        case .awaitingRecoveryBuffer(var run, let cycle, let live):
            guard run.recordingID == recordingID else { return false }
            mutation(&run)
            phase = .awaitingRecoveryBuffer(run, cycle, live)
        case .idle, .failed:
            return false
        }
        return true
    }

    private mutating func trimDiagnosticHistory() {
        let maximumEvents = 16
        if diagnostics.discontinuities.count > maximumEvents {
            diagnostics.discontinuities.removeFirst(diagnostics.discontinuities.count - maximumEvents)
        }
        if diagnostics.failures.count > maximumEvents {
            diagnostics.failures.removeFirst(diagnostics.failures.count - maximumEvents)
        }
    }
}
