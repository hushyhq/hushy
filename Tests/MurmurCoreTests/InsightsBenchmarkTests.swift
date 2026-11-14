import Foundation
import Testing
@testable import MurmurCore

/// Not a correctness test (see `InsightsSQLEquivalenceTests`) — measures old (full fetch +
/// in-memory `Insights.compute`) vs new (`Store.computeInsights`, SQL aggregates) at 5k/20k/50k
/// rows and prints the numbers for the performance-plan report. Seeds a disposable SQLite file
/// under a scratch temp directory, never `AppPaths`/`HUSHY_HOME`/the user's real database, and
/// deletes it afterward. Disabled by default (`.disabled`), matching
/// `StorePagingBenchmarkTests`; run explicitly for perf numbers, or delete `.disabled(...)`
/// locally.
@Suite("Insights compute benchmark", .disabled("run explicitly for perf numbers; not part of CI"))
struct InsightsBenchmarkTests {
    func seed(_ store: Store, rowCount: Int) throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let apps = ["com.a.app", "com.b.app", "com.c.app", nil] as [String?]
        let statuses: [Dictation.Status] = [.inserted, .inserted, .inserted, .failed, .notInserted]

        try store.writer.write { db in
            for index in 0..<rowCount {
                var d = Dictation(
                    createdAt: base.addingTimeInterval(Double(index) * 60),
                    rawText: "bench row \(index) with a bit more text to be realistic",
                    text: "Bench row \(index) with a bit more text to be realistic.",
                    appBundleID: apps[index % apps.count],
                    appName: "App \(index % apps.count)",
                    durationSeconds: 3.2,
                    status: statuses[index % statuses.count])
                try d.save(db)
            }
        }
    }

    func measureMs(_ body: () throws -> Void) rethrows -> Int {
        let start = Date()
        try body()
        return Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    @Test("5k / 20k / 50k rows: old full-fetch compute vs new SQL-aggregate compute", arguments: [5_000, 20_000, 50_000])
    func benchmark(rowCount: Int) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hushy-insights-bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = try Store(url: scratch.appendingPathComponent("bench.sqlite"))
        try seed(store, rowCount: rowCount)

        var oldMs = 0
        oldMs = try measureMs {
            let items = try store.allDictations()
            _ = Insights.compute(from: items)
        }

        var newMs = 0
        newMs = try measureMs {
            _ = try store.computeInsights()
        }

        print("[insights-bench] \(rowCount) rows: old (fetch+compute) = \(oldMs) ms, new (SQL aggregates) = \(newMs) ms")
        // Not a strict assertion (machine noise at small row counts), but the whole point of
        // the change is that the new path must not be slower at scale.
        #expect(newMs <= max(oldMs, 5))
    }
}
