import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting streaming partial session")
struct MeetingStreamingPartialSessionTests {
    @available(macOS 15, *)
    @Test("accumulates chunk text and publishes the growing tail")
    func accumulatesAndPublishes() async throws {
        let transcriber = ScriptedPartialTranscriber(script: ["one", " two"])
        let session = MeetingStreamingPartialSession(transcriber: transcriber, chunkSamples: 4, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }

        session.enqueue([Float](repeating: 0, count: 8))

        #expect(await waitUntil { collector.latest == "one two" })
        #expect(transcriber.makeStateCalls == 1)
        #expect(transcriber.transcribeCalls == 2)
    }

    @available(macOS 15, *)
    @Test("buffers sub-chunk sample batches until a full chunk is available")
    func buffersSubChunkBatches() async throws {
        let transcriber = ScriptedPartialTranscriber(script: ["hello"])
        let session = MeetingStreamingPartialSession(transcriber: transcriber, chunkSamples: 6, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }

        session.enqueue([Float](repeating: 0, count: 4))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(transcriber.transcribeCalls == 0)

        session.enqueue([Float](repeating: 0, count: 2))
        #expect(await waitUntil { collector.latest == "hello" })
    }

    @available(macOS 15, *)
    @Test("segment boundary freezes the prefix and commit drops it")
    func boundaryAndCommit() async throws {
        let transcriber = ScriptedPartialTranscriber(script: ["one two", " three"])
        let session = MeetingStreamingPartialSession(transcriber: transcriber, chunkSamples: 4, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }

        session.enqueue([Float](repeating: 0, count: 4))
        #expect(await waitUntil { collector.latest == "one two" })

        session.markSegmentBoundary()
        session.enqueue([Float](repeating: 0, count: 4))
        // The frozen prefix stays visible until commit — no flicker-to-empty.
        #expect(await waitUntil { collector.latest == "one two three" })

        session.commitSegment()
        #expect(await waitUntil { collector.latest == " three" })
    }

    @available(macOS 15, *)
    @Test("commit without a marked boundary publishes nothing")
    func commitWithoutBoundaryIsNoOp() async throws {
        let transcriber = ScriptedPartialTranscriber(script: ["one"])
        let session = MeetingStreamingPartialSession(transcriber: transcriber, chunkSamples: 4, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }

        session.enqueue([Float](repeating: 0, count: 4))
        #expect(await waitUntil { collector.latest == "one" })
        let updatesBefore = collector.all.count

        session.commitSegment()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(collector.all.count == updatesBefore)
    }

    @available(macOS 15, *)
    @Test("suspend clears the tail and drops audio; resume re-enables")
    func suspendAndResume() async throws {
        let transcriber = ScriptedPartialTranscriber(script: ["one", "two"])
        let session = MeetingStreamingPartialSession(transcriber: transcriber, chunkSamples: 4, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }

        session.enqueue([Float](repeating: 0, count: 4))
        #expect(await waitUntil { collector.latest == "one" })

        session.suspend()
        #expect(await waitUntil { collector.latest == "" })

        session.enqueue([Float](repeating: 0, count: 4))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(transcriber.transcribeCalls == 1)

        session.resume()
        session.enqueue([Float](repeating: 0, count: 4))
        #expect(await waitUntil { collector.latest == "two" })
    }

    @available(macOS 15, *)
    @Test("a transcription failure clears the tail and goes dormant")
    func failureGoesDormant() async throws {
        let transcriber = ThrowingPartialTranscriber()
        let session = MeetingStreamingPartialSession(transcriber: transcriber, chunkSamples: 4, label: "Others")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }

        session.enqueue([Float](repeating: 0, count: 4))
        #expect(await waitUntil { collector.latest == "" })
        let callsAfterFailure = transcriber.transcribeCalls

        session.enqueue([Float](repeating: 0, count: 8))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(transcriber.transcribeCalls == callsAfterFailure)
    }

    @available(macOS 15, *)
    @Test("stop drops buffered audio and suppresses further updates")
    func stopSuppressesUpdates() async throws {
        let transcriber = ScriptedPartialTranscriber(script: ["one", "two"])
        let session = MeetingStreamingPartialSession(transcriber: transcriber, chunkSamples: 4, label: "You")
        let collector = PartialCollector()
        session.onPartialUpdate = { collector.record($0) }

        session.enqueue([Float](repeating: 0, count: 4))
        #expect(await waitUntil { collector.latest == "one" })

        session.stop()
        let updatesBefore = collector.all.count
        session.enqueue([Float](repeating: 0, count: 8))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(collector.all.count == updatesBefore)
        #expect(transcriber.transcribeCalls == 1)
    }
}

// MARK: - Test doubles

@available(macOS 15, *)
private final class ScriptedPartialTranscriber: NemotronStreamingTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String]
    private var _makeStateCalls = 0
    private var _transcribeCalls = 0

    init(script: [String]) {
        self.script = script
    }

    var makeStateCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _makeStateCalls
    }

    var transcribeCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _transcribeCalls
    }

    func makeStreamState() async throws -> RNNTStreamState {
        lock.lock()
        _makeStateCalls += 1
        lock.unlock()
        return try makePartialTestStreamState()
    }

    func transcribeChunk(samples: [Float], state: inout RNNTStreamState) async throws -> String {
        lock.lock()
        defer { lock.unlock() }
        _transcribeCalls += 1
        guard !script.isEmpty else { return "" }
        return script.removeFirst()
    }
}

@available(macOS 15, *)
private final class ThrowingPartialTranscriber: NemotronStreamingTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var _transcribeCalls = 0

    var transcribeCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _transcribeCalls
    }

    func makeStreamState() async throws -> RNNTStreamState {
        try makePartialTestStreamState()
    }

    func transcribeChunk(samples: [Float], state: inout RNNTStreamState) async throws -> String {
        lock.lock()
        _transcribeCalls += 1
        lock.unlock()
        throw NSError(domain: "ThrowingPartialTranscriber", code: 1)
    }
}

private final class PartialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [String] = []

    func record(_ text: String) {
        lock.lock()
        updates.append(text)
        lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return updates
    }

    var latest: String? {
        all.last
    }
}

/// Minimal caches — the fake transcribers never read them.
private func makePartialTestStreamState() throws -> RNNTStreamState {
    try nemotronMakeStreamState(
        config: NemotronRNNTConfig(
            chunkSamples: 4,
            cacheChannelFrames: 1,
            totalMelFrames: 1,
            encoderDim: 1,
            decoderHiddenSize: 1,
            blankTokenId: 1,
            promptId: nil,
            stripAngleBracketTags: false
        )
    )
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
