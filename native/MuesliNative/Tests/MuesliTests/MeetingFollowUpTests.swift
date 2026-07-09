import Foundation
import CloudKit
import SQLite3
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting follow-up policy")
struct MeetingFollowUpPolicyTests {
    @Test("a completed meeting can spawn a follow-up")
    func completedCanStartFollowUp() {
        #expect(MeetingFollowUpPolicy.canStartFollowUp(status: .completed))
    }

    @Test("non-completed meetings cannot spawn follow-ups")
    func nonCompletedCannotStartFollowUp() {
        for status in [MeetingStatus.recording, .processing, .noteOnly, .failed] {
            #expect(!MeetingFollowUpPolicy.canStartFollowUp(status: status))
        }
    }

    @Test("follow-up title prefixes the predecessor title")
    func followUpTitlePrefixes() {
        #expect(MeetingFollowUpPolicy.followUpTitle(from: "Design sync") == "Follow-up: Design sync")
    }

    @Test("follow-up title does not stack prefixes when chaining follow-ups")
    func followUpTitleDoesNotStack() {
        #expect(MeetingFollowUpPolicy.followUpTitle(from: "Follow-up: Design sync") == "Follow-up: Design sync")
        #expect(MeetingFollowUpPolicy.followUpTitle(from: "Follow-up: Follow-up: Design sync") == "Follow-up: Design sync")
    }

    @Test("follow-up title falls back for empty predecessor titles")
    func followUpTitleEmptyFallback() {
        #expect(MeetingFollowUpPolicy.followUpTitle(from: "   ") == "Follow-up meeting")
        #expect(MeetingFollowUpPolicy.followUpTitle(from: "Follow-up: ") == "Follow-up meeting")
    }

    @Test("carried context passes structured notes through")
    func carriedContextStructuredNotes() {
        let predecessor = makeMeeting(notes: "## Summary\n\nDecided X.\n\n### Action items\n- [ ] Ship Y")
        #expect(MeetingFollowUpPolicy.carriedContext(from: predecessor) == predecessor.formattedNotes)
    }

    @Test("carried context skips raw-transcript fallback notes")
    func carriedContextSkipsRawTranscriptFallback() {
        let predecessor = makeMeeting(notes: "## Raw transcript\n\nhello world hello world")
        #expect(MeetingFollowUpPolicy.carriedContext(from: predecessor) == nil)
    }

    @Test("carried context skips empty notes")
    func carriedContextSkipsEmptyNotes() {
        #expect(MeetingFollowUpPolicy.carriedContext(from: makeMeeting(notes: "  \n ")) == nil)
    }

    @Test("carried context truncates very long notes")
    func carriedContextTruncates() throws {
        let long = "## Summary\n" + String(repeating: "a", count: MeetingFollowUpPolicy.maxCarriedNotesLength + 500)
        let carried = try #require(MeetingFollowUpPolicy.carriedContext(fromPredecessorNotes: long))
        #expect(carried.count < long.count)
        #expect(carried.hasSuffix("[…previous notes truncated]"))
    }

    private func makeMeeting(notes: String) -> MeetingRecord {
        MeetingRecord(
            id: 1,
            title: "Design sync",
            startTime: "2026-07-01T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "hello",
            formattedNotes: notes,
            wordCount: 1,
            folderID: nil
        )
    }
}

@Suite("Meeting follow-up threads", .serialized)
struct MeetingFollowUpThreadTests {
    /// Creates a DictationStore backed by a temporary database file.
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-followup-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    @discardableResult
    private func makeMeeting(
        _ store: DictationStore,
        title: String,
        startTime: Date = Date(),
        followUpToID: Int64? = nil,
        folderID: Int64? = nil
    ) throws -> Int64 {
        try store.createLiveMeeting(
            title: title,
            calendarEventID: nil,
            startTime: startTime,
            folderID: folderID,
            followUpToID: followUpToID
        )
    }

    private func tableColumns(_ table: String, store: DictationStore) throws -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "MeetingFollowUpTests", code: 1)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "MeetingFollowUpTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }

    private func completeMeeting(_ store: DictationStore, id: Int64, title: String) throws {
        let start = Date()
        try store.completeLiveMeeting(
            id: id,
            title: title,
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            durationSeconds: 60,
            rawTranscript: "\(title) transcript",
            formattedNotes: "\(title) notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    @Test("follow-up link persists and reads back on the meeting record")
    func followUpLinkPersists() throws {
        let store = try makeStore()
        let rootID = try makeMeeting(store, title: "Root")
        let followUpID = try makeMeeting(store, title: "Follow-up: Root", followUpToID: rootID)

        let followUp = try #require(try store.meeting(id: followUpID))
        #expect(followUp.followUpToID == rootID)
        let root = try #require(try store.meeting(id: rootID))
        #expect(root.followUpToID == nil)
    }

    @Test("fresh schema stores follow-up metadata on meetings only")
    func freshSchemaStoresFollowUpMetadataOnMeetingsOnly() throws {
        let store = try makeStore()

        let dictationColumns = try tableColumns("dictations", store: store)
        let meetingColumns = try tableColumns("meetings", store: store)

        #expect(!dictationColumns.contains("follow_up_to_id"))
        #expect(!dictationColumns.contains("follow_up_to_record_name"))
        #expect(meetingColumns.contains("follow_up_to_id"))
        #expect(meetingColumns.contains("follow_up_to_record_name"))
    }

    @Test("created follow-up inherits the requested folder")
    func followUpInheritsFolder() throws {
        let store = try makeStore()
        let folderID = try store.createFolder(name: "Projects")
        let rootID = try makeMeeting(store, title: "Root", folderID: folderID)
        let followUpID = try makeMeeting(store, title: "Follow-up: Root", followUpToID: rootID, folderID: folderID)

        let followUp = try #require(try store.meeting(id: followUpID))
        #expect(followUp.folderID == folderID)
    }

    @Test("successor and predecessor queries walk one hop in each direction")
    func successorAndPredecessor() throws {
        let store = try makeStore()
        let a = try makeMeeting(store, title: "A")
        let b = try makeMeeting(store, title: "B", followUpToID: a)

        #expect(try store.meetingSuccessorID(of: a) == b)
        #expect(try store.meetingSuccessorID(of: b) == nil)
        #expect(try store.meetingPredecessorID(of: b) == a)
        #expect(try store.meetingPredecessorID(of: a) == nil)
    }

    @Test("latest meeting in thread resolves from any member")
    func latestInThread() throws {
        let store = try makeStore()
        let a = try makeMeeting(store, title: "A")
        let b = try makeMeeting(store, title: "B", followUpToID: a)
        let c = try makeMeeting(store, title: "C", followUpToID: b)

        #expect(try store.latestMeetingIDInThread(of: a) == c)
        #expect(try store.latestMeetingIDInThread(of: b) == c)
        #expect(try store.latestMeetingIDInThread(of: c) == c)
    }

    @Test("a standalone meeting is its own thread")
    func standaloneThread() throws {
        let store = try makeStore()
        let a = try makeMeeting(store, title: "A")

        #expect(try store.latestMeetingIDInThread(of: a) == a)
        #expect(try store.meetingThreadIDs(containing: a) == [a])
    }

    @Test("thread ids are ordered root to latest from any member")
    func threadOrdering() throws {
        let store = try makeStore()
        let a = try makeMeeting(store, title: "A")
        let b = try makeMeeting(store, title: "B", followUpToID: a)
        let c = try makeMeeting(store, title: "C", followUpToID: b)

        for member in [a, b, c] {
            #expect(try store.meetingThreadIDs(containing: member) == [a, b, c])
        }
    }

    @Test("soft-deleted successors do not extend the thread")
    func deletedSuccessorExcluded() throws {
        let store = try makeStore()
        let a = try makeMeeting(store, title: "A")
        let b = try makeMeeting(store, title: "B", followUpToID: a)
        try store.deleteMeeting(id: b)

        #expect(try store.meetingSuccessorID(of: a) == nil)
        #expect(try store.latestMeetingIDInThread(of: a) == a)
        #expect(try store.meetingThreadIDs(containing: a) == [a])
    }

    @Test("a predecessor can have multiple live follow-ups ordered chronologically")
    func multipleLiveFollowUpsPerPredecessor() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        let a = try makeMeeting(store, title: "A", startTime: start)
        let later = try makeMeeting(store, title: "Later follow-up", startTime: start.addingTimeInterval(120), followUpToID: a)
        let earlier = try makeMeeting(store, title: "Earlier follow-up", startTime: start.addingTimeInterval(60), followUpToID: a)

        #expect(try store.meetingPredecessorID(of: earlier) == a)
        #expect(try store.meetingPredecessorID(of: later) == a)
        #expect(try store.meetingSuccessorID(of: a) == earlier)
        #expect(try store.meetingThreadIDs(containing: a) == [a, earlier, later])
        #expect(try store.latestMeetingIDInThread(of: a) == later)
    }

    @Test("soft-deleting a middle meeting splits the remaining thread")
    func deletedMiddleMeetingSplitsThread() throws {
        let store = try makeStore()
        let a = try makeMeeting(store, title: "A")
        let b = try makeMeeting(store, title: "B", followUpToID: a)
        let c = try makeMeeting(store, title: "C", followUpToID: b)

        try store.deleteMeeting(id: b)

        #expect(try store.meetingSuccessorID(of: a) == nil)
        #expect(try store.meetingPredecessorID(of: c) == nil)
        #expect(try store.meetingThreadIDs(containing: c) == [c])
    }

    @Test("purging a deleted predecessor does not fail with a live successor")
    func purgeDeletedPredecessorWithSuccessor() throws {
        let store = try makeStore()
        let a = try makeMeeting(store, title: "A")
        let b = try makeMeeting(store, title: "B", followUpToID: a)

        try store.deleteMeeting(id: a)
        let purged = try store.purgeSoftDeletedTextRecords(olderThan: 0, now: Date().addingTimeInterval(1))

        #expect(purged.meetings == 1)
        #expect(try store.meetingPredecessorID(of: b) == nil)
    }

    @Test("sync export carries stable predecessor record names")
    func syncExportCarriesStablePredecessorRecordName() throws {
        let store = try makeStore()
        let rootID = try makeMeeting(store, title: "Root")
        let followUpID = try makeMeeting(store, title: "Follow-up: Root", followUpToID: rootID)
        try completeMeeting(store, id: rootID, title: "Root")
        try completeMeeting(store, id: followUpID, title: "Follow-up: Root")

        let records = try store.textRecordsNeedingSync(limit: 10)
            .filter { $0.kind == .meeting }
        let root = try #require(records.first { $0.title == "Root" })
        let followUp = try #require(records.first { $0.title == "Follow-up: Root" })

        #expect(root.followUpToRecordName == nil)
        #expect(followUp.followUpToRecordName == root.id)
    }

    @Test("sync import resolves follow-up links by stable record name")
    func syncImportResolvesStablePredecessorRecordName() throws {
        let store = try makeStore()
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)

        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "meeting-follow",
            kind: .meeting,
            title: "Follow-up: Root",
            text: "follow transcript",
            summaryText: "follow notes",
            source: "macos",
            meetingStatus: .completed,
            createdAt: timestamp.addingTimeInterval(60),
            updatedAt: timestamp.addingTimeInterval(60),
            startedAt: timestamp.addingTimeInterval(60),
            endedAt: timestamp.addingTimeInterval(120),
            durationSeconds: 60,
            wordCount: 2,
            followUpToRecordName: "meeting-root"
        )))
        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "meeting-follow-2",
            kind: .meeting,
            title: "Second follow-up: Root",
            text: "second follow transcript",
            summaryText: "second follow notes",
            source: "macos",
            meetingStatus: .completed,
            createdAt: timestamp.addingTimeInterval(180),
            updatedAt: timestamp.addingTimeInterval(180),
            startedAt: timestamp.addingTimeInterval(180),
            endedAt: timestamp.addingTimeInterval(240),
            durationSeconds: 60,
            wordCount: 3,
            followUpToRecordName: "meeting-root"
        )))
        #expect(try store.upsertSyncedTextRecord(SyncTextRecord(
            id: "meeting-root",
            kind: .meeting,
            title: "Root",
            text: "root transcript",
            summaryText: "root notes",
            source: "macos",
            meetingStatus: .completed,
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            durationSeconds: 60,
            wordCount: 2
        )))

        let meetings = try store.recentMeetings(limit: 10)
        let root = try #require(meetings.first { $0.title == "Root" })
        let followUp = try #require(meetings.first { $0.title == "Follow-up: Root" })
        let secondFollowUp = try #require(meetings.first { $0.title == "Second follow-up: Root" })

        #expect(followUp.followUpToRecordName == "meeting-root")
        #expect(secondFollowUp.followUpToRecordName == "meeting-root")
        #expect(try store.meetingPredecessorID(of: followUp.id) == root.id)
        #expect(try store.meetingPredecessorID(of: secondFollowUp.id) == root.id)
        #expect(try store.meetingThreadIDs(containing: root.id) == [root.id, followUp.id, secondFollowUp.id])
    }

    @Test("CloudKit sync payload carries stable predecessor record name")
    func cloudKitPayloadCarriesStablePredecessorRecordName() {
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)
        let cloud = MuesliICloudSyncEngine.syncZoneCloudRecord(from: SyncTextRecord(
            id: "meeting-follow",
            kind: .meeting,
            title: "Follow-up: Root",
            text: "follow transcript",
            source: "macos",
            meetingStatus: .completed,
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            durationSeconds: 60,
            wordCount: 2,
            followUpToRecordName: "meeting-root"
        ))

        #expect(cloud["followUpToRecordName"] as? String == "meeting-root")
    }

    @Test("legacy meeting record decode defaults follow-up fields")
    func legacyMeetingRecordDecodeDefaultsFollowUpFields() throws {
        let json = """
        {
          "id": 1,
          "title": "Legacy",
          "startTime": "2026-07-01T10:00:00Z",
          "durationSeconds": 60,
          "rawTranscript": "hello",
          "formattedNotes": "notes",
          "wordCount": 1,
          "folderID": null
        }
        """
        let record = try JSONDecoder().decode(MeetingRecord.self, from: Data(json.utf8))

        #expect(record.followUpToID == nil)
        #expect(record.followUpToRecordName == nil)
    }

    @Test("meeting record Codable round-trip preserves follow-up fields")
    func meetingRecordRoundTripPreservesFollowUpFields() throws {
        let record = MeetingRecord(
            id: 2,
            title: "Follow-up: Legacy",
            startTime: "2026-07-01T11:00:00Z",
            durationSeconds: 120,
            rawTranscript: "hello again",
            formattedNotes: "notes again",
            wordCount: 2,
            folderID: nil,
            followUpToID: 1,
            followUpToRecordName: "meeting-root"
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(MeetingRecord.self, from: data)

        #expect(decoded.followUpToID == 1)
        #expect(decoded.followUpToRecordName == "meeting-root")
    }
}

@Suite("Meeting follow-up summary prompt")
struct MeetingFollowUpSummaryPromptTests {
    @Test("user prompt includes previous meeting notes when provided")
    func userPromptIncludesPreviousNotes() {
        let prompt = MeetingSummaryClient.summaryUserPrompt(
            transcript: "we talked",
            meetingTitle: "Follow-up: Design sync",
            previousMeetingNotes: "- [ ] Ship Y"
        )
        #expect(prompt.contains("Notes from the previous meeting in this thread"))
        #expect(prompt.contains("- [ ] Ship Y"))
    }

    @Test("user prompt omits the previous-notes section when absent or blank")
    func userPromptOmitsPreviousNotesWhenAbsent() {
        let withoutNotes = MeetingSummaryClient.summaryUserPrompt(
            transcript: "we talked",
            meetingTitle: "Design sync"
        )
        #expect(!withoutNotes.contains("Notes from the previous meeting"))
        let blankNotes = MeetingSummaryClient.summaryUserPrompt(
            transcript: "we talked",
            meetingTitle: "Design sync",
            previousMeetingNotes: "  \n"
        )
        #expect(!blankNotes.contains("Notes from the previous meeting"))
    }

    @Test("instructions gain the carry-forward guidance only for follow-ups")
    func instructionsCarryForwardGuidance() {
        let template = MeetingTemplates.auto.snapshot
        let followUp = MeetingSummaryClient.summaryInstructions(for: template, previousMeetingNotes: "- [ ] Ship Y")
        #expect(followUp.contains("carry forward action items"))
        let regular = MeetingSummaryClient.summaryInstructions(for: template)
        #expect(!regular.contains("carry forward action items"))
    }
}
