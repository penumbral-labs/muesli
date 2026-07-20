import AVFoundation
import Foundation
import os

enum MeetingRecordingFileFormat: String, CaseIterable, Sendable {
    case m4a
    case wav

    var displayName: String {
        switch self {
        case .m4a:
            return "M4A (AAC, smaller)"
        case .wav:
            return "WAV (lossless)"
        }
    }

    var fileExtension: String {
        switch self {
        case .m4a:
            return "m4a"
        case .wav:
            return "wav"
        }
    }

    static func resolved(_ rawValue: String) -> MeetingRecordingFileFormat {
        MeetingRecordingFileFormat(rawValue: rawValue) ?? .m4a
    }
}

final class MeetingRecordingWriter {
    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    private struct SourceSpan {
        enum Payload {
            case audio([Int16])
            case missing
        }

        let start: Int64
        let end: Int64
        let payload: Payload

        func sample(at position: Int64) -> Int16? {
            guard position >= start, position < end else { return nil }
            switch payload {
            case .audio(let samples):
                return samples[Int(position - start)]
            case .missing:
                return nil
            }
        }
    }

    /// A source-local logical clock. Spans are kept in capture order so a
    /// microphone outage cannot be accidentally moved across recovered audio
    /// while the other source is catching up.
    private struct SourceTimeline {
        var frontier: Int64 = 0
        private var spans: [SourceSpan] = []
        private var firstSpanIndex = 0

        mutating func appendAudio(_ samples: [Int16]) {
            guard !samples.isEmpty, frontier < Int64.max else { return }
            let acceptedCount = Int(min(Int64(samples.count), Int64.max - frontier))
            guard acceptedCount > 0 else { return }

            let acceptedSamples = acceptedCount == samples.count
                ? samples
                : Array(samples.prefix(acceptedCount))
            let end = frontier + Int64(acceptedCount)
            spans.append(SourceSpan(start: frontier, end: end, payload: .audio(acceptedSamples)))
            frontier = end
        }

        mutating func appendMissing(sampleCount: Int64) {
            let acceptedCount = min(max(0, sampleCount), Int64.max - frontier)
            guard acceptedCount > 0 else { return }

            let end = frontier + acceptedCount
            if let lastSpanIndex = spans.indices.last,
               lastSpanIndex >= firstSpanIndex,
               case .missing = spans[lastSpanIndex].payload,
               spans[lastSpanIndex].end == frontier {
                let previous = spans.removeLast()
                spans.append(SourceSpan(start: previous.start, end: end, payload: .missing))
            } else {
                spans.append(SourceSpan(start: frontier, end: end, payload: .missing))
            }
            frontier = end
        }

        func span(containing position: Int64) -> SourceSpan? {
            guard firstSpanIndex < spans.count else { return nil }
            let span = spans[firstSpanIndex]
            return position >= span.start && position < span.end ? span : nil
        }

        mutating func discardSpans(endingAtOrBefore position: Int64) {
            while firstSpanIndex < spans.count, spans[firstSpanIndex].end <= position {
                firstSpanIndex += 1
            }

            if firstSpanIndex == spans.count {
                spans.removeAll(keepingCapacity: true)
                firstSpanIndex = 0
            } else if firstSpanIndex >= 64, firstSpanIndex * 2 >= spans.count {
                spans.removeFirst(firstSpanIndex)
                firstSpanIndex = 0
            }
        }

        mutating func rebase(at position: Int64) {
            frontier = position
            spans.removeAll(keepingCapacity: true)
            firstSpanIndex = 0
        }
    }

    private struct State {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten: Int = 0
        var outputCursor: Int64 = 0
        var mic = SourceTimeline()
        var system = SourceTimeline()
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    init() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open retained meeting recording file for writing."]
            )
        }
        fileHandle.write(Self.wavHeader(dataSize: 0))
        lock.withLock {
            $0 = State(fileHandle: fileHandle, fileURL: fileURL)
        }
    }

    func appendMic(_ samples: [Int16]) {
        append(samples, toMic: true)
    }

    func appendSystem(_ samples: [Int16]) {
        append(samples, toMic: false)
    }

    func stop() -> URL? {
        lock.withLock { state in
            writeAvailableSamples(state: &state, flushAll: true)
            guard let fileHandle = state.fileHandle, let fileURL = state.fileURL else { return nil }

            fileHandle.seek(toFileOffset: 0)
            fileHandle.write(Self.wavHeader(dataSize: UInt32(state.bytesWritten)))
            fileHandle.closeFile()

            let outputURL = fileURL
            let bytesWritten = state.bytesWritten
            state = State()
            if bytesWritten == 0 {
                try? FileManager.default.removeItem(at: outputURL)
                return nil
            }
            return outputURL
        }
    }

    func markPauseBoundary() {
        lock.withLock { state in
            writeAvailableSamples(state: &state, flushAll: true)
            state.mic.rebase(at: state.outputCursor)
            state.system.rebase(at: state.outputCursor)
        }
    }

    /// Advance only the microphone's logical clock for an observed outage.
    /// Keeping the gap in the source timeline preserves its ordering relative
    /// to recovered mic audio, even if older system callbacks arrive later.
    func markMicDiscontinuity(missingSampleCount: Int64) {
        lock.withLock { state in
            state.mic.appendMissing(sampleCount: missingSampleCount)
            writeAvailableSamples(state: &state, flushAll: false)
        }
    }

    func cancel() {
        let tempURL = lock.withLock { state -> URL? in
            state.fileHandle?.closeFile()
            let fileURL = state.fileURL
            state = State()
            return fileURL
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    static func persistTemporaryRecordingAsync(
        from tempURL: URL,
        meetingTitle: String,
        startedAt: Date,
        supportDirectory: URL,
        fileFormat: MeetingRecordingFileFormat = .m4a
    ) async throws -> URL {
        let recordingsDirectory = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = recordingsDirectory.appendingPathComponent(
            "\(fileNamePrefix(for: startedAt, title: meetingTitle)).\(fileFormat.fileExtension)"
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        switch fileFormat {
        case .m4a:
            do {
                try await transcodeWAVToM4AAsync(sourceURL: tempURL, destinationURL: destinationURL)
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        case .wav:
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        }
        return destinationURL
    }

    private func append(_ samples: [Int16], toMic: Bool) {
        guard !samples.isEmpty else { return }
        lock.withLock { state in
            if toMic {
                state.mic.appendAudio(samples)
            } else {
                state.system.appendAudio(samples)
            }
            writeAvailableSamples(state: &state, flushAll: false)
        }
    }

    private func writeAvailableSamples(state: inout State, flushAll: Bool) {
        let target = flushAll
            ? max(state.mic.frontier, state.system.frontier)
            : min(state.mic.frontier, state.system.frontier)
        guard target > state.outputCursor else { return }

        // Bound allocations when one source is absent for a long time.
        let maximumWriteSampleCount: Int64 = 16_000
        while state.outputCursor < target {
            state.mic.discardSpans(endingAtOrBefore: state.outputCursor)
            state.system.discardSpans(endingAtOrBefore: state.outputCursor)

            let micSpan = state.mic.span(containing: state.outputCursor)
            let systemSpan = state.system.span(containing: state.outputCursor)
            let micBoundary = micSpan?.end ?? target
            let systemBoundary = systemSpan?.end ?? target
            let boundedWriteEnd = state.outputCursor > Int64.max - maximumWriteSampleCount
                ? Int64.max
                : state.outputCursor + maximumWriteSampleCount
            let segmentEnd = min(
                target,
                boundedWriteEnd,
                micBoundary,
                systemBoundary
            )
            guard segmentEnd > state.outputCursor else { break }

            let count = Int(segmentEnd - state.outputCursor)
            var mixedSamples = [Int16]()
            mixedSamples.reserveCapacity(count)
            for offset in 0..<count {
                let position = state.outputCursor + Int64(offset)
                let micSample = micSpan?.sample(at: position)
                let systemSample = systemSpan?.sample(at: position)
                switch (micSample, systemSample) {
                case let (.some(mic), .some(system)):
                    mixedSamples.append(Int16(clamping: (Int(mic) + Int(system)) / 2))
                case let (.some(mic), .none):
                    mixedSamples.append(mic)
                case let (.none, .some(system)):
                    mixedSamples.append(system)
                case (.none, .none):
                    mixedSamples.append(0)
                }
            }

            writeSamples(mixedSamples, state: &state)
            state.outputCursor = segmentEnd
        }
    }

    private func writeSamples(_ samples: [Int16], state: inout State) {
        guard !samples.isEmpty else { return }
        let pcmData = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        state.fileHandle?.write(pcmData)
        state.bytesWritten += pcmData.count
    }

    private static func fileNamePrefix(for date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let timestamp = formatter.string(from: date)

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let normalized = title.unicodeScalars.map { allowed.contains($0) ? String($0) : " " }.joined()
        let slug = normalized
            .split(whereSeparator: \.isWhitespace)
            .prefix(6)
            .joined(separator: "-")
            .lowercased()

        return slug.isEmpty ? timestamp : "\(timestamp)-\(slug)"
    }

    private static func transcodeWAVToM4AAsync(sourceURL: URL, destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create M4A export session for meeting recording."]
            )
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .m4a
        let exportSessionBox = ExportSessionBox(exportSession)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSessionBox.session.exportAsynchronously {
                guard exportSessionBox.session.status == .completed else {
                    continuation.resume(throwing: exportSessionBox.session.error ?? NSError(
                        domain: "MeetingRecordingWriter",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Could not export meeting recording as M4A."]
                    ))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private static func wavHeader(dataSize: UInt32) -> Data {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        return header
    }
}
