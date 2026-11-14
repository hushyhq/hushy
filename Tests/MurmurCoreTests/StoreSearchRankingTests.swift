import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// Search ranks by best match first, newest as the tie-break (founder, 2026-10-26; TRY-73).
/// Before this, `searchDictations` ordered strictly newest-first, so with a small limit (the palette
/// shows 8) a long history buried the rows that actually talk about the query. Invented text only; the
/// stores are in memory or a temp file, never the user's database.
@Suite("Store search ranking")
struct StoreSearchRankingTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func dictation(_ text: String, minutes: Int) -> Dictation {
        Dictation(
            createdAt: base.addingTimeInterval(Double(minutes) * 60),
            rawText: text.lowercased(), text: text, durationSeconds: 1)
    }

    @Test("an older row that is a better match beats newer weak matches inside a small limit")
    func betterMatchBeatsNewer() throws {
        let store = try Store()
        let strong = try store.save(dictation("Invoice invoice invoice: please check the invoice.", minutes: 0))
        for index in 1...40 {
            _ = try store.save(dictation(
                "Send the weekly update to the team about the invoice and the schedule for item \(index).",
                minutes: index))
        }
        let results = try store.searchDictations("invoice", limit: 8)
        #expect(results.count == 8)
        #expect(results.first?.id == strong.id)
    }

    @Test("equally good matches come back newest first")
    func tiesBreakNewestFirst() throws {
        let store = try Store()
        let offsets = [4, 1, 7, 0, 5]
        for offset in offsets { _ = try store.save(dictation("Budget review note \(offset).", minutes: offset)) }
        let results = try store.searchDictations("budget review", limit: 100)
        #expect(results.map { Int($0.createdAt.timeIntervalSince(base) / 60) } == offsets.sorted(by: >))
    }

    @Test("a date range still applies and the best match inside it comes first")
    func dateRangeWithRanking() throws {
        let store = try Store()
        _ = try store.save(dictation("Roadmap roadmap roadmap roadmap.", minutes: 0))
        let inRangeStrong = try store.save(dictation("Roadmap roadmap roadmap talk.", minutes: 100))
        _ = try store.save(dictation("We should talk about the roadmap with the whole team on Friday.", minutes: 110))
        let range = Store.DictationDateRange(
            start: base.addingTimeInterval(50 * 60), end: base.addingTimeInterval(200 * 60))
        let results = try store.searchDictations("roadmap", dateRange: range, limit: 10)
        #expect(results.count == 2)
        #expect(results.first?.id == inRangeStrong.id)
    }

    @Test("a title match outranks a transcript-only match, even when the transcript note is newer")
    func noteTitleOutranksTranscript() throws {
        let store = try Store()
        // Other notes that do not mention the word, so it is rare enough to carry weight (BM25 gives a word
        // found in most rows next to no weight).
        for index in 0..<12 { _ = try store.save(note(title: "Standup \(index)", transcript: "Nothing to report.", minutes: 200 + index)) }
        let talk = "We went through the hiring plan and the office move. "
        let titled = try store.save(note(title: "Pricing review", transcript: String(repeating: talk, count: 20), minutes: 0))
        _ = try store.save(note(
            title: "Weekly sync", transcript: String(repeating: talk, count: 5) + String(repeating: " Pricing came up.", count: 3),
            minutes: 60))
        let results = try store.searchNotes("pricing")
        #expect(results.count == 2)
        #expect(results.first?.id == titled.id)
    }

    @Test("equally good note matches come back newest first")
    func notesTieBreakNewestFirst() throws {
        let store = try Store()
        let older = try store.save(note(title: "Hiring plan", transcript: "Open roles.", minutes: 0))
        let newer = try store.save(note(title: "Hiring plan", transcript: "Open roles.", minutes: 30))
        let results = try store.searchNotes("hiring")
        #expect(results.map(\.id) == [newer.id, older.id])
    }

    private func note(title: String, transcript: String, minutes: Int) -> Note {
        var note = Note(
            title: title, createdAt: base.addingTimeInterval(Double(minutes) * 60), transcript: transcript)
        note.status = .ready
        return note
    }
}
