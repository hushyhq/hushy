import Foundation
import Testing
@testable import MurmurCore

/// Covers `Store.dictationPage`'s keyset pagination: ordering, ties on `createdAt` (bulk
/// imports and fast successive dictations often share a timestamp to the second), and each
/// `DictationPageFilter`. Uses an in-memory store (see `Store.init()`), never the user's
/// real database.
@Suite("Store dictation paging")
struct StorePagingTests {
    @Test("pages come back newest first, and pages tile the full set with no gaps or dupes")
    func ordersAndTilesPages() throws {
        let store = try Store()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<25 {
            _ = try store.save(Dictation(
                createdAt: base.addingTimeInterval(Double(index)),
                rawText: "item \(index)", text: "item \(index)", durationSeconds: 1))
        }

        var seenIDs: [Int64] = []
        var cursor: Store.DictationCursor?
        var pages = 0
        while true {
            let page = try store.dictationPage(after: cursor, filter: .all, pageSize: 10)
            seenIDs += page.items.compactMap(\.id)
            pages += 1
            guard page.hasMore, let last = page.items.last, let id = last.id else { break }
            cursor = Store.DictationCursor(createdAt: last.createdAt, id: id)
            #expect(pages < 10) // guards against an infinite loop if hasMore is ever wrong
        }

        #expect(pages == 3) // 10 + 10 + 5
        #expect(seenIDs.count == 25)
        #expect(Set(seenIDs).count == 25) // no duplicates across page boundaries
        // Newest first: the createdAt values corresponding to seenIDs must be strictly descending.
        let byID = Dictionary(uniqueKeysWithValues: try store.allDictations().map { ($0.id!, $0.createdAt) })
        let orderedDates = seenIDs.map { byID[$0]! }
        #expect(orderedDates == orderedDates.sorted(by: >))
    }

    @Test("ties on createdAt are broken by id, so no row is skipped or duplicated")
    func breaksTiesOnCreatedAt() throws {
        let store = try Store()
        let sameInstant = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [Int64] = []
        for index in 0..<6 {
            let saved = try store.save(Dictation(
                createdAt: sameInstant, rawText: "tie \(index)", text: "tie \(index)", durationSeconds: 1))
            ids.append(saved.id!)
        }

        let firstPage = try store.dictationPage(after: nil, filter: .all, pageSize: 3)
        #expect(firstPage.items.count == 3)
        #expect(firstPage.hasMore)
        // Newest-first tie-break is descending id.
        #expect(firstPage.items.map(\.id) == ids.sorted(by: >).prefix(3).map { $0 })

        let last = firstPage.items.last!
        let cursor = Store.DictationCursor(createdAt: last.createdAt, id: last.id!)
        let secondPage = try store.dictationPage(after: cursor, filter: .all, pageSize: 3)
        #expect(secondPage.items.count == 3)
        #expect(!secondPage.hasMore)

        let allSeen = Set((firstPage.items + secondPage.items).compactMap(\.id))
        #expect(allSeen == Set(ids))
    }

    @Test("needsAttention filter excludes only inserted dictations")
    func needsAttentionFilter() throws {
        let store = try Store()
        let now = Date()
        _ = try store.save(Dictation(createdAt: now, rawText: "ok", text: "ok", durationSeconds: 1, status: .inserted))
        _ = try store.save(Dictation(createdAt: now.addingTimeInterval(1), rawText: "", text: "", durationSeconds: 1, status: .failed))
        _ = try store.save(Dictation(createdAt: now.addingTimeInterval(2), rawText: "x", text: "", durationSeconds: 1, status: .notInserted))
        _ = try store.save(Dictation(createdAt: now.addingTimeInterval(3), rawText: "y", text: "y", durationSeconds: 1, status: .cancelled))

        let page = try store.dictationPage(after: nil, filter: .needsAttention, pageSize: 10)
        #expect(page.items.count == 3)
        #expect(page.items.allSatisfy { $0.status != .inserted })
    }

    @Test("app filter matches only the given bundle id, and nil matches dictations with no app recorded")
    func appFilter() throws {
        let store = try Store()
        let now = Date()
        _ = try store.save(Dictation(createdAt: now, rawText: "a", text: "a", appBundleID: "com.a.app", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: now.addingTimeInterval(1), rawText: "b", text: "b", appBundleID: "com.b.app", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: now.addingTimeInterval(2), rawText: "c", text: "c", appBundleID: nil, durationSeconds: 1))

        let aOnly = try store.dictationPage(after: nil, filter: .app("com.a.app"), pageSize: 10)
        #expect(aOnly.items.map(\.rawText) == ["a"])

        let noAppOnly = try store.dictationPage(after: nil, filter: .app(nil), pageSize: 10)
        #expect(noAppOnly.items.map(\.rawText) == ["c"])
    }

    @Test("hasMore is false exactly when the page is the last one")
    func hasMoreReflectsRemainingRows() throws {
        let store = try Store()
        let now = Date()
        for index in 0..<5 {
            _ = try store.save(Dictation(createdAt: now.addingTimeInterval(Double(index)), rawText: "\(index)", text: "\(index)", durationSeconds: 1))
        }
        let exactPage = try store.dictationPage(after: nil, filter: .all, pageSize: 5)
        #expect(!exactPage.hasMore)

        let shortPage = try store.dictationPage(after: nil, filter: .all, pageSize: 4)
        #expect(shortPage.hasMore)
    }

    @Test("empty store returns an empty first page with no crash")
    func emptyStore() throws {
        let store = try Store()
        let page = try store.dictationPage(after: nil, filter: .all, pageSize: 100)
        #expect(page.items.isEmpty)
        #expect(!page.hasMore)
    }
}
