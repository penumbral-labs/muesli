import AVFoundation
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingRecordingWriter")
struct MeetingRecordingWriterTests {

    @Test("streaming writer merges mic and system samples incrementally")
    func writerMergesIncrementally() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 2000, 3000, 4000])
        writer.appendSystem([3000, -2000])
        writer.appendSystem([500, 1500])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [2000, 0, 1750, 2750])
    }

    @Test("streaming writer flushes single-track tail on stop")
    func writerFlushesSingleTrackTail() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1200, -800, 400])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [1200, -800, 400])
    }

    @Test("pause boundary prevents unmatched samples from mixing across pause")
    func pauseBoundaryFlushesPendingSamples() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 3000])
        writer.markPauseBoundary()
        writer.appendSystem([5000, 7000])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [1000, 3000, 5000, 7000])
    }

    @Test("mic discontinuity keeps gap system audio full-volume and out of post-gap mic")
    func micDiscontinuityFlushesSystemGap() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1_000, 1_000])
        writer.appendSystem([3_000, 3_000])
        writer.appendSystem([5_000, 6_000])

        writer.markMicDiscontinuity(missingSampleCount: 2)

        writer.appendMic([2_000, 4_000])
        writer.appendSystem([6_000, 8_000])
        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [2_000, 2_000, 5_000, 6_000, 4_000, 6_000])
    }

    @Test("late system callbacks fill the mic gap before mixing post-recovery mic")
    func lateSystemGapDoesNotMixWithRecoveredMic() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1_000, 1_000])
        writer.appendSystem([3_000, 3_000])
        writer.markMicDiscontinuity(missingSampleCount: 2)

        // The first recovered mic callback can beat older system callbacks to
        // the meeting queue. The logical source timeline keeps those samples
        // full-volume and pairs only the remaining system samples with new mic.
        writer.appendMic([2_000, 4_000])
        writer.appendSystem([5_000, 6_000, 6_000, 8_000])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)
        #expect(samples == [2_000, 2_000, 5_000, 6_000, 4_000, 6_000])
    }

    @Test("rapid repeated mic gaps stay ordered while system callbacks are delayed")
    func repeatedMicGapsPreserveSourceTimelineOrder() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1_000, 1_000])
        writer.appendSystem([3_000, 3_000])

        writer.markMicDiscontinuity(missingSampleCount: 2)
        writer.appendMic([2_000, 4_000])
        writer.markMicDiscontinuity(missingSampleCount: 2)
        writer.appendMic([3_000, 5_000])

        // Both recovery gaps and both recovered mic spans are already ordered
        // when the delayed system callback finally catches up.
        writer.appendSystem([5_000, 6_000, 7_000, 8_000, 9_000, 10_000, 11_000, 12_000])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)
        #expect(samples == [2_000, 2_000, 5_000, 6_000, 4_500, 6_000, 9_000, 10_000, 7_000, 8_500])
    }

    @Test("stop materializes an unfilled mic gap before recovered mic audio")
    func stopPreservesUnfilledMicGap() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1_000, 1_000])
        writer.appendSystem([3_000, 3_000])
        writer.markMicDiscontinuity(missingSampleCount: 4)
        writer.appendMic([2_000, 4_000])
        writer.appendSystem([5_000, 6_000])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [2_000, 2_000, 5_000, 6_000, 0, 0, 2_000, 4_000])
    }

    @Test("pause materializes a mic gap before the resumed source timeline")
    func pausePreservesUnfilledMicGap() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1_000, 1_000])
        writer.appendSystem([3_000, 3_000])
        writer.markMicDiscontinuity(missingSampleCount: 2)
        writer.appendMic([2_000, 4_000])
        writer.markPauseBoundary()
        writer.appendMic([1_000, 3_000])
        writer.appendSystem([5_000, 7_000])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [2_000, 2_000, 0, 0, 2_000, 4_000, 3_000, 5_000])
    }

    @Test("repeated maximum discontinuities saturate instead of overflowing")
    func repeatedMaximumGapsDoNotOverflow() throws {
        let writer = try MeetingRecordingWriter()

        writer.markMicDiscontinuity(missingSampleCount: Int64.max)
        writer.markMicDiscontinuity(missingSampleCount: Int64.max)

        writer.cancel()
    }

    @Test("persistTemporaryRecording moves the temp wav when WAV is selected")
    func persistTemporaryRecordingMovesWAVFile() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem([1200, -800, 400])
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Weekly Product Sync! With Very Long Title Extra Words",
            startedAt: startedAt,
            supportDirectory: supportDirectory,
            fileFormat: .wav
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync-with-very-long.wav"))
        #expect(try readMonoPCM16WAVSamples(from: savedURL) == [1200, -800, 400])
    }

    @Test("persistTemporaryRecording transcodes to M4A by default")
    func persistTemporaryRecordingTranscodesToM4AByDefault() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem(Array(repeating: Int16(1200), count: 16_000))
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            supportDirectory: supportDirectory
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.pathExtension == "m4a")
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync.m4a"))

        let file = try AVAudioFile(forReading: savedURL)
        #expect(file.length > 0)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-writer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readMonoPCM16WAVSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let sampleBytes = data.subdata(in: 44..<data.count)
        let count = sampleBytes.count / MemoryLayout<Int16>.size
        return sampleBytes.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Int16.self)
            return Array(buffer.prefix(count)).map(Int16.init(littleEndian:))
        }
    }
}
