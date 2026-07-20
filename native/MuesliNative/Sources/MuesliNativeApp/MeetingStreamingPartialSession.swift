import AVFoundation
import FluidAudio
import Foundation
import os

enum MeetingLiveCaptionModelStore {
    static let repo = Repo.parakeetEou320
    static let sizeLabel = "~430 MB"
    static let label = "Parakeet Realtime EOU"

    static func cacheRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    static func modelDirectory(fileManager: FileManager = .default) -> URL {
        modelDirectory(in: cacheRoot(fileManager: fileManager))
    }

    static func isDownloaded(fileManager: FileManager = .default) -> Bool {
        isDownloaded(in: cacheRoot(fileManager: fileManager), fileManager: fileManager)
    }

    static func modelDirectory(in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    static func isDownloaded(in cacheRoot: URL, fileManager: FileManager = .default) -> Bool {
        let directory = modelDirectory(in: cacheRoot)
        return ModelNames.ParakeetEOU.requiredModels.allSatisfy {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func download(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await DownloadUtils.downloadRepo(repo, to: cacheRoot()) { update in
            progress?(update.fractionCompleted)
        }
    }

    static func delete(fileManager: FileManager = .default) throws {
        let directory = modelDirectory(fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    static func makeEngine(label: String) async throws -> MeetingStreamingPartialEngine {
        let engine = ParakeetEOUMeetingPartialEngine(label: label)
        try await engine.loadModels(from: modelDirectory())
        return engine
    }

    static func makeEngines(
        backend: MeetingLiveCaptionBackend,
        nemotronPromptId: Int32
    ) async throws -> (mic: MeetingStreamingPartialEngine, system: MeetingStreamingPartialEngine) {
        switch backend {
        case .parakeetRealtimeEOU:
            let mic = try await makeEngine(label: "You")
            do {
                return (mic, try await makeEngine(label: "Others"))
            } catch {
                await mic.shutdown()
                throw error
            }
        case .nemotron35:
            guard #available(macOS 15, *) else {
                throw NSError(
                    domain: "MeetingLiveCaptions",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Nemotron 3.5 requires macOS 15 or later."]
                )
            }
            let transcriber = Nemotron35StreamingTranscriber()
            await transcriber.setPromptId(nemotronPromptId)
            try await transcriber.loadModels()
            let mic = Nemotron35MeetingPartialEngine(transcriber: transcriber, label: "You")
            let system = Nemotron35MeetingPartialEngine(transcriber: transcriber, label: "Others")
            do {
                try await mic.prepare()
                try await system.prepare()
                return (mic, system)
            } catch {
                await mic.shutdown()
                await system.shutdown()
                await transcriber.shutdown()
                throw error
            }
        }
    }
}

protocol MeetingStreamingPartialEngine: AnyObject, Sendable {
    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async
    func process(samples: [Float]) async throws
    func resetForDiscontinuity() async throws
    func finish() async throws
    func shutdown() async
}

extension MeetingStreamingPartialEngine {
    func resetForDiscontinuity() async throws {}
    func finish() async throws {}
}

private actor ParakeetEOUMeetingPartialEngine: MeetingStreamingPartialEngine {
    private let manager = StreamingEouAsrManager(chunkSize: .ms320)
    private let label: String

    init(label: String) {
        self.label = label
    }

    func loadModels(from directory: URL) async throws {
        try await manager.loadModels(from: directory)
    }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialCallback(handler)
    }

    func process(samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw NSError(
                domain: "MeetingLiveCaptions",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate a 16 kHz live-caption buffer."]
            )
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        _ = try await manager.process(audioBuffer: buffer)
    }

    func resetForDiscontinuity() async throws {
        await manager.reset()
    }

    func shutdown() async {
        await manager.cleanup()
        fputs("[meeting-partials] \(label) Parakeet EOU session stopped\n", stderr)
    }
}

/// Small value-type gate kept separate from the model implementation so the
/// generation rule protecting actor-reentrant Nemotron calls is deterministic
/// and unit testable without loading model artifacts.
struct NemotronMeetingPartialLifecycle: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var isShutdown = false

    var operationGeneration: UInt64? {
        isShutdown ? nil : generation
    }

    mutating func beginReset() -> UInt64? {
        guard !isShutdown else { return nil }
        generation &+= 1
        return generation
    }

    mutating func shutDown() -> Bool {
        guard !isShutdown else { return false }
        isShutdown = true
        generation &+= 1
        return true
    }

    func admits(_ operationGeneration: UInt64) -> Bool {
        !isShutdown && operationGeneration == generation
    }
}

@available(macOS 15, *)
private actor Nemotron35MeetingPartialEngine: MeetingStreamingPartialEngine {
    private let transcriber: Nemotron35StreamingTranscriber
    private let label: String
    private var streamState: Nemotron35StreamingTranscriber.StreamState?
    private var sampleBuffer: [Float] = []
    private var transcript = ""
    private var partialHandler: (@Sendable (String) -> Void)?
    /// Every operation that suspends while calling the shared transcriber must
    /// prove that it still belongs to the current engine lifecycle before it
    /// writes actor state. Actor reentrancy otherwise lets a late process/reset
    /// continuation recreate stream state after `shutdown()` cleared it.
    private var lifecycle = NemotronMeetingPartialLifecycle()

    init(transcriber: Nemotron35StreamingTranscriber, label: String) {
        self.transcriber = transcriber
        self.label = label
    }

    func prepare() async throws {
        guard let generation = lifecycle.operationGeneration else {
            throw CancellationError()
        }
        let preparedState = try await transcriber.makeStreamState()
        guard lifecycle.admits(generation) else {
            throw CancellationError()
        }
        streamState = preparedState
    }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        guard !lifecycle.isShutdown else { return }
        partialHandler = handler
    }

    func process(samples: [Float]) async throws {
        guard let generation = lifecycle.operationGeneration, !samples.isEmpty else { return }
        sampleBuffer.append(contentsOf: samples)
        let chunkSize = transcriber.chunkSamples
        while sampleBuffer.count >= chunkSize {
            guard lifecycle.admits(generation) else { return }
            let chunk = Array(sampleBuffer.prefix(chunkSize))
            sampleBuffer.removeFirst(chunkSize)
            guard var state = streamState else {
                throw Nemotron35StreamingTranscriber.TranscriberError.notLoaded
            }
            let text = try await transcriber.transcribeChunk(samples: chunk, state: &state)
            guard lifecycle.admits(generation) else { return }
            streamState = state
            guard !text.isEmpty else { continue }
            transcript += text
            partialHandler?(transcript)
        }
    }

    func finish() async throws {
        guard let generation = lifecycle.operationGeneration, !sampleBuffer.isEmpty else { return }
        let chunkSize = transcriber.chunkSamples
        sampleBuffer.append(contentsOf: repeatElement(0, count: max(chunkSize - sampleBuffer.count, 0)))
        if sampleBuffer.count >= chunkSize {
            let chunk = Array(sampleBuffer.prefix(chunkSize))
            sampleBuffer.removeFirst(chunkSize)
            guard var state = streamState else {
                throw Nemotron35StreamingTranscriber.TranscriberError.notLoaded
            }
            let text = try await transcriber.transcribeChunk(samples: chunk, state: &state)
            guard lifecycle.admits(generation) else { return }
            streamState = state
            if !text.isEmpty {
                transcript += text
                partialHandler?(transcript)
            }
        }
    }

    func resetForDiscontinuity() async throws {
        guard let generation = lifecycle.beginReset() else { throw CancellationError() }
        sampleBuffer.removeAll(keepingCapacity: true)
        transcript = ""
        streamState = nil
        let resetState = try await transcriber.makeStreamState()
        guard lifecycle.admits(generation) else {
            throw CancellationError()
        }
        streamState = resetState
    }

    func shutdown() async {
        guard lifecycle.shutDown() else { return }
        sampleBuffer.removeAll()
        transcript = ""
        streamState = nil
        partialHandler = nil
        fputs("[meeting-partials] \(label) Nemotron 3.5 session stopped\n", stderr)
    }
}

/// Display-only streaming partials for one meeting audio source ("You" or "Others").
///
/// The session receives the same 16 kHz samples as the existing meeting VAD and
/// chunk recorders. Parakeet EOU supplies a low-latency cumulative transcript,
/// while VAD rotation and durable chunk transcription remain authoritative:
/// `markSegmentBoundary(id:)` freezes the provisional prefix and
/// `commitSegment(id:)` removes it only after that chunk retires.
final class MeetingStreamingPartialSession: @unchecked Sendable {
    /// Called with the current provisional tail text on a background thread.
    /// An empty string clears the tail.
    var onPartialUpdate: ((String) -> Void)? {
        get { partialUpdateHandler.withLock { $0 } }
        set { partialUpdateHandler.withLock { $0 = newValue } }
    }

    /// Feed the EOU manager at its 320 ms shift cadence. The manager retains the
    /// larger look-ahead window required by its cache-aware encoder.
    static let feedSamples = StreamingChunkSize.ms320.shiftSamples
    static let maxQueuedChunks = 3
    static let publicationIntervalNanoseconds: UInt64 = 250_000_000
    static let finishDrainTimeoutNanoseconds: UInt64 = 30_000_000_000
    static let shutdownGraceNanoseconds: UInt64 = 250_000_000

    private let engine: MeetingStreamingPartialEngine
    private let label: String
    private let shutdownGraceNanoseconds: UInt64
    private let scheduledPublicationDidPrepare: (@Sendable () -> Void)?

    private struct PendingSegment {
        let id: UUID
        let transcriptEpoch: UInt64
        let prefixLength: Int
        var isCommitted = false
        let frozenText: String
    }

    private struct State {
        var sampleBuffer: [Float] = []
        var chunkQueue: [[Float]] = []
        var isDraining = false
        var engineText = ""
        var committedPrefixLength = 0
        var pendingSegments: [PendingSegment] = []
        var isStopped = false
        var isSuspended = false
        var didFail = false
        var pendingPublicationTail: String?
        var pendingPublicationLifecycleRevision: UInt64?
        var lastPublishedTail: String?
        var lastDeliveredTail: String?
        var isPublicationScheduled = false
        var publicationRevision: UInt64 = 0
        var lifecycleRevision: UInt64 = 0
        var activeInferenceRevision: UInt64?
        var isResettingForDiscontinuity = false
        var pendingResetRevision: UInt64?
        var transcriptEpoch: UInt64 = 0
        var isShutdownRequested = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let partialUpdateHandler = OSAllocatedUnfairLock<((String) -> Void)?>(initialState: nil)
    private let publicationQueue = DispatchQueue(label: "com.muesli.meeting-partials.publication")

    private struct Publication: Sendable {
        let tail: String
        let lifecycleRevision: UInt64
        let publicationRevision: UInt64
    }

    init(
        engine: MeetingStreamingPartialEngine,
        label: String,
        shutdownGraceNanoseconds: UInt64 = MeetingStreamingPartialSession.shutdownGraceNanoseconds,
        scheduledPublicationDidPrepare: (@Sendable () -> Void)? = nil
    ) {
        self.engine = engine
        self.label = label
        self.shutdownGraceNanoseconds = shutdownGraceNanoseconds
        self.scheduledPublicationDidPrepare = scheduledPublicationDidPrepare
    }

    func connect() async {
        await engine.setPartialHandler { [weak self] text in
            self?.receiveEnginePartial(text)
        }
    }

    /// Cheap append called from the existing meeting audio queue. Inference is
    /// single-flight and bounded so provisional captions cannot delay recording.
    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let shouldStartDrain = state.withLock { s -> Bool in
            guard !s.isStopped, !s.isSuspended, !s.didFail else { return false }
            s.sampleBuffer.append(contentsOf: samples)
            while s.sampleBuffer.count >= Self.feedSamples {
                s.chunkQueue.append(Array(s.sampleBuffer.prefix(Self.feedSamples)))
                s.sampleBuffer.removeFirst(Self.feedSamples)
            }
            if s.chunkQueue.count > Self.maxQueuedChunks {
                s.chunkQueue.removeFirst(s.chunkQueue.count - Self.maxQueuedChunks)
            }
            guard !s.isResettingForDiscontinuity else { return false }
            guard !s.chunkQueue.isEmpty, !s.isDraining else { return false }
            s.isDraining = true
            return true
        }
        if shouldStartDrain {
            Task.detached(priority: .utility) { [weak self] in
                await self?.drain()
            }
        }
    }

    func markSegmentBoundary(id: UUID) {
        state.withLock { s in
            let previousPrefixLength = s.pendingSegments.last(where: {
                $0.transcriptEpoch == s.transcriptEpoch
            })?.prefixLength ?? s.committedPrefixLength
            let startOffset = min(previousPrefixLength, s.engineText.count)
            let endOffset = s.engineText.count
            let frozenText: String
            if endOffset > startOffset {
                let start = s.engineText.index(s.engineText.startIndex, offsetBy: startOffset)
                frozenText = String(s.engineText[start...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                frozenText = ""
            }
            s.pendingSegments.append(PendingSegment(
                id: id,
                transcriptEpoch: s.transcriptEpoch,
                prefixLength: endOffset,
                frozenText: frozenText
            ))
        }
    }

    /// Drop sub-frame audio that straddles a microphone route discontinuity.
    /// Existing durable segment boundaries remain intact, while lifecycle
    /// revision validation suppresses any in-flight pre-gap partial update.
    func markDiscontinuity() {
        let shouldStartReset = state.withLock { s -> Bool in
            guard !s.isStopped, !s.isSuspended, !s.didFail else { return false }
            s.lifecycleRevision &+= 1
            s.transcriptEpoch &+= 1
            s.sampleBuffer.removeAll(keepingCapacity: true)
            s.chunkQueue.removeAll(keepingCapacity: true)
            s.engineText = ""
            s.committedPrefixLength = 0
            s.pendingPublicationTail = nil
            s.pendingPublicationLifecycleRevision = nil
            s.pendingResetRevision = s.lifecycleRevision
            guard !s.isResettingForDiscontinuity else { return false }
            s.isResettingForDiscontinuity = true
            return true
        }
        publishImmediately("")
        if shouldStartReset {
            Task.detached(priority: .utility) { [weak self] in
                await self?.resetEngineForDiscontinuity()
            }
        }
    }

    func pendingSegmentText(id: UUID) -> String? {
        state.withLock { s in
            guard !s.isStopped, !s.didFail,
                  let segmentIndex = s.pendingSegments.firstIndex(where: { $0.id == id }) else { return nil }
            let segment = s.pendingSegments[segmentIndex]
            return segment.frozenText.isEmpty ? nil : segment.frozenText
        }
    }

    func commitSegment(id: UUID) {
        let publication: Publication? = state.withLock { s in
            guard !s.isStopped, !s.isSuspended, !s.didFail else { return nil }
            guard let segmentIndex = s.pendingSegments.firstIndex(where: { $0.id == id }) else { return nil }
            s.pendingSegments[segmentIndex].isCommitted = true
            var didAdvance = false
            while let first = s.pendingSegments.first, first.isCommitted {
                if first.transcriptEpoch == s.transcriptEpoch {
                    s.committedPrefixLength = max(
                        s.committedPrefixLength,
                        min(first.prefixLength, s.engineText.count)
                    )
                }
                s.pendingSegments.removeFirst()
                didAdvance = true
            }
            guard didAdvance else { return nil }
            return preparePublicationLocked(
                visibleTail(for: s),
                expectedLifecycleRevision: s.lifecycleRevision,
                state: &s
            )
        }
        if let publication {
            enqueuePreparedPublication(publication)
        }
    }

    /// Pause is a transcript epoch boundary, not just a UI suppression flag.
    ///
    /// A model inference may still be running when capture reaches its pause
    /// barrier. Advancing the lifecycle revision fences that callback
    /// immediately, while the asynchronous reset waits for the in-flight call
    /// to leave the engine before clearing its cumulative decoder state. Audio
    /// accepted after an early resume remains buffered behind that reset.
    func suspend() {
        let shouldStartReset = state.withLock { s -> Bool in
            guard !s.isStopped, !s.didFail, !s.isSuspended else { return false }
            s.isSuspended = true
            s.lifecycleRevision &+= 1
            s.transcriptEpoch &+= 1
            s.sampleBuffer.removeAll(keepingCapacity: true)
            s.chunkQueue.removeAll(keepingCapacity: true)
            s.engineText = ""
            s.committedPrefixLength = 0
            s.pendingSegments.removeAll(keepingCapacity: true)
            s.pendingPublicationTail = nil
            s.pendingPublicationLifecycleRevision = nil
            s.pendingResetRevision = s.lifecycleRevision
            guard !s.isResettingForDiscontinuity else { return false }
            s.isResettingForDiscontinuity = true
            return true
        }
        publishImmediately("")
        if shouldStartReset {
            Task.detached(priority: .utility) { [weak self] in
                await self?.resetEngineForDiscontinuity()
            }
        }
    }

    func resume() {
        state.withLock { s in
            guard !s.isStopped, !s.didFail, s.isSuspended else { return }
            s.isSuspended = false
        }
    }

    func finish(
        drainTimeoutNanoseconds: UInt64 = MeetingStreamingPartialSession.finishDrainTimeoutNanoseconds
    ) async -> String? {
        let drainDeadline = DispatchTime.now().uptimeNanoseconds &+ drainTimeoutNanoseconds
        while true {
            let drainState = state.withLock { s -> (ready: Bool, startDrain: Bool, terminal: Bool) in
                guard !s.isStopped, !s.isSuspended, !s.didFail else {
                    return (false, false, true)
                }
                guard !s.isResettingForDiscontinuity else {
                    return (false, false, false)
                }
                if !s.sampleBuffer.isEmpty {
                    s.sampleBuffer.append(contentsOf: repeatElement(
                        0,
                        count: Self.feedSamples - s.sampleBuffer.count
                    ))
                    s.chunkQueue.append(s.sampleBuffer)
                    s.sampleBuffer.removeAll(keepingCapacity: true)
                }
                let startDrain = !s.chunkQueue.isEmpty && !s.isDraining
                if startDrain {
                    s.isDraining = true
                }
                return (!s.isDraining && s.chunkQueue.isEmpty, startDrain, false)
            }
            if drainState.terminal { return nil }
            if drainState.startDrain {
                Task.detached(priority: .utility) { [weak self] in
                    await self?.drain()
                }
            }
            if drainState.ready { break }
            guard DispatchTime.now().uptimeNanoseconds < drainDeadline else {
                goDormant(error: NSError(
                    domain: "MeetingStreamingPartialSession",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out finalizing live transcript audio."]
                ))
                return nil
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let finishRevision = state.withLock { s -> UInt64 in
            s.activeInferenceRevision = s.lifecycleRevision
            return s.lifecycleRevision
        }
        do {
            try await engine.finish()
        } catch {
            goDormant(error: error, completedInference: true)
            return nil
        }
        state.withLock { s in
            if s.activeInferenceRevision == finishRevision {
                s.activeInferenceRevision = nil
            }
        }
        return state.withLock { s in
            let text = visibleTail(for: s).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    func stop() {
        state.withLock { s in
            s.isStopped = true
            s.lifecycleRevision &+= 1
            s.sampleBuffer.removeAll()
            s.chunkQueue.removeAll()
            s.engineText = ""
            s.committedPrefixLength = 0
            s.pendingSegments.removeAll()
            s.pendingPublicationTail = nil
            s.pendingPublicationLifecycleRevision = nil
            s.pendingResetRevision = nil
        }
        publishImmediately("")
        requestEngineShutdown()
    }

    private func drain() async {
        while true {
            let work: (chunk: [Float], revision: UInt64)? = state.withLock { s in
                guard !s.isStopped, !s.isSuspended, !s.didFail,
                      !s.isResettingForDiscontinuity, !s.chunkQueue.isEmpty else {
                    s.isDraining = false
                    return nil
                }
                let revision = s.lifecycleRevision
                s.activeInferenceRevision = revision
                return (s.chunkQueue.removeFirst(), revision)
            }
            guard let work else { return }

            do {
                try await engine.process(samples: work.chunk)
                state.withLock { s in
                    if s.activeInferenceRevision == work.revision {
                        s.activeInferenceRevision = nil
                    }
                }
            } catch {
                goDormant(error: error, completedInference: true)
                return
            }
        }
    }

    private func receiveEnginePartial(_ text: String) {
        let filteredText = TranscriptionEngineArtifactsFilter.apply(text)
        let tail: String? = state.withLock { s in
            guard !s.isStopped, !s.isSuspended, !s.didFail,
                  !s.isResettingForDiscontinuity,
                  s.activeInferenceRevision == s.lifecycleRevision else { return nil }
            if filteredText.count < s.committedPrefixLength {
                s.committedPrefixLength = 0
                s.pendingSegments.removeAll { $0.transcriptEpoch == s.transcriptEpoch }
            }
            s.engineText = filteredText
            return visibleTail(for: s)
        }
        if let tail {
            schedulePublication(tail)
        }
    }

    private func goDormant(
        error: Error,
        completedInference: Bool = false,
        completedReset: Bool = false
    ) {
        state.withLock { s in
            s.didFail = true
            s.lifecycleRevision &+= 1
            s.isDraining = false
            s.sampleBuffer.removeAll()
            s.chunkQueue.removeAll()
            s.engineText = ""
            s.committedPrefixLength = 0
            s.pendingSegments.removeAll()
            s.pendingPublicationTail = nil
            s.pendingPublicationLifecycleRevision = nil
            if completedInference {
                s.activeInferenceRevision = nil
            }
            if completedReset {
                s.isResettingForDiscontinuity = false
                s.pendingResetRevision = nil
            }
        }
        fputs("[meeting-partials] \(label) session dormant after error: \(error)\n", stderr)
        publishImmediately("")
        requestEngineShutdown()
    }

    /// Core ML may produce partials faster than SwiftUI can lay out a long live
    /// transcript. Keep one delayed publication per source and replace its
    /// payload with the newest tail instead of queueing main-actor work.
    private func schedulePublication(_ tail: String) {
        let shouldSchedule = state.withLock { s -> Bool in
            guard !s.isStopped, !s.isSuspended, !s.didFail else { return false }
            guard tail != s.lastPublishedTail || s.pendingPublicationTail != nil else { return false }
            s.pendingPublicationTail = tail
            s.pendingPublicationLifecycleRevision = s.lifecycleRevision
            guard !s.isPublicationScheduled else { return false }
            s.isPublicationScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: Self.publicationIntervalNanoseconds)
            self?.flushScheduledPublication()
        }
    }

    private func flushScheduledPublication() {
        let publication: Publication? = state.withLock { s in
            s.isPublicationScheduled = false
            guard !s.isStopped, !s.isSuspended, !s.didFail,
                  let tail = s.pendingPublicationTail,
                  let lifecycleRevision = s.pendingPublicationLifecycleRevision,
                  lifecycleRevision == s.lifecycleRevision else {
                s.pendingPublicationTail = nil
                s.pendingPublicationLifecycleRevision = nil
                return nil
            }
            s.pendingPublicationTail = nil
            s.pendingPublicationLifecycleRevision = nil
            return preparePublicationLocked(
                tail,
                expectedLifecycleRevision: lifecycleRevision,
                state: &s
            )
        }
        guard let publication else { return }
        scheduledPublicationDidPrepare?()
        enqueuePreparedPublication(publication)
    }

    private func publishImmediately(_ tail: String) {
        enqueuePublication(
            tail,
            expectedLifecycleRevision: nil
        )
    }

    private func enqueuePublication(
        _ tail: String,
        expectedLifecycleRevision: UInt64?
    ) {
        let publication: Publication? = state.withLock { s in
            preparePublicationLocked(
                tail,
                expectedLifecycleRevision: expectedLifecycleRevision,
                state: &s
            )
        }
        guard let publication else { return }
        enqueuePreparedPublication(publication)
    }

    private func preparePublicationLocked(
        _ tail: String,
        expectedLifecycleRevision: UInt64?,
        state: inout State
    ) -> Publication? {
        if let expectedLifecycleRevision,
           expectedLifecycleRevision != state.lifecycleRevision {
            return nil
        }
        state.pendingPublicationTail = nil
        state.pendingPublicationLifecycleRevision = nil
        state.publicationRevision &+= 1
        let publicationRevision = state.publicationRevision
        state.lastPublishedTail = tail

        // If this value has already reached the observer, incrementing the
        // token above is still required to invalidate any older queued
        // delivery, but another duplicate callback is unnecessary.
        guard tail != state.lastDeliveredTail else { return nil }
        return Publication(
            tail: tail,
            lifecycleRevision: state.lifecycleRevision,
            publicationRevision: publicationRevision
        )
    }

    private func enqueuePreparedPublication(_ publication: Publication) {
        let delivery: @Sendable () -> Void = { [weak self] in
            self?.deliver(publication)
        }
        publicationQueue.async(execute: delivery)
    }

    private func deliver(_ publication: Publication) {
        let shouldDeliver = state.withLock { s -> Bool in
            guard s.publicationRevision == publication.publicationRevision,
                  s.lifecycleRevision == publication.lifecycleRevision,
                  s.lastDeliveredTail != publication.tail else { return false }
            s.lastDeliveredTail = publication.tail
            return true
        }
        if shouldDeliver {
            partialUpdateHandler.withLock { $0 }?(publication.tail)
        }
    }

    private func visibleTail(for state: State) -> String {
        let dropCount = min(state.committedPrefixLength, state.engineText.count)
        return String(state.engineText.dropFirst(dropCount))
    }

    private func resetEngineForDiscontinuity() async {
        while true {
            while state.withLock({ !$0.isStopped && $0.activeInferenceRevision != nil }) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let revision = state.withLock({ s -> UInt64? in
                guard !s.isStopped, !s.didFail else {
                    s.isResettingForDiscontinuity = false
                    s.pendingResetRevision = nil
                    return nil
                }
                return s.pendingResetRevision
            }) else { return }

            do {
                try await engine.resetForDiscontinuity()
            } catch {
                goDormant(error: error, completedReset: true)
                return
            }

            let completion = state.withLock { s -> (finished: Bool, startDrain: Bool) in
                guard !s.isStopped, !s.didFail else {
                    s.isResettingForDiscontinuity = false
                    s.pendingResetRevision = nil
                    return (true, false)
                }
                guard s.pendingResetRevision == revision else { return (false, false) }
                s.pendingResetRevision = nil
                s.isResettingForDiscontinuity = false
                let shouldDrain = !s.isSuspended && !s.chunkQueue.isEmpty && !s.isDraining
                if shouldDrain {
                    s.isDraining = true
                }
                return (true, shouldDrain)
            }
            if completion.startDrain {
                Task.detached(priority: .utility) { [weak self] in
                    await self?.drain()
                }
            }
            if completion.finished { return }
        }
    }

    private func shutdownEngineAfterPendingWork() async {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ shutdownGraceNanoseconds
        // Prefer orderly teardown, but never let a wedged model inference or
        // reset keep the meeting lifecycle alive indefinitely.
        while state.withLock({
            $0.isResettingForDiscontinuity || $0.activeInferenceRevision != nil
        }) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await engine.shutdown()
    }

    private func requestEngineShutdown() {
        let shouldSchedule = state.withLock { s -> Bool in
            guard !s.isShutdownRequested else { return false }
            s.isShutdownRequested = true
            return true
        }
        guard shouldSchedule else { return }
        Task { [self] in
            await shutdownEngineAfterPendingWork()
        }
    }
}
