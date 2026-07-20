import Foundation

struct MeetingChunkTimingSnapshot: Equatable, Sendable {
    let startSampleIndex: Int64
    let sampleCount: Int64

    var startTimeSeconds: TimeInterval {
        Double(startSampleIndex) / Double(MeetingChunkTimingTracker.sampleRate)
    }

    var durationSeconds: TimeInterval {
        Double(sampleCount) / Double(MeetingChunkTimingTracker.sampleRate)
    }
}

struct MeetingChunkTimingTracker: Sendable {
    static let sampleRate = 16_000

    private var currentChunkStartSampleIndex: Int64?
    private var currentChunkSampleCount: Int64 = 0

    mutating func start() {
        currentChunkStartSampleIndex = 0
        currentChunkSampleCount = 0
    }

    mutating func append(sampleCount: Int) {
        guard sampleCount > 0, currentChunkStartSampleIndex != nil else { return }
        currentChunkSampleCount += Int64(sampleCount)
    }

    /// Advance the logical 16 kHz clock without claiming that audio exists.
    /// Recovery callers rotate the pre-gap chunk first, so the next real audio
    /// begins at the correct meeting offset without feeding synthetic silence
    /// through VAD or transcription.
    mutating func advance(sampleCount: Int64) {
        guard sampleCount > 0,
              currentChunkSampleCount == 0,
              let currentChunkStartSampleIndex else { return }
        self.currentChunkStartSampleIndex = currentChunkStartSampleIndex + sampleCount
    }

    mutating func rotate() -> MeetingChunkTimingSnapshot? {
        guard let currentChunkStartSampleIndex else { return nil }
        let snapshot = MeetingChunkTimingSnapshot(
            startSampleIndex: currentChunkStartSampleIndex,
            sampleCount: currentChunkSampleCount
        )
        self.currentChunkStartSampleIndex = currentChunkStartSampleIndex + currentChunkSampleCount
        currentChunkSampleCount = 0
        return snapshot
    }

    mutating func finish() -> MeetingChunkTimingSnapshot? {
        guard let startSampleIndex = currentChunkStartSampleIndex else { return nil }
        let snapshot = MeetingChunkTimingSnapshot(
            startSampleIndex: startSampleIndex,
            sampleCount: currentChunkSampleCount
        )
        currentChunkStartSampleIndex = nil
        currentChunkSampleCount = 0
        return snapshot
    }

    mutating func discard() {
        currentChunkStartSampleIndex = nil
        currentChunkSampleCount = 0
    }
}
