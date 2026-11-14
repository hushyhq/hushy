import Foundation
import Testing
@testable import MurmurCore

/// Covers `Store.DictationDateRange`'s SQL bounds: `[start, end)` semantics at `dictationPage`
/// and `searchDictations`, combined with the existing status filter and full-text search, and
/// keyset pagination staying gap/dupe-free across a bounded range. Bound *computation* (presets,
/// DST-safety) lives in `HistoryDateRange` in the app target and is covered separately; this
/// file only checks that `Store` applies whatever bounds it's given correctly. Uses an
/// in-memory store (see `Store.init()`), never the user's real database.
@Suite("Store date-range filtering")
struct StoreDateRangeTests {
    private static let day = Date(timeIntervalSince1970: 1_700_000_000) // an arbitrary anchor instant

    @Test("createdAt exactly at the start bound is included; exactly at the end bound is excluded")
    func rangeBoundaryInclusiveExclusive() throws {
        let store = try Store()
        let start = Self.day
        let end = start.addingTimeInterval(86_400)

        _ = try store.save(Dictation(createdAt: start.addingTimeInterval(-1), rawText: "before", text: "before", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: start, rawText: "at-start", text: "at-start", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: start.addingTimeInterval(3600), rawText: "inside", text: "inside", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: end.addingTimeInterval(-0.001), rawText: "just-before-end", text: "just-before-end", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: end, rawText: "at-end", text: "at-end", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: end.addingTimeInterval(1), rawText: "after", text: "after", durationSeconds: 1))

        let range = Store.DictationDateRange(start: start, end: end)
        let page = try store.dictationPage(after: nil, filter: .all, dateRange: range, pageSize: 100)

        #expect(Set(page.items.map(\.rawText)) == ["at-start", "inside", "just-before-end"])
        #expect(!page.items.map(\.rawText).contains("before"))
        #expect(!page.items.map(\.rawText).contains("at-end")) // end is exclusive
        #expect(!page.items.map(\.rawText).contains("after"))
    }

    @Test("date range combines with the status filter (AND, not OR)")
    func combinesWithStatusFilter() throws {
        let store = try Store()
        let start = Self.day
        let end = start.addingTimeInterval(86_400)
        let inside = start.addingTimeInterval(1_000)
        let outside = end.addingTimeInterval(1_000)

        _ = try store.save(Dictation(createdAt: inside, rawText: "in-range-ok", text: "in-range-ok", durationSeconds: 1, status: .inserted))
        _ = try store.save(Dictation(createdAt: inside.addingTimeInterval(1), rawText: "in-range-needs-attention", text: "", durationSeconds: 1, status: .failed))
        _ = try store.save(Dictation(createdAt: outside, rawText: "out-of-range-needs-attention", text: "", durationSeconds: 1, status: .failed))

        let range = Store.DictationDateRange(start: start, end: end)
        let page = try store.dictationPage(after: nil, filter: .needsAttention, dateRange: range, pageSize: 100)

        #expect(page.items.map(\.rawText) == ["in-range-needs-attention"])
    }

    @Test("date range combines with full-text search (AND, not OR)")
    func combinesWithTextSearch() throws {
        let store = try Store()
        let start = Self.day
        let end = start.addingTimeInterval(86_400)
        let inside = start.addingTimeInterval(1_000)
        let outside = end.addingTimeInterval(1_000)

        _ = try store.save(Dictation(createdAt: inside, rawText: "ship the release", text: "ship the release", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: inside.addingTimeInterval(1), rawText: "buy milk", text: "buy milk", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: outside, rawText: "ship another release", text: "ship another release", durationSeconds: 1))

        let range = Store.DictationDateRange(start: start, end: end)
        let results = try store.searchDictations("release", dateRange: range, limit: 100)

        #expect(results.map(\.rawText) == ["ship the release"])
    }

    @Test("keyset pagination across a filtered range returns every row exactly once, in order, with no gaps or dupes")
    func pagesTileFilteredRangeWithoutGapsOrDupes() throws {
        let store = try Store()
        let start = Self.day
        let end = start.addingTimeInterval(86_400)

        // 23 rows inside the range, plus decoys just outside both edges.
        for index in 0..<23 {
            _ = try store.save(Dictation(
                createdAt: start.addingTimeInterval(Double(index) * 60),
                rawText: "in-\(index)", text: "in-\(index)", durationSeconds: 1))
        }
        _ = try store.save(Dictation(createdAt: start.addingTimeInterval(-60), rawText: "decoy-before", text: "decoy-before", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: end.addingTimeInterval(60), rawText: "decoy-after", text: "decoy-after", durationSeconds: 1))

        let range = Store.DictationDateRange(start: start, end: end)
        var seen: [String] = []
        var cursor: Store.DictationCursor?
        var pages = 0
        while true {
            let page = try store.dictationPage(after: cursor, filter: .all, dateRange: range, pageSize: 7)
            seen += page.items.map(\.rawText)
            pages += 1
            guard page.hasMore, let last = page.items.last, let id = last.id else { break }
            cursor = Store.DictationCursor(createdAt: last.createdAt, id: id)
            #expect(pages < 10) // guards against an infinite loop if hasMore is ever wrong
        }

        #expect(seen.count == 23)
        #expect(Set(seen).count == 23)
        #expect(!seen.contains("decoy-before"))
        #expect(!seen.contains("decoy-after"))
        // Newest first end to end.
        let expectedOrder = (0..<23).reversed().map { "in-\($0)" }
        #expect(seen == expectedOrder)
    }

    @Test("a range matching nothing returns an empty, non-crashing page")
    func emptyRange() throws {
        let store = try Store()
        _ = try store.save(Dictation(createdAt: Self.day, rawText: "outside", text: "outside", durationSeconds: 1))

        let farFuture = Self.day.addingTimeInterval(365 * 86_400)
        let range = Store.DictationDateRange(start: farFuture, end: farFuture.addingTimeInterval(86_400))
        let page = try store.dictationPage(after: nil, filter: .all, dateRange: range, pageSize: 100)

        #expect(page.items.isEmpty)
        #expect(!page.hasMore)
    }
}
