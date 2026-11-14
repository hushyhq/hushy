import Foundation
import Testing
@testable import MurmurCore

/// Old (one regex per heard phrase) against new (one automaton pass) on a 200-word dictation, for 10, 200 and 2,000
/// Dictionary entries. Off by default; run with `HUSHY_BENCH_DICTIONARY=1 swift test --filter DictionaryMatcherBenchmark`.
/// Entries are invented names with two heard-as phrases each, one of two words; about 5% of the dictation's words are heard
/// phrases.
@Suite("Dictionary matcher benchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HUSHY_BENCH_DICTIONARY"] != nil))
struct DictionaryMatcherBenchmarkTests {
    private static let filler = ["we", "need", "to", "review", "the", "plan", "before", "friday", "and", "send", "notes", "about", "budget",
                                 "roadmap", "hiring", "launch", "after", "lunch", "with", "team", "so", "everyone", "knows", "what", "ships"]

    private static func entries(_ count: Int, tag: String) -> [DictionaryEntry] {
        (0..<count).map { index in
            DictionaryEntry(term: "Zorv\(tag)\(index)", soundsLike: ["zorf\(tag)\(index)", "zor \(tag)\(index)x"])
        }
    }

    private static func dictation(_ entries: [DictionaryEntry]) -> String {
        var state: UInt64 = 7
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        var words: [String] = []
        while words.count < 200 {
            if words.count % 20 == 10 {
                let phrases = entries[next() % entries.count].soundsLike
                words.append(phrases[next() % phrases.count])
            } else {
                words.append(filler[next() % filler.count])
            }
        }
        return words.joined(separator: " ") + "."
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure(body)
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func median(_ runs: Int, _ body: () -> Void) -> Double {
        let times = (0..<runs).map { _ in milliseconds(body) }.sorted()
        return times[times.count / 2]
    }

    @Test("old against new at 10, 200 and 2,000 entries")
    func benchmark() {
        var lines = ["entries | regex cold ms | regex warm ms | matcher build ms | matcher warm ms | same text"]
        for count in [10, 200, 2_000] {
            let entries = Self.entries(count, tag: "n\(count)q")
            let text = Self.dictation(entries)
            var oldResult = ("", 0)
            let regexCold = Self.milliseconds { oldResult = Personalizer.applyDictionarySequential(text, entries: entries, keep: .empty) }
            let regexWarm = Self.median(5) { oldResult = Personalizer.applyDictionarySequential(text, entries: entries, keep: .empty) }
            var matcher: DictionaryMatcher?
            let build = Self.median(5) { matcher = DictionaryMatcher(entries: entries) }
            var newResult: DictionaryMatcher.Applied?
            let warm = Self.median(200) { newResult = matcher?.apply(text, keep: .empty) }
            let same = newResult?.text == oldResult.0 && newResult?.fixes == oldResult.1
            #expect(same)
            #expect(oldResult.1 > 0, "the dictation should contain heard phrases")
            lines.append(String(format: "%7d | %13.2f | %13.2f | %16.2f | %15.3f | %@", count, regexCold, regexWarm, build, warm, same ? "yes" : "NO"))
            lines.append("        fixes \(oldResult.1), path \(newResult.map { "\($0.path)" } ?? "regex")")
        }
        print("DICTIONARY MATCHER BENCHMARK (200-word dictation)\n" + lines.joined(separator: "\n"))
    }
}
