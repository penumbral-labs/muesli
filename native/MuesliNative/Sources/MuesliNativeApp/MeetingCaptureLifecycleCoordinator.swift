import Foundation

/// Owns the process-wide meeting capture lease independently of transcript
/// processing. A new meeting may begin as soon as both audio sources from the
/// previous generation are quiescent, but never while an older start/teardown
/// is still inside CoreAudio.
struct MeetingCaptureLifecycleCoordinator {
    struct Lease: Hashable, Sendable {
        fileprivate let generation: UInt64
    }

    enum Phase: Equatable, Sendable {
        case idle
        case starting(Lease)
        case active(Lease)
        case quiescing(Lease)
    }

    enum QuiescenceClaim: Equatable, Sendable {
        /// This caller transitioned the capture into teardown and owns the
        /// single call that stops/discards the underlying audio session.
        case acquired
        /// Another caller already owns teardown for this lease.
        case alreadyQuiescing
        /// The lease is stale or capture is already idle.
        case rejected
    }

    private(set) var phase: Phase = .idle
    private var nextGeneration: UInt64 = 0

    var isCaptureOccupied: Bool {
        phase != .idle
    }

    mutating func beginCapture() -> Lease? {
        guard phase == .idle else { return nil }
        nextGeneration &+= 1
        let lease = Lease(generation: nextGeneration)
        phase = .starting(lease)
        return lease
    }

    @discardableResult
    mutating func markActive(_ lease: Lease) -> Bool {
        guard phase == .starting(lease) else { return false }
        phase = .active(lease)
        return true
    }

    /// Separates lifecycle state from teardown ownership. A repeated request
    /// can observe the same quiescing lease, but must not invoke teardown a
    /// second time. Stale generations cannot seize the lease.
    @discardableResult
    mutating func beginQuiescing(_ lease: Lease) -> QuiescenceClaim {
        switch phase {
        case .starting(lease), .active(lease):
            phase = .quiescing(lease)
            return .acquired
        case .quiescing(lease):
            return .alreadyQuiescing
        case .idle, .starting, .active, .quiescing:
            return .rejected
        }
    }

    /// Releases only the matching quiescing generation. This is the core stale
    /// completion guard when delayed CoreAudio work outlives a newer request.
    @discardableResult
    mutating func completeQuiescence(_ lease: Lease) -> Bool {
        guard phase == .quiescing(lease) else { return false }
        phase = .idle
        return true
    }

    func owns(_ lease: Lease) -> Bool {
        switch phase {
        case .starting(lease), .active(lease), .quiescing(lease):
            return true
        case .idle, .starting, .active, .quiescing:
            return false
        }
    }
}

/// Capture-generation admission for durable transcript checkpoints. Meeting
/// rows are reusable on Resume, so database status alone cannot distinguish a
/// late callback from the completed capture from a callback belonging to the
/// newly-recording generation of the same row.
struct MeetingTranscriptCheckpointGenerationTracker {
    private var generationByMeetingID: [Int64: UUID] = [:]

    mutating func replaceGeneration(for meetingID: Int64, with generation: UUID) {
        generationByMeetingID[meetingID] = generation
    }

    func accepts(meetingID: Int64, generation: UUID) -> Bool {
        generationByMeetingID[meetingID] == generation
    }
}
