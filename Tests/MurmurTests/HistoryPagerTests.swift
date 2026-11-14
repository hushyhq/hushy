import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The History pager's paging and live updates, over an in-memory store. Invented text only.
@Suite("History pager")
@MainActor
struct HistoryPagerTests {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeLibrary(count: Int) throws -> (Library, Store) {
        let store = try Store()
        for index in 1...count { try add(index, to: store) }
        return (Library(store: store), store)
    }

    @discardableResult
    private func add(_ index: Int, to store: Store) throws -> Dictation {
        try store.save(Dictation(
            createdAt: base.addingTimeInterval(Double(index) * 60), rawText: "note \(index)", text: "Note \(index).",
            durationSeconds: 1))
    }

    private func loadedIDs(_ pager: HistoryPager) -> [Int64] {
        pager.sections.flatMap(\.rows).flatMap(\.items).compactMap(\.id)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Scrolls to the bottom the way the list does: each page asks for the next when its last row appears.
    private func scrollToEnd(_ pager: HistoryPager) {
        while pager.hasMore, let last = loadedIDs(pager).last {
            let before = loadedIDs(pager).count
            pager.loadNextPageIfNeeded(currentID: last)
            if loadedIDs(pager).count == before { break }
        }
    }

    @Test("a dictation made after page two loaded keeps every row once, newest first, through the end of History")
    func liveInsertAfterSecondPage() async throws {
        let (library, store) = try makeLibrary(count: 7)
        let pager = HistoryPager(library: library, pageSize: 3)
        await waitUntil { pager.sections.isEmpty == false }
        pager.loadNextPageIfNeeded(currentID: try #require(loadedIDs(pager).last))
        #expect(loadedIDs(pager).count == 6)

        let inserted = try add(8, to: store)
        await waitUntil { loadedIDs(pager).first == inserted.id }
        #expect(loadedIDs(pager).first == inserted.id)

        scrollToEnd(pager)

        let ids = loadedIDs(pager)
        #expect(ids == (1...8).reversed().map(Int64.init), "every row once, newest first: \(ids)")
    }

    @Test("a row changing in the first page leaves the loaded rows below it as they were")
    func liveChangeKeepsLoadedPages() async throws {
        let (library, store) = try makeLibrary(count: 7)
        let pager = HistoryPager(library: library, pageSize: 3)
        await waitUntil { pager.sections.isEmpty == false }
        pager.loadNextPageIfNeeded(currentID: try #require(loadedIDs(pager).last))
        let before = loadedIDs(pager)

        try store.setEditState(.edited, forDictation: before[0])
        try await Task.sleep(for: .milliseconds(150))

        #expect(loadedIDs(pager) == before)
        scrollToEnd(pager)
        #expect(loadedIDs(pager) == (1...7).reversed().map(Int64.init))
    }

    @Test("a dictation deleted from the first page disappears and does not come back from older pages")
    func liveDeleteInFirstPage() async throws {
        let (library, store) = try makeLibrary(count: 7)
        let pager = HistoryPager(library: library, pageSize: 3)
        await waitUntil { pager.sections.isEmpty == false }
        pager.loadNextPageIfNeeded(currentID: try #require(loadedIDs(pager).last))

        try store.deleteDictation(id: 7)
        await waitUntil { !loadedIDs(pager).contains(7) }

        scrollToEnd(pager)
        #expect(loadedIDs(pager) == [6, 5, 4, 3, 2, 1])
    }
}
