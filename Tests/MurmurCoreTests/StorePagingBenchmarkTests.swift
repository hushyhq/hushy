import Foundation
import Testing
@testable import MurmurCore

/// Not a correctness test (see `StorePagingTests`) — measures `Store.dictationPage` at scale
/// and prints the numbers to stdout for the History paging report. Seeds a disposable SQLite
/// file under a scratch temp directory, never `AppPaths`/`HUSHY_HOME`/the user's real
/// database, and deletes it afterward. Disabled by default (`.disabled`) since it seeds
/// 20,000 rows and is meant to be read, not asserted on; run explicitly with
/// `swift test --filter StorePagingBenchmarkTests -- -Xswiftc -enable-testing` style filter,
/// or just delete `.disabled(...)` locally.
@Suite("Store dictation paging benchmark", .disabled("run explicitly for perf numbers; not part of CI"))
struct StorePagingBenchmarkTests {
    @Test("20k dictations: first page and page-fetch timings")
    func benchmarkAt20k() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hushy-history-bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = try Store(url: scratch.appendingPathComponent("bench.sqlite"))

        let rowCount = 20_000
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let apps = ["com.a.app", "com.b.app", "com.c.app", nil] as [String?]
        let statuses: [Dictation.Status] = [.inserted, .inserted, .inserted, .failed, .notInserted]

        try store.writer.write { db in
            for index in 0..<rowCount {
                var d = Dictation(
                    createdAt: base.addingTimeInterval(Double(index)),
                    rawText: "bench row \(index) with a bit more text to be realistic",
                    text: "Bench row \(index) with a bit more text to be realistic.",
                    appBundleID: apps[index % apps.count],
                    appName: "App \(index % apps.count)",
                    durationSeconds: 3.2,
                    status: statuses[index % statuses.count])
                try d.save(db)
            }
        }

        func measure(_ label: String, _ body: () throws -> Void) rethrows {
            let start = Date()
            try body()
            print("[history-bench] \(label): \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }

        try measure("first page (pageSize 100, .all)") {
            _ = try store.dictationPage(after: nil, filter: .all, pageSize: 100)
        }

        var cursor: Store.DictationCursor?
        try measure("20 sequential page fetches (rows 0-2000)") {
            for _ in 0..<20 {
                let page = try store.dictationPage(after: cursor, filter: .all, pageSize: 100)
                guard let last = page.items.last, let id = last.id else { break }
                cursor = Store.DictationCursor(createdAt: last.createdAt, id: id)
            }
        }

        // Walk to a cursor ~15,000 rows in (not timed: this isolates the cost of one page
        // fetch deep in the table from the cost of the 150 round trips it took to get there).
        var deepCursor: Store.DictationCursor?
        for _ in 0..<150 {
            let page = try store.dictationPage(after: deepCursor, filter: .all, pageSize: 100)
            guard let last = page.items.last, let id = last.id else { break }
            deepCursor = Store.DictationCursor(createdAt: last.createdAt, id: id)
        }
        try measure("single page fetch at ~row 15000 (keyset, not offset)") {
            _ = try store.dictationPage(after: deepCursor, filter: .all, pageSize: 100)
        }

        try measure("first page with .needsAttention filter") {
            _ = try store.dictationPage(after: nil, filter: .needsAttention, pageSize: 100)
        }

        try measure("first page with .app filter") {
            _ = try store.dictationPage(after: nil, filter: .app("com.a.app"), pageSize: 100)
        }

        try measure("old-style full load: recentDictations(limit: 500)") {
            _ = try store.recentDictations(limit: 500)
        }
    }
}
