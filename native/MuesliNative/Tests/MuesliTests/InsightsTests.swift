import AppKit
import Foundation
@testable import MuesliCore
@testable import MuesliNativeApp
import SQLite3
import Testing

@Suite("Local Insights", .serialized)
struct InsightsTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-insights-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    @Test("empty history returns a complete zero-filled range")
    func emptyHistory() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800) // 2026-07-15T00:00:00Z
        let snapshot = try store.insightsSnapshot(range: .thirtyDays, now: now)

        #expect(snapshot.selected.totalWords == 0)
        #expect(snapshot.dailyActivity.count == 30)
        #expect(snapshot.activeDaysInRange == 0)
        #expect(snapshot.dictationWords.isEmpty)
        #expect(snapshot.meetingWords.isEmpty)
    }

    @Test("range aggregates dictations and only finished meeting states")
    func rangeAggregation() throws {
        let store = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        let recent = calendar.date(byAdding: .day, value: -2, to: now)!
        let old = calendar.date(byAdding: .day, value: -45, to: now)!

        try store.insertDictation(text: "Nordic signal signal", durationSeconds: 60, startedAt: recent.addingTimeInterval(-60), endedAt: recent)
        try store.insertDictation(text: "old archive", durationSeconds: 60, startedAt: old.addingTimeInterval(-60), endedAt: old)
        try store.insertMeeting(
            title: "Finished", calendarEventID: nil, startTime: recent,
            endTime: recent.addingTimeInterval(60), rawTranscript: "product rhythm rhythm",
            formattedNotes: "", micAudioPath: nil, systemAudioPath: nil
        )
        let live = try store.createLiveMeeting(title: "Still live", calendarEventID: nil, startTime: recent)
        try store.updateMeetingManualNotes(id: live, manualNotes: "should stay private from insights")

        let snapshot = try store.insightsSnapshot(range: .thirtyDays, now: now, calendar: calendar)
        #expect(snapshot.lifetime.dictationWords == 5)
        #expect(snapshot.selected.dictationWords == 3)
        #expect(snapshot.selected.meetings == 1)
        #expect(snapshot.selected.meetingWords == 3)
        #expect(snapshot.dailyActivity.reduce(0) { $0 + $1.meetings } == 1)
        #expect(snapshot.dictationWords.first?.word == "signal")
        #expect(snapshot.meetingWords.first?.word == "rhythm")
    }

    @Test("deleted history is absent from totals, activity, and vocabulary")
    func deletedHistory() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        let id = try store.insertDictation(
            text: "vanishing vocabulary", durationSeconds: 10,
            startedAt: now.addingTimeInterval(-10), endedAt: now
        )
        let beforeDeletion = try store.insightsSnapshot(range: .allTime, now: now)
        #expect(beforeDeletion.lifetime.totalWords == 2)
        #expect(beforeDeletion.dictationWords.contains { $0.word == "vocabulary" })

        try store.deleteDictation(id: id)

        let snapshot = try store.insightsSnapshot(range: .allTime, now: now)
        #expect(snapshot.lifetime.totalWords == 0)
        #expect(snapshot.activeDaysInRange == 0)
        #expect(snapshot.dictationWords.isEmpty)
    }

    @Test("incremental cache adds newly completed records without rebuilding prior contributions")
    func incrementalAddition() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        try store.insertDictation(text: "alpha alpha", durationSeconds: 10, startedAt: now.addingTimeInterval(-10), endedAt: now)
        let first = try store.insightsSnapshot(range: .allTime, now: now)
        #expect(first.lifetime.totalWords == 2)

        let meetingID = try store.createLiveMeeting(title: "Notes", calendarEventID: nil, startTime: now)
        _ = try store.insightsSnapshot(range: .allTime, now: now)
        try store.updateMeetingManualNotes(id: meetingID, manualNotes: "bravo bravo bravo")
        try store.updateMeetingStatus(id: meetingID, status: .noteOnly)

        let updated = try store.insightsSnapshot(range: .allTime, now: now)
        #expect(updated.lifetime.totalWords == 5)
        #expect(updated.lifetime.meetings == 1)
        #expect(updated.meetingWords.first == InsightsWordFrequency(word: "bravo", count: 3))
    }

    @Test("lossless contribution codec round trips sorted token counts")
    func contributionCodecRoundTrip() {
        let pairs = (1...2_000).map {
            InsightsContributionCodec.Pair(tokenID: Int64($0 * 3), count: ($0 % 17) + 1)
        }
        let encoded = InsightsContributionCodec.encode(pairs)
        let decoded = InsightsContributionCodec.decode(encoded)

        #expect(decoded == pairs)
        #expect(encoded.count < pairs.count * MemoryLayout<InsightsContributionCodec.Pair>.stride)
    }

    @Test("unchanged snapshots reuse the same record cache")
    func unchangedSnapshotReusesCache() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        try store.insertDictation(text: "cache efficiency efficiency", durationSeconds: 15, startedAt: now.addingTimeInterval(-15), endedAt: now)
        let first = try store.insightsSnapshot(range: .allTime, now: now)
        let before = try cacheFootprint(store)
        let second = try store.insightsSnapshot(range: .allTime, now: now)
        let after = try cacheFootprint(store)

        #expect(second == first)
        #expect(after.records == before.records)
        #expect(after.blobBytes == before.blobBytes)
    }

    @MainActor
    @Test("share card renders as a fixed-size PNG")
    func shareCardRendering() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        try store.insertDictation(
            text: "shareable local activity", durationSeconds: 12,
            startedAt: now.addingTimeInterval(-12), endedAt: now
        )
        let snapshot = try store.insightsSnapshot(range: .twelveMonths, now: now)

        let image = try #require(InsightsShareRenderer.render(snapshot: snapshot, rangeLabel: "12 months"))
        let png = try #require(InsightsShareRenderer.pngData(for: image))
        let template = try #require(InsightsShareRenderer.renderTemplate())
        let templatePNG = try #require(InsightsShareRenderer.pngData(for: template))

        #expect(image.size == InsightsShareRenderer.size)
        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        #expect(template.size == InsightsShareRenderer.size)
        #expect(Array(templatePNG.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    }

    @Test("calendar range remains day-correct across daylight saving changes")
    func daylightSavingRange() throws {
        let store = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12))!

        let snapshot = try store.insightsSnapshot(range: .thirtyDays, now: now, calendar: calendar)
        #expect(snapshot.dailyActivity.count == 30)
        #expect(calendar.isDate(snapshot.dailyActivity.first!.date, inSameDayAs: calendar.date(byAdding: .day, value: -29, to: now)!))
        #expect(calendar.isDate(snapshot.dailyActivity.last!.date, inSameDayAs: now))
    }

    @Test("word analysis removes stop words and ranks ties alphabetically")
    func wordAnalysis() {
        let words = InsightsWordAnalyzer.frequencies(
            in: "The aurora aurora and fjord fjord beacon",
            limit: 10
        )
        #expect(!words.contains { $0.word == "the" || $0.word == "and" })
        #expect(words.map(\.word).prefix(2) == ["aurora", "fjord"])
        #expect(words.first?.count == 2)
    }

    @Test("word analysis accepts Unicode and rejects numeric noise")
    func unicodeWordAnalysis() {
        let words = InsightsWordAnalyzer.frequencies(in: "नमस्ते नमस्ते 1234 x café café", limit: 10)
        #expect(words.contains { $0.word == "नमस्ते" && $0.count == 2 })
        #expect(words.contains { $0.word == "café" && $0.count == 2 })
        #expect(!words.contains { $0.word == "1234" || $0.word == "x" })
    }

    @Test("meeting word analysis removes diarization labels and transcript annotations")
    func meetingLabelsAreRemoved() {
        let transcript = """
        [00:01:04] Speaker 1: Roadmap roadmap planning
        [00:01:08] You: Product launch
        [00:01:12] Others: [MUSIC PLAYING] Product review
        """
        let words = InsightsWordAnalyzer.meetingFrequencies(in: transcript, limit: 20)

        #expect(!words.contains { ["speaker", "you", "others", "music", "playing"].contains($0.word) })
        #expect(words.first?.word == "product")
        #expect(words.first?.count == 2)
        #expect(words.contains { $0.word == "roadmap" && $0.count == 2 })
    }

    @Test("word analysis is deterministically capped for large input")
    func largeInputIsCapped() {
        let text = (0..<200).map { "term" + String(repeating: "a", count: $0 + 2) }.joined(separator: " ")
        let words = InsightsWordAnalyzer.frequencies(in: text, limit: 48)
        #expect(words.count == 48)
        #expect(words == words.sorted { $0.count == $1.count ? $0.word < $1.word : $0.count > $1.count })
    }

    private func cacheFootprint(_ store: DictationStore) throws -> (records: Int, blobBytes: Int) {
        var db: OpaquePointer?
        guard sqlite3_open(store.databasePath().path, &db) == SQLITE_OK else {
            throw NSError(domain: "InsightsTests", code: 1)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*), COALESCE(SUM(length(token_blob)),0) FROM insights_record_cache", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "InsightsTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "InsightsTests", code: 3) }
        return (Int(sqlite3_column_int(statement, 0)), Int(sqlite3_column_int(statement, 1)))
    }
}
