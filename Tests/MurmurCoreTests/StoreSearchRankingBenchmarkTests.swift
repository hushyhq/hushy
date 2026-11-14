import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// The audit's search micro-benchmark (docs/research/algorithms-audit-2026-10-26.md, B5), repeatable:
/// a long history of invented dictations in which one word is mentioned once in about 5% of rows and
/// strongly (four times) in 10 older rows. A palette-sized search (limit 8) should hold those 10 strong
/// rows, not the newest rows that mention the word once.
///
/// Off by default (it builds a big store). Run: `HUSHY_SEARCH_BENCH=1 [HUSHY_SEARCH_BENCH_ROWS=100000]
/// swift test --filter StoreSearchRankingBenchmarkTests`. The store is a temp file, never the user's.
@Suite(
    "Store search ranking benchmark",
    .enabled(if: ProcessInfo.processInfo.environment["HUSHY_SEARCH_BENCH"] != nil))
struct StoreSearchRankingBenchmarkTests {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Pronounceable invented words, so nothing real is in the data.
    private static func vocabulary(count: Int, _ rng: inout SeededGenerator) -> [String] {
        let syllables = ["ba", "ke", "mi", "so", "tu", "la", "ne", "ri", "po", "du", "fa", "go", "hi", "ju", "wa", "ze"]
        return (0..<count).map { index in
            var word = ""
            var rest = index
            repeat { word += syllables[rest % syllables.count]; rest /= syllables.count } while rest > 0
            return word + syllables[Int.random(in: 0..<syllables.count, using: &rng)]
        }
    }

    @Test("limit-8 search holds the strongly relevant rows, and how long it takes")
    func relevantRowsInTopEight() throws {
        let rows = Int(ProcessInfo.processInfo.environment["HUSHY_SEARCH_BENCH_ROWS"] ?? "") ?? 100_000
        var rng = SeededGenerator(state: 42)
        let words = Self.vocabulary(count: 5_000, &rng)
        let target = "zorbulate"
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 10 strong rows spread over the older half of the history.
        let strongRows = Set((0..<10).map { rows / 20 + $0 * (rows / 25) })

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-search-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(url: dir.appendingPathComponent("bench.sqlite"))
        var strongIDs = Set<Int64>()
        try store.writer.write { db in
            for index in 0..<rows {
                let length = Int.random(in: 35...65, using: &rng)
                // Zipf-like: word k with weight 1/k, by squaring a uniform draw.
                var body = (0..<length).map { _ -> String in
                    let u = Double.random(in: 0..<1, using: &rng)
                    return words[min(words.count - 1, Int(u * u * Double(words.count)))]
                }
                if strongRows.contains(index) {
                    for slot in [3, 12, 20, 30] { body[slot] = target }
                } else if Int.random(in: 0..<20, using: &rng) == 0 {
                    body[Int.random(in: 0..<length, using: &rng)] = target
                }
                let text = body.joined(separator: " ")
                var dictation = Dictation(
                    createdAt: base.addingTimeInterval(Double(index) * 30), rawText: text, text: text, durationSeconds: 3)
                try dictation.save(db)
                if strongRows.contains(index), let id = dictation.id { strongIDs.insert(id) }
            }
        }

        var top: [Dictation] = []
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = DispatchTime.now()
            top = try store.searchDictations(target, limit: 8)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        samples.sort()
        let relevant = top.filter { strongIDs.contains($0.id ?? -1) }.count
        print("[search-bench] rows=\(rows) strong=\(strongIDs.count) relevant in top 8: \(relevant) of \(min(8, strongIDs.count)); "
              + "median \(String(format: "%.1f", samples[samples.count / 2])) ms, worst \(String(format: "%.1f", samples.last ?? 0)) ms")
        #expect(relevant == min(8, strongIDs.count))
    }
}
