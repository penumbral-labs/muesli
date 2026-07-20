import Foundation

enum MeetingTerminationState: Equatable {
    case none
    case starting
    case recording
    case processing
}

enum MeetingTerminationPolicy {
    static func state(
        isStarting: Bool,
        hasActiveSession: Bool,
        isRecording: Bool,
        isStopping: Bool
    ) -> MeetingTerminationState {
        if isStarting {
            return .starting
        }
        if hasActiveSession {
            return isRecording ? .recording : .processing
        }
        if isStopping {
            return .processing
        }
        return .none
    }
}

/// Decides whether an asynchronously-finalizing meeting still owns the shared
/// status bar and waveform UI. Meeting audio may release its capture lease
/// before transcript work finishes, so a newly-started dictation must take
/// priority over every late progress or completion callback from that meeting.
enum MeetingFinalizationUIUpdatePolicy {
    static func canPublishProgress(
        isUIOwner: Bool,
        isMeetingRecording: Bool,
        isStartingMeeting: Bool
    ) -> Bool {
        isUIOwner
            && !isMeetingRecording
            && !isStartingMeeting
    }

    static func canRestoreIdle(
        ownedUIBeforeCompletion: Bool,
        isMeetingRecording: Bool,
        isStartingMeeting: Bool,
        activeFinalizationCount: Int
    ) -> Bool {
        ownedUIBeforeCompletion
            && !isMeetingRecording
            && !isStartingMeeting
            && activeFinalizationCount == 0
    }
}

/// Reconciles the historical shared `DictationState` display with meeting
/// finalization. A meeting may display `.transcribing` after releasing every
/// audio graph; that display must not block a new foreground capture.
enum ForegroundActivityUIClaimPolicy {
    static func dictationPrepareClaimsUI(
        isStreamingBackend: Bool,
        hasActiveAudioSession: Bool
    ) -> Bool {
        !isStreamingBackend && !hasActiveAudioSession
    }

    static func dictationArmClaimsUI(isStreamingBackend: Bool) -> Bool {
        !isStreamingBackend
    }

    static func canBeginCapture(
        sharedState: DictationState,
        meetingFinalizationOwnsUI: Bool,
        allowsPreparedState: Bool = false
    ) -> Bool {
        if sharedState == .idle {
            return true
        }
        if allowsPreparedState && sharedState == .preparing {
            return true
        }
        return meetingFinalizationOwnsUI && sharedState == .transcribing
    }
}

/// Tracks independently-running meeting finalizations and which one is allowed
/// to drive the shared processing UI. Tokens are stable for the lifetime of a
/// finalization, so out-of-order completion cannot transfer UI ownership to an
/// unrelated task.
struct MeetingFinalizationTracker {
    struct Token: Hashable {
        let id: UUID

        init(id: UUID = UUID()) {
            self.id = id
        }
    }

    private var activeTokens: Set<Token> = []
    private(set) var uiOwner: Token?

    var count: Int { activeTokens.count }

    mutating func begin(
        token: Token = Token(),
        designateAsUIOwner: Bool
    ) -> Token {
        activeTokens.insert(token)
        if designateAsUIOwner {
            uiOwner = token
        }
        return token
    }

    mutating func complete(_ token: Token) {
        activeTokens.remove(token)
        if uiOwner == token {
            uiOwner = nil
        }
    }

    /// Permanently yields the shared activity UI to a foreground operation
    /// such as dictation, computer use, or a newly-starting meeting. Older
    /// finalizations keep running, but can never reclaim the UI afterward.
    mutating func relinquishUIOwnership() {
        uiOwner = nil
    }

    func isUIOwner(_ token: Token) -> Bool {
        activeTokens.contains(token) && uiOwner == token
    }
}
