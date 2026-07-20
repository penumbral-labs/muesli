import Foundation
import FluidAudio
import os
import Testing
@testable import MuesliNativeApp

@Suite("Meeting streaming partial session")
struct MeetingStreamingPartialSessionTests {
    @Test("live caption model is ready only when every EOU artifact exists")
    func modelAvailabilityRequiresEveryArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = MeetingLiveCaptionModelStore.modelDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(!MeetingLiveCaptionModelStore.isDownloaded(in: root))
        for artifact in ModelNames.ParakeetEOU.requiredModels {
            let url = directory.appendingPathComponent(artifact)
            if artifact.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("{}".utf8).write(to: url)
            }
        }
        #expect(MeetingLiveCaptionModelStore.isDownloaded(in: root))
    }

    @Test("Nemotron lifecycle rejects process and reset continuations after shutdown")
    func nemotronLifecycleFencesActorReentrancy() throws {
        var lifecycle = NemotronMeetingPartialLifecycle()
        let initialProcessGeneration = lifecycle.operationGeneration
        let initialResetGeneration = lifecycle.beginReset()
        let processGeneration = try #require(initialProcessGeneration)
        let resetGeneration = try #require(initialResetGeneration)

        #expect(!lifecycle.admits(processGeneration))
        #expect(lifecycle.admits(resetGeneration))

        let didShutDown = lifecycle.shutDown()
        #expect(didShutDown)
        #expect(!lifecycle.admits(resetGeneration))
        #expect(lifecycle.operationGeneration == nil)
        let postShutdownReset = lifecycle.beginReset()
        #expect(postShutdownReset == nil)
        let didRepeatShutdown = lifecycle.shutDown()
        #expect(!didRepeatShutdown)
    }

    @Test("publishes cumulative Parakeet partials")
    func accumulatesAndPublishes() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one two"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 2))

        #expect(await waitUntil { collector.latest == "one two" })
        #expect(engine.processCalls == 2)
    }

    @Test("coalesces rapid partials and suppresses duplicate UI updates")
    func coalescesAndDeduplicatesPartials() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one", "one two"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 3))

        #expect(await waitUntil { collector.latest == "one two" })
        #expect(collector.all == ["one two"])
        #expect(engine.processCalls == 3)
    }

    @Test("a new tail arriving after flush preparation remains scheduled")
    func flushPreparationDoesNotEraseNewerPendingTail() async throws {
        let engine = ScriptedPartialEngine(script: ["first", "second"])
        let holder = PartialSessionHolder()
        let didInterleave = OSAllocatedUnfairLock(initialState: false)
        let session = MeetingStreamingPartialSession(
            engine: engine,
            label: "You",
            scheduledPublicationDidPrepare: {
                let shouldInterleave = didInterleave.withLock { value -> Bool in
                    guard !value else { return false }
                    value = true
                    return true
                }
                guard shouldInterleave, let session = holder.value else { return }

                // Install a second pending tail in the exact interval after
                // the first flush prepares its delivery and before that
                // delivery is queued. Preparation must not later clear it.
                session.enqueue(samples(chunkCount: 1))
                let deadline = Date().addingTimeInterval(1)
                while engine.completedProcessCalls < 2, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        )
        holder.value = session
        defer { holder.value = nil }
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))

        #expect(await waitUntil { collector.latest == "second" })
        #expect(collector.all == ["first", "second"])
        #expect(engine.completedProcessCalls == 2)
    }

    @Test("filters engine control tags before publishing live captions")
    func filtersEngineArtifacts() async throws {
        let engine = ScriptedPartialEngine(script: [">> [BLANK_AUDIO]"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))

        #expect(await waitUntil { collector.latest == "" })
        #expect(!collector.all.contains { $0.localizedCaseInsensitiveContains("blank_audio") })
    }

    @Test("buffers sub-chunk sample batches until a feed interval is available")
    func buffersSubChunkBatches() async throws {
        let engine = ScriptedPartialEngine(script: ["hello"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        let firstCount = MeetingStreamingPartialSession.feedSamples - 1
        session.enqueue([Float](repeating: 0, count: firstCount))
        #expect(await remainsTrue { engine.processCalls == 0 })

        session.enqueue([0])
        #expect(await waitUntil { collector.latest == "hello" })
    }

    @Test("VAD boundary freezes the prefix and durable commit drops it")
    func boundaryAndCommit() async throws {
        let engine = ScriptedPartialEngine(script: ["one two", "one two three"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two" })

        let segmentID = UUID()
        session.markSegmentBoundary(id: segmentID)
        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two three" })

        session.commitSegment(id: segmentID)
        #expect(await waitUntil { collector.latest == " three" })
    }

    @Test("frozen streaming text is available as a durable fallback")
    func pendingSegmentFallback() async throws {
        let engine = ScriptedPartialEngine(script: ["नमस्ते दुनिया", "नमस्ते दुनिया फिर"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "नमस्ते दुनिया" })
        let segmentID = UUID()
        session.markSegmentBoundary(id: segmentID)
        #expect(session.pendingSegmentText(id: segmentID) == "नमस्ते दुनिया")

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "नमस्ते दुनिया फिर" })
        session.commitSegment(id: segmentID)
        #expect(await waitUntil { collector.latest == " फिर" })
    }

    @Test("concurrent durable chunks retire their VAD boundaries in order")
    func queuedBoundariesCommitInOrder() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one two", "one two three"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })
        let firstSegmentID = UUID()
        session.markSegmentBoundary(id: firstSegmentID)

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two" })
        let secondSegmentID = UUID()
        session.markSegmentBoundary(id: secondSegmentID)

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two three" })

        session.commitSegment(id: firstSegmentID)
        #expect(await waitUntil { collector.latest == " two three" })
        session.commitSegment(id: secondSegmentID)
        #expect(await waitUntil { collector.latest == " three" })
    }

    @Test("out-of-order chunk completion resolves the matching VAD boundary")
    func outOfOrderCommitUsesSegmentID() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one two", "one two three"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })
        let firstSegmentID = UUID()
        session.markSegmentBoundary(id: firstSegmentID)

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two" })
        let secondSegmentID = UUID()
        session.markSegmentBoundary(id: secondSegmentID)

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one two three" })
        #expect(session.pendingSegmentText(id: firstSegmentID) == "one")
        #expect(session.pendingSegmentText(id: secondSegmentID) == "two")

        session.commitSegment(id: secondSegmentID)
        #expect(await remainsTrue { collector.latest == "one two three" })
        session.commitSegment(id: firstSegmentID)
        #expect(await waitUntil { collector.latest == " three" })
    }

    @Test("commit without a VAD boundary publishes nothing")
    func commitWithoutBoundaryIsNoOp() async throws {
        let engine = ScriptedPartialEngine(script: ["one"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })
        let updatesBefore = collector.all.count

        session.commitSegment(id: UUID())
        #expect(await remainsTrue { collector.all.count == updatesBefore })
    }

    @Test("pause hides prior text and resume publishes only new speech")
    func suspendAndResume() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "two"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })

        session.suspend()
        #expect(await waitUntil { collector.latest == "" })

        session.enqueue(samples(chunkCount: 1))
        #expect(await remainsTrue { engine.processCalls == 1 })

        session.resume()
        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "two" })
        #expect(engine.resetCalls == 1)
    }

    @Test("a chunk retiring after pause cannot restore its stale tail")
    func commitAfterSuspendDoesNotRepublish() async throws {
        let engine = ScriptedPartialEngine(script: ["one"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })
        let segmentID = UUID()
        session.markSegmentBoundary(id: segmentID)

        session.suspend()
        #expect(await waitUntil { collector.latest == "" })
        session.commitSegment(id: segmentID)
        #expect(await remainsTrue { collector.latest == "" })
    }

    @Test("a delayed publication queued before pause cannot follow the clear")
    func queuedPublicationCannotResurrectAfterSuspend() async throws {
        let engine = ScriptedPartialEngine(script: ["first", "stale"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = BlockingPartialCollector(blockingText: "first")
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.isBlocking })
        defer { collector.release() }

        // Queue the second publication behind the blocked first callback. The
        // delay lets its throttle task flush, so this exercises delivery-time
        // validation rather than only invalidating a pending throttle value.
        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.processCalls == 2 })
        try await Task.sleep(
            nanoseconds: MeetingStreamingPartialSession.publicationIntervalNanoseconds + 50_000_000
        )

        session.suspend()
        // Reset begins after suspend has advanced the lifecycle/publication
        // generations, while serialized publication is still blocked.
        #expect(await waitUntil { engine.resetCalls == 1 })

        collector.release()

        #expect(await waitUntil { collector.latest == "" })
        #expect(await remainsTrue(for: 0.5) { collector.all == ["first", ""] })
    }

    @Test("inference started before pause cannot publish after resume")
    func prePauseInferenceCannotPublishAfterResume() async throws {
        let engine = BlockingPartialEngine(text: "stale")
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.isWaiting })

        session.suspend()
        #expect(await waitUntil { collector.latest == "" })
        session.resume()
        engine.release()

        #expect(await remainsTrue(for: 0.5) { collector.latest == "" })
    }

    @Test("pause resets cumulative inference before resumed audio and retires the old epoch")
    func pauseFencesBlockedCumulativeInferenceBeforeResume() async throws {
        let engine = BlockingCumulativePartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "before" })
        let prePauseSegment = UUID()
        session.markSegmentBoundary(id: prePauseSegment)
        #expect(session.pendingSegmentText(id: prePauseSegment) == "before")

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.isWaiting })

        session.suspend()
        #expect(await waitUntil { collector.latest == "" })
        #expect(session.pendingSegmentText(id: prePauseSegment) == nil)

        // Resume is deliberately immediate. Its audio must wait behind the
        // reset even though the pre-pause model call is still blocked.
        session.resume()
        session.enqueue(samples(chunkCount: 1))
        #expect(await remainsTrue { engine.processCalls == 2 && engine.resetCalls == 0 })

        engine.release()

        #expect(await waitUntil {
            engine.resetCalls == 1 && engine.processCalls == 3 && collector.latest == "after"
        })
        session.commitSegment(id: prePauseSegment)
        #expect(await remainsTrue { collector.latest == "after" })
        #expect(!collector.all.contains("before paused"))
        #expect(engine.events == [
            "process-before",
            "process-before-paused-start",
            "process-before-paused-finish",
            "reset",
            "process-after",
        ])
    }

    @Test("discontinuity resets model state and preserves the frozen durable prefix")
    func discontinuityResetsEngineState() async throws {
        let engine = ScriptedPartialEngine(script: ["before", "after"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "before" })
        let preGapSegment = UUID()
        session.markSegmentBoundary(id: preGapSegment)

        session.markDiscontinuity()
        #expect(await waitUntil { engine.resetCalls == 1 && collector.latest == "" })
        #expect(session.pendingSegmentText(id: preGapSegment) == "before")

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "after" })
        session.commitSegment(id: preGapSegment)
        #expect(await remainsTrue { collector.latest == "after" })
    }

    @Test("discontinuity waits for old inference before resetting")
    func discontinuityFencesInFlightInference() async throws {
        let engine = BlockingPartialEngine(text: "stale")
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.isWaiting })
        session.markDiscontinuity()
        #expect(engine.resetCalls == 0)
        engine.release()

        #expect(await waitUntil { engine.resetCalls == 1 })
        #expect(await remainsTrue(for: 0.5) { collector.latest == "" })
    }

    @Test("audio arriving during a route reset is processed after the new epoch is ready")
    func discontinuityBuffersAudioDuringReset() async throws {
        let engine = BlockingResetPartialEngine(script: ["before", "after"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "before" })

        session.markDiscontinuity()
        #expect(await waitUntil { engine.isResetWaiting })
        session.enqueue(samples(chunkCount: 1))
        #expect(await remainsTrue { engine.processCalls == 1 })

        engine.releaseReset()
        #expect(await waitUntil { engine.processCalls == 2 && collector.latest == "after" })
    }

    @Test("stop waits for an in-flight reset and shuts the engine down once")
    func stopWaitsForResetBeforeShutdown() async throws {
        let engine = BlockingResetPartialEngine(script: [])
        let session = MeetingStreamingPartialSession(
            engine: engine,
            label: "You",
            shutdownGraceNanoseconds: 1_000_000_000
        )
        await session.connect()

        session.markDiscontinuity()
        #expect(await waitUntil { engine.isResetWaiting })

        session.stop()
        session.stop()
        #expect(await remainsTrue { engine.shutdownCalls == 0 })

        engine.releaseReset()
        #expect(await waitUntil { engine.shutdownCalls == 1 })
        #expect(engine.events == ["reset-start", "reset-finish", "shutdown"])
    }

    @Test("stop forces shutdown after the grace period when inference hangs")
    func stopForcesShutdownForHungInference() async throws {
        let engine = BlockingPartialEngine(text: "stale")
        let session = MeetingStreamingPartialSession(
            engine: engine,
            label: "You",
            shutdownGraceNanoseconds: 20_000_000
        )
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.isWaiting })

        session.stop()
        session.stop()

        #expect(await waitUntil { engine.shutdownCalls == 1 && !engine.isWaiting })
        #expect(await remainsTrue { engine.shutdownCalls == 1 })
    }

    @Test("stop forces shutdown after the grace period when a reset hangs")
    func stopForcesShutdownForHungReset() async throws {
        let engine = BlockingResetPartialEngine(script: [])
        let session = MeetingStreamingPartialSession(
            engine: engine,
            label: "You",
            shutdownGraceNanoseconds: 20_000_000
        )
        await session.connect()

        session.markDiscontinuity()
        #expect(await waitUntil { engine.isResetWaiting })

        session.stop()
        session.stop()

        #expect(await waitUntil { engine.shutdownCalls == 1 })
        #expect(engine.events == ["reset-start", "shutdown"])

        engine.releaseReset()
        #expect(await waitUntil { engine.events == ["reset-start", "shutdown", "reset-finish"] })
        #expect(await remainsTrue { engine.shutdownCalls == 1 })
    }

    @Test("a finish timeout cannot shut down ahead of a late reset completion")
    func finishTimeoutWaitsForResetBeforeShutdown() async throws {
        let engine = BlockingResetPartialEngine(script: [])
        let session = MeetingStreamingPartialSession(
            engine: engine,
            label: "You",
            shutdownGraceNanoseconds: 1_000_000_000
        )
        await session.connect()

        session.markDiscontinuity()
        #expect(await waitUntil { engine.isResetWaiting })

        let tail = await session.finish(drainTimeoutNanoseconds: 20_000_000)
        #expect(tail == nil)
        #expect(engine.shutdownCalls == 0)

        engine.releaseReset()
        #expect(await waitUntil { engine.shutdownCalls == 1 })
        #expect(engine.events == ["reset-start", "reset-finish", "shutdown"])
    }

    @Test("segment commits remain scoped to their transcript epoch across repeated gaps")
    func segmentCommitsRemainEpochScoped() async throws {
        let engine = ScriptedPartialEngine(script: ["old", "new", "latest"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "old" })
        let oldSegment = UUID()
        session.markSegmentBoundary(id: oldSegment)

        session.markDiscontinuity()
        #expect(await waitUntil { engine.resetCalls == 1 })
        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "new" })
        let newSegment = UUID()
        session.markSegmentBoundary(id: newSegment)
        #expect(session.pendingSegmentText(id: newSegment) == "new")

        // Durable transcription may finish out of order. The newer commit is
        // retained behind the older segment without altering the live epoch.
        session.commitSegment(id: newSegment)
        #expect(await remainsTrue { collector.latest == "new" })

        session.markDiscontinuity()
        #expect(await waitUntil { engine.resetCalls == 2 })
        #expect(session.pendingSegmentText(id: newSegment) == "new")
        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "latest" })

        session.commitSegment(id: oldSegment)
        #expect(await remainsTrue { collector.latest == "latest" })
    }

    @Test("an EOU inference failure clears the tail and goes dormant")
    func failureGoesDormant() async throws {
        let engine = ThrowingPartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "" })
        let callsAfterFailure = engine.processCalls

        session.enqueue(samples(chunkCount: 2))
        #expect(await remainsTrue { engine.processCalls == callsAfterFailure })
    }

    @Test("stop drops buffered audio and suppresses further updates")
    func stopSuppressesUpdates() async throws {
        let engine = ScriptedPartialEngine(script: ["one", "one two"])
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { collector.latest == "one" })

        session.stop()
        #expect(await waitUntil { collector.latest == "" })
        let updatesBefore = collector.all.count
        session.enqueue(samples(chunkCount: 2))
        #expect(await remainsTrue { collector.all.count == updatesBefore && engine.processCalls == 1 })
    }

    @Test("finish drains residual audio and returns the finalized tail")
    func finishDrainsResidualAudio() async throws {
        let engine = ScriptedPartialEngine(script: ["partial"], finishText: "partial final")
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        await session.connect()

        session.enqueue([Float](repeating: 0, count: MeetingStreamingPartialSession.feedSamples - 1))

        let tail = await session.finish()

        #expect(engine.processCalls == 1)
        #expect(engine.finishCalls == 1)
        #expect(tail == "partial final")
    }

    @Test("finish abandons a hung streaming inference so meeting stop can recover")
    func finishTimesOutHungInference() async throws {
        let engine = BlockingPartialEngine(text: "late")
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        await session.connect()

        session.enqueue(samples(chunkCount: 1))
        #expect(await waitUntil { engine.isWaiting })

        let tail = await session.finish(drainTimeoutNanoseconds: 20_000_000)

        #expect(tail == nil)
        #expect(await waitUntil { !engine.isWaiting })
    }

    @Test("backpressure keeps only the freshest EOU feed intervals")
    func backpressureDropsOldestChunks() async throws {
        let engine = EchoPartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        var input: [Float] = []
        for chunkIndex in 0..<7 {
            input.append(contentsOf: [Float](
                repeating: Float(chunkIndex),
                count: MeetingStreamingPartialSession.feedSamples
            ))
        }
        session.enqueue(input)

        #expect(await waitUntil { collector.latest == "c4 c5 c6" })
        #expect(engine.processCalls == MeetingStreamingPartialSession.maxQueuedChunks)
    }
}

private final class ScriptedPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private struct State {
        var script: [String]
        var finishText: String?
        var handler: (@Sendable (String) -> Void)?
        var processCalls = 0
        var completedProcessCalls = 0
        var finishCalls = 0
        var shutdownCalls = 0
        var resetCalls = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(script: [String], finishText: String? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(script: script, finishText: finishText))
    }

    var processCalls: Int { state.withLock { $0.processCalls } }
    var completedProcessCalls: Int { state.withLock { $0.completedProcessCalls } }
    var finishCalls: Int { state.withLock { $0.finishCalls } }
    var resetCalls: Int { state.withLock { $0.resetCalls } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func process(samples: [Float]) async throws {
        let update: (String, (@Sendable (String) -> Void)?)? = state.withLock { s in
            s.processCalls += 1
            guard !s.script.isEmpty else { return nil }
            return (s.script.removeFirst(), s.handler)
        }
        if let update {
            update.1?(update.0)
        }
        state.withLock { $0.completedProcessCalls += 1 }
    }

    func finish() async throws {
        let update: (String, (@Sendable (String) -> Void)?)? = state.withLock { s in
            s.finishCalls += 1
            guard let finishText = s.finishText else { return nil }
            return (finishText, s.handler)
        }
        if let update {
            update.1?(update.0)
        }
    }

    func resetForDiscontinuity() async throws {
        state.withLock { $0.resetCalls += 1 }
    }

    func shutdown() async {
        state.withLock { $0.shutdownCalls += 1 }
    }
}

private final class ThrowingPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    var processCalls: Int { calls.withLock { $0 } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {}

    func process(samples: [Float]) async throws {
        calls.withLock { $0 += 1 }
        throw NSError(domain: "ThrowingPartialEngine", code: 1)
    }

    func shutdown() async {}
}

private final class BlockingPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (String) -> Void)?
        var continuation: CheckedContinuation<Void, Never>?
        var isWaiting = false
        var resetCalls = 0
        var shutdownCalls = 0
    }
    private let text: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(text: String) {
        self.text = text
    }

    var isWaiting: Bool { state.withLock { $0.isWaiting } }
    var resetCalls: Int { state.withLock { $0.resetCalls } }
    var shutdownCalls: Int { state.withLock { $0.shutdownCalls } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func process(samples: [Float]) async throws {
        await withCheckedContinuation { continuation in
            state.withLock { s in
                s.isWaiting = true
                s.continuation = continuation
            }
        }
        state.withLock { $0.handler }?(text)
    }

    func release() {
        let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
            let continuation = s.continuation
            s.continuation = nil
            s.isWaiting = false
            return continuation
        }
        continuation?.resume()
    }

    func resetForDiscontinuity() async throws {
        state.withLock { $0.resetCalls += 1 }
    }

    func shutdown() async {
        state.withLock { $0.shutdownCalls += 1 }
        release()
    }
}

private final class BlockingCumulativePartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (String) -> Void)?
        var continuation: CheckedContinuation<Void, Never>?
        var isWaiting = false
        var processCalls = 0
        var resetCalls = 0
        var events: [String] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isWaiting: Bool { state.withLock { $0.isWaiting } }
    var processCalls: Int { state.withLock { $0.processCalls } }
    var resetCalls: Int { state.withLock { $0.resetCalls } }
    var events: [String] { state.withLock { $0.events } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func process(samples: [Float]) async throws {
        let call = state.withLock { s -> Int in
            s.processCalls += 1
            return s.processCalls
        }
        switch call {
        case 1:
            let handler = state.withLock { s -> (@Sendable (String) -> Void)? in
                s.events.append("process-before")
                return s.handler
            }
            handler?("before")
        case 2:
            await withCheckedContinuation { continuation in
                state.withLock { s in
                    s.events.append("process-before-paused-start")
                    s.isWaiting = true
                    s.continuation = continuation
                }
            }
            let handler = state.withLock { s -> (@Sendable (String) -> Void)? in
                s.events.append("process-before-paused-finish")
                return s.handler
            }
            handler?("before paused")
        default:
            let handler = state.withLock { s -> (@Sendable (String) -> Void)? in
                s.events.append("process-after")
                return s.handler
            }
            handler?("after")
        }
    }

    func release() {
        let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
            let continuation = s.continuation
            s.continuation = nil
            s.isWaiting = false
            return continuation
        }
        continuation?.resume()
    }

    func resetForDiscontinuity() async throws {
        state.withLock { s in
            s.resetCalls += 1
            s.events.append("reset")
        }
    }

    func shutdown() async {
        release()
    }
}

private final class BlockingResetPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private struct State {
        var script: [String]
        var handler: (@Sendable (String) -> Void)?
        var processCalls = 0
        var resetContinuation: CheckedContinuation<Void, Never>?
        var isResetWaiting = false
        var shutdownCalls = 0
        var events: [String] = []
    }
    private let state: OSAllocatedUnfairLock<State>

    init(script: [String]) {
        state = OSAllocatedUnfairLock(initialState: State(script: script))
    }

    var processCalls: Int { state.withLock { $0.processCalls } }
    var isResetWaiting: Bool { state.withLock { $0.isResetWaiting } }
    var shutdownCalls: Int { state.withLock { $0.shutdownCalls } }
    var events: [String] { state.withLock { $0.events } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func process(samples: [Float]) async throws {
        let update: (String, (@Sendable (String) -> Void)?)? = state.withLock { s in
            s.processCalls += 1
            guard !s.script.isEmpty else { return nil }
            return (s.script.removeFirst(), s.handler)
        }
        if let update {
            update.1?(update.0)
        }
    }

    func resetForDiscontinuity() async throws {
        await withCheckedContinuation { continuation in
            state.withLock { s in
                s.events.append("reset-start")
                s.isResetWaiting = true
                s.resetContinuation = continuation
            }
        }
        state.withLock { $0.events.append("reset-finish") }
    }

    func releaseReset() {
        let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
            let continuation = s.resetContinuation
            s.resetContinuation = nil
            s.isResetWaiting = false
            return continuation
        }
        continuation?.resume()
    }

    func shutdown() async {
        state.withLock { s in
            s.shutdownCalls += 1
            s.events.append("shutdown")
        }
    }
}

private final class EchoPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (String) -> Void)?
        var processCalls = 0
        var text = ""
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var processCalls: Int { state.withLock { $0.processCalls } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func process(samples: [Float]) async throws {
        let update = state.withLock { s -> (String, (@Sendable (String) -> Void)?) in
            s.processCalls += 1
            let marker = samples.first.map { Int($0) } ?? -1
            s.text += " c\(marker)"
            return (s.text, s.handler)
        }
        update.1?(update.0)
    }

    func shutdown() async {}
}

private final class PartialCollector: @unchecked Sendable {
    private let updates = OSAllocatedUnfairLock(initialState: [String]())

    func record(_ text: String) {
        updates.withLock { $0.append(text) }
    }

    var all: [String] { updates.withLock { $0 } }
    var latest: String? { all.last }
}

private final class PartialSessionHolder: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<MeetingStreamingPartialSession?>(initialState: nil)

    var value: MeetingStreamingPartialSession? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

private final class BlockingPartialCollector: @unchecked Sendable {
    private struct State {
        var updates: [String] = []
        var isBlocking = false
        var hasReleased = false
    }

    private let blockingText: String
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    init(blockingText: String) {
        self.blockingText = blockingText
    }

    func record(_ text: String) {
        let shouldBlock = state.withLock { s -> Bool in
            s.updates.append(text)
            guard text == blockingText, !s.hasReleased else { return false }
            s.isBlocking = true
            return true
        }
        guard shouldBlock else { return }
        releaseSemaphore.wait()
        state.withLock { $0.isBlocking = false }
    }

    func release() {
        let shouldSignal = state.withLock { s -> Bool in
            guard !s.hasReleased else { return false }
            s.hasReleased = true
            return true
        }
        if shouldSignal {
            releaseSemaphore.signal()
        }
    }

    var isBlocking: Bool { state.withLock { $0.isBlocking } }
    var all: [String] { state.withLock { $0.updates } }
    var latest: String? { all.last }
}

private func samples(chunkCount: Int, marker: Float = 0) -> [Float] {
    [Float](
        repeating: marker,
        count: MeetingStreamingPartialSession.feedSamples * chunkCount
    )
}

private func remainsTrue(
    for duration: TimeInterval = 0.2,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        if !condition() { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private func waitUntil(
    timeout: TimeInterval = 2.0,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
