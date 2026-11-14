import Foundation
import Testing
@testable import MurmurCore

/// Covers `Store.searchDictations`'s two-step (rank ids via FTS, then hydrate only that page)
/// implementation added in perf-audit-2026-09 (see docs/engineering/perf-audit-2026-09.md):
/// newest-first ordering and `limit` truncation must be identical to the single-query JOIN it
/// replaced. `CoreTests`/`StoreDateRangeTests`/`EncryptionEndToEndTests` already cover match
/// content and date-range filtering; this file only checks ordering and truncation, which a
/// two-query rewrite is most likely to get subtly wrong (e.g. losing the rank/id order when
/// re-hydrating by id). Uses an in-memory store (see `Store.init()`), never the user's real
/// database.
@Suite("Store.searchDictations ordering and limit")
struct StoreSearchOrderingTests {
    @Test("results come back newest-first, matching the createdAt-ranked id order")
    func newestFirstOrdering() throws {
        let store = try Store()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Insert out of chronological order so a bug that fell back to insertion order or
        // primary-key order would be caught.
        let offsets = [5, 1, 9, 3, 7, 0, 8, 2, 6, 4]
        for offset in offsets {
            _ = try store.save(Dictation(
                createdAt: base.addingTimeInterval(Double(offset) * 60),
                rawText: "quarterly report row \(offset)", text: "Quarterly report row \(offset).",
                durationSeconds: 1))
        }

        let results = try store.searchDictations("quarterly report", limit: 100)
        let resultOffsets = results.map { Int($0.createdAt.timeIntervalSince(base) / 60) }
        #expect(resultOffsets == offsets.sorted(by: >))
    }

    @Test("limit truncates to the newest N matches, not an arbitrary subset")
    func limitTruncatesToNewest() throws {
        let store = try Store()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<30 {
            _ = try store.save(Dictation(
                createdAt: base.addingTimeInterval(Double(index) * 60),
                rawText: "quarterly report row \(index)", text: "Quarterly report row \(index).",
                durationSeconds: 1))
        }

        let results = try store.searchDictations("quarterly report", limit: 5)
        #expect(results.count == 5)
        // Newest 5 are indices 29...25, descending.
        #expect(results.map(\.rawText) == (25..<30).reversed().map { "quarterly report row \($0)" })
    }

    @Test("no matches returns an empty array, not an error")
    func noMatchesReturnsEmpty() throws {
        let store = try Store()
        _ = try store.save(Dictation(rawText: "buy milk", text: "buy milk", durationSeconds: 1))
        #expect(try store.searchDictations("nonexistent term xyz").isEmpty)
    }

    @Test("ties in createdAt still return every matching row exactly once")
    func tiedCreatedAtReturnsAllMatches() throws {
        let store = try Store()
        let same = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: Set<Int64?> = []
        for index in 0..<5 {
            let saved = try store.save(Dictation(
                createdAt: same, rawText: "quarterly report row \(index)", text: "Quarterly report row \(index).",
                durationSeconds: 1))
            ids.insert(saved.id)
        }
        let results = try store.searchDictations("quarterly report", limit: 100)
        #expect(Set(results.map(\.id)) == ids)
        #expect(results.count == 5)
    }
}
