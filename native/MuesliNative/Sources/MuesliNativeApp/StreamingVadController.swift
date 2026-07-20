import FluidAudio
import Foundation
import os

/// Bridges real-time meeting audio to VadManager's streaming API.
///
/// The key requirement here is single-flight state ownership: exactly one chunk
/// may be processed against the mutable stream state at a time. Chunks can
/// arrive faster than VAD inference finishes, so we queue them and drain
/// serially rather than spawning overlapping Tasks that race the same state.
final class StreamingVadController: @unchecked Sendable {
    /// Called when VAD detects a natural chunk boundary.
    ///
    /// The generation is a revocable ticket for this boundary decision. A
    /// handler that forwards the decision across another asynchronous queue
    /// must revalidate it there with `isBoundaryGenerationCurrent(_:)` before
    /// mutating timeline state.
    var onChunkBoundary: ((Int) -> Void)?

    private struct State {
        var generation = 0
        var drainerEpoch = 0
        var isActive = false
        var isDraining = false
        var pendingChunks: [[Float]] = []
        var streamState: VadStreamState?
        var lastRotationTime: Date?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let makeInitialState: @Sendable () async -> VadStreamState
    private let processStreamChunk: @Sendable ([Float], VadStreamState) async throws -> VadStreamResult
    private let scheduleBoundary: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let logger = Logger(subsystem: "com.muesli.native", category: "StreamingVadController")

    /// Minimum chunk duration before allowing rotation (prevents rapid flipping).
    private let minChunkDuration: TimeInterval
    /// Maximum chunk duration before forcing rotation (safety cap).
    private let maxChunkDuration: TimeInterval
    private var maxDurationTimer: Timer?

    convenience init(vadManager: VadManager) {
        self.init(
            minChunkDuration: 3.0,
            // Keep live transcript latency bounded by forcing shorter meeting chunks.
            maxChunkDuration: 5.0,
            makeInitialState: { await vadManager.makeStreamState() },
            processStreamChunk: { samples, state in
                try await vadManager.processStreamingChunk(samples, state: state)
            }
        )
    }

    internal init(
        minChunkDuration: TimeInterval,
        maxChunkDuration: TimeInterval,
        makeInitialState: @escaping @Sendable () async -> VadStreamState,
        processStreamChunk: @escaping @Sendable ([Float], VadStreamState) async throws -> VadStreamResult,
        scheduleBoundary: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in
            DispatchQueue.main.async(execute: work)
        }
    ) {
        self.minChunkDuration = minChunkDuration
        self.maxChunkDuration = maxChunkDuration
        self.makeInitialState = makeInitialState
        self.processStreamChunk = processStreamChunk
        self.scheduleBoundary = scheduleBoundary
    }

    func start() {
        let startGeneration = lock.withLock { state -> Int? in
            guard !state.isActive else { return nil }
            state.generation += 1
            state.isActive = true
            state.isDraining = false
            state.pendingChunks.removeAll(keepingCapacity: true)
            state.streamState = nil
            state.lastRotationTime = Date()
            return state.generation
        }
        guard let startGeneration else { return }

        Task { [weak self] in
            guard let self else { return }
            let initialState = await self.makeInitialState()
            let shouldKickDrain = self.lock.withLock { state in
                guard state.isActive, state.generation == startGeneration else { return false }
                state.streamState = initialState
                return !state.pendingChunks.isEmpty
            }
            if shouldKickDrain {
                self.startDrainIfNeeded()
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.maxDurationTimer?.invalidate()
            guard self.lock.withLock({ $0.isActive && $0.generation == startGeneration }) else { return }
            self.maxDurationTimer = Timer.scheduledTimer(withTimeInterval: self.maxChunkDuration, repeats: true) { [weak self] _ in
                self?.handleMaxDurationTimer()
            }
        }
    }

    func stop() {
        let stopGeneration = lock.withLock { state in
            state.isActive = false
            state.pendingChunks.removeAll(keepingCapacity: false)
            state.streamState = nil
            return state.generation
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.lock.withLock({ !$0.isActive && $0.generation == stopGeneration }) else { return }
            self.maxDurationTimer?.invalidate()
            self.maxDurationTimer = nil
        }
    }

    /// Reset streaming inference at a microphone timeline discontinuity while
    /// keeping the controller active. Generation and drainer-epoch bumps make
    /// queued or in-flight pre-gap results unable to mutate the new stream.
    func resetForDiscontinuity() {
        let resetGeneration = lock.withLock { state -> Int? in
            guard state.isActive else { return nil }
            state.generation += 1
            state.drainerEpoch += 1
            state.isDraining = false
            state.pendingChunks.removeAll(keepingCapacity: true)
            state.streamState = nil
            state.lastRotationTime = Date()
            return state.generation
        }
        guard let resetGeneration else { return }

        Task { [weak self] in
            guard let self else { return }
            let initialState = await self.makeInitialState()
            let shouldKickDrain = self.lock.withLock { state in
                guard state.isActive, state.generation == resetGeneration else { return false }
                state.streamState = initialState
                return !state.pendingChunks.isEmpty
            }
            if shouldKickDrain {
                self.startDrainIfNeeded()
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.lock.withLock({ $0.isActive && $0.generation == resetGeneration }) else { return }
            self.maxDurationTimer?.fireDate = Date().addingTimeInterval(self.maxChunkDuration)
        }
    }

    /// Feed a chunk of Float audio samples (typically 4096 samples = 256ms at 16kHz).
    func processAudio(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        let shouldStart = lock.withLock { state in
            guard state.isActive else { return false }
            state.pendingChunks.append(samples)
            return state.streamState != nil && !state.isDraining
        }

        if shouldStart {
            startDrainIfNeeded()
        }
    }

    /// Notify that an external rotation just happened.
    func notifyRotation() {
        let generation = lock.withLock { state -> Int? in
            guard state.isActive else { return nil }
            state.lastRotationTime = Date()
            return state.generation
        }
        guard let generation else { return }
        resetMaxDurationTimer(for: generation)
    }

    /// Kept internal so the max-duration path can be exercised without relying
    /// on wall-clock timer scheduling in deterministic tests.
    func handleMaxDurationTimer() {
        let boundaryGeneration = lock.withLock { state -> Int? in
            guard state.isActive else { return nil }
            let now = Date()
            let elapsed = now.timeIntervalSince(state.lastRotationTime ?? now)
            guard elapsed >= self.minChunkDuration else { return nil }
            state.lastRotationTime = now
            return state.generation
        }
        guard let boundaryGeneration else { return }
        fputs("[vad] max chunk duration reached, forcing rotation\n", stderr)
        scheduleBoundaryDelivery(generation: boundaryGeneration)
    }

    private func startDrainIfNeeded() {
        let drainerEpoch = lock.withLock { state -> Int? in
            guard state.isActive, state.streamState != nil, !state.isDraining else { return nil }
            guard !state.pendingChunks.isEmpty else { return nil }
            state.drainerEpoch += 1
            state.isDraining = true
            return state.drainerEpoch
        }
        guard let drainerEpoch else { return }

        Task { [weak self] in
            await self?.drainQueue(drainerEpoch: drainerEpoch)
        }
    }

    private func drainQueue(drainerEpoch: Int) async {
        while true {
            let next: (generation: Int, chunk: [Float], streamState: VadStreamState)? = lock.withLock { state in
                guard state.isActive, state.isDraining, state.drainerEpoch == drainerEpoch else {
                    if !state.isActive {
                        state.isDraining = false
                        state.pendingChunks.removeAll(keepingCapacity: false)
                    }
                    return nil
                }
                guard let streamState = state.streamState else {
                    state.isDraining = false
                    return nil
                }
                guard !state.pendingChunks.isEmpty else {
                    state.isDraining = false
                    return nil
                }
                return (state.generation, state.pendingChunks.removeFirst(), streamState)
            }

            guard let next else { return }

            do {
                let result = try await processStreamChunk(next.chunk, next.streamState)

                let boundaryGeneration = lock.withLock { state -> Int? in
                    guard state.isActive, state.generation == next.generation else { return nil }
                    state.streamState = result.state

                    guard let event = result.event, event.kind == .speechEnd else {
                        return nil
                    }

                    let now = Date()
                    let elapsed = now.timeIntervalSince(state.lastRotationTime ?? now)
                    guard elapsed >= self.minChunkDuration else { return nil }
                    state.lastRotationTime = now
                    return state.generation
                }

                if let boundaryGeneration {
                    fputs("[vad] speech end detected, rotating chunk\n", stderr)
                    scheduleBoundaryDelivery(generation: boundaryGeneration)
                }
            } catch {
                logger.error("streaming VAD chunk failed: \(String(describing: error), privacy: .public)")
                fputs("[vad] streaming chunk failed: \(error)\n", stderr)
            }
        }
    }

    /// Revalidation for consumers that forward a boundary over another queue.
    /// This closes the window where discontinuity reset or stop/restart occurs
    /// after controller delivery but before the consumer mutates its timeline.
    func isBoundaryGenerationCurrent(_ generation: Int) -> Bool {
        lock.withLock { state in
            state.isActive && state.generation == generation
        }
    }

    private func scheduleBoundaryDelivery(generation: Int) {
        scheduleBoundary { [weak self] in
            guard let self,
                  self.isBoundaryGenerationCurrent(generation) else { return }
            self.onChunkBoundary?(generation)
            self.resetMaxDurationTimer(for: generation)
        }
    }

    private func resetMaxDurationTimer(for generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isBoundaryGenerationCurrent(generation) else { return }
            self.maxDurationTimer?.fireDate = Date().addingTimeInterval(self.maxChunkDuration)
        }
    }
}
