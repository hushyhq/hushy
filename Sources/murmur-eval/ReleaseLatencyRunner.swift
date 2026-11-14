import Foundation
import MurmurCore

/// `murmur-eval release-latency [--level clean|polished|both] [--wps 2.5] [--lag 2] [--repeats 1]`
///
/// Real-time simulation of a long streaming dictation, to measure what the user waits for after
/// key release. Words "arrive" at `--wps` words/s (2.5 ≈ 150 wpm); every second the confirmed
/// transcript (everything spoken more than `--lag` s ago) is split into groups exactly like
/// `StreamingDictationSession.prewarmClosedGroups` does and every closed group is prewarmed with
/// the real on-device model, awaited in the same loop (as the session awaits it). At release the
/// final transcript is cleaned with `SmartCleaner.clean` and timed; per-group sources show which
/// groups were cache hits, awaited in-flight prewarms, late, or fresh.
///
/// Two final-transcript variants per dictation: `same` (the final text equals the streamed
/// text) and `repunctuated` (same words, sentence punctuation added every 12 words — what the
/// app's whole-utterance final pass does to boundaries). ASR time is not included: this is
/// cleanup time after release only. Texts are long dev inputs from `Evals/reformat-golden.json`
/// concatenated to ~150 words (60 s) and ~250 words (100 s).
enum ReleaseLatencyRunner {
    static func run(_ args: Arguments) async throws {
        let golden = try JSONDecoder().decode(
            [ReformatChecks.Case].self, from: Data(contentsOf: Paths.root.appendingPathComponent("reformat-golden.json")))
        let byID = Dictionary(uniqueKeysWithValues: golden.map { ($0.id, $0.input) })
        let dictations: [(label: String, ids: [String])] = [
            ("60 s", ["fill-04", "mix-07"]),
            ("100 s", ["mix-07", "fill-07", "mix-01", "abort-04"]),
        ]
        let levels = try ReformatRunner.parseLevels(args.string("level") ?? "both")
        let wordsPerSecond = Double(args.string("wps") ?? "2.5") ?? 2.5
        let lag = Double(args.string("lag") ?? "2") ?? 2
        let repeats = args.int("repeats") ?? 1
        var lines = ["### Release latency (streaming prewarm simulation, real on-device model) · \(wordsPerSecond) words/s, \(lag) s confirmation lag",
                     "", "| Dictation | Words | Level | Final text | After release | Groups (hit/awaited/late/fresh/rules-only) | Model used (last group) |",
                     "|---|---:|---|---|---:|---|---|"]
        for dictation in dictations {
            let text = dictation.ids.compactMap { byID[$0] }.joined(separator: " ")
            let words = text.split(separator: " ").map(String.init)
            for level in levels {
                for variant in ["same", "repunctuated"] {
                    for _ in 0..<repeats {
                        let final = variant == "same" ? text : repunctuate(words)
                        let (ms, output) = await simulate(words: words, final: final, level: level, wps: wordsPerSecond, lag: lag)
                        let counts = [SmartCleaner.GroupSource.prewarmHit, .prewarmAwaited, .prewarmLate, .fresh, .freshRulesOnly]
                            .map { source in output.groupSources.filter { $0 == source }.count }
                        lines.append("| \(dictation.label) | \(words.count) | \(level.rawValue) | \(variant) | \(Int(ms)) ms | \(counts.map(String.init).joined(separator: "/")) | \(output.usedModel)\(output.rejection.map { " (\($0))" } ?? "") |")
                        print(lines.last!)
                    }
                }
            }
        }
        Runners.emit(lines.joined(separator: "\n"))
    }

    /// Same words, a period after every 12th word, capitalized after it.
    static func repunctuate(_ words: [String]) -> String {
        var out: [String] = []
        var capitalizeNext = true
        for (index, word) in words.enumerated() {
            var token = capitalizeNext ? word.prefix(1).uppercased() + word.dropFirst() : word
            capitalizeNext = false
            if (index + 1) % 12 == 0 || index == words.count - 1 {
                token += "."
                capitalizeNext = true
            }
            out.append(token)
        }
        return out.joined(separator: " ")
    }

    private static func simulate(
        words: [String], final: String, level: CleanupLevel, wps: Double, lag: Double
    ) async -> (Double, SmartCleaner.Output) {
        let cleaner = SmartCleaner()
        cleaner.prewarm()
        let options = CleanupOptions(level: level)
        let speechSeconds = Double(words.count) / wps
        let start = ContinuousClock.now
        let prewarmer = Task {
            var seen = Set<String>()
            while !Task.isCancelled {
                let elapsed = ModelPace.ms(ContinuousClock.now - start) / 1000
                if elapsed >= speechSeconds { break }
                let confirmedCount = max(0, min(words.count, Int((elapsed - lag) * wps)))
                let confirmed = words.prefix(confirmedCount).joined(separator: " ")
                let groups = TextSegmentation.groups(confirmed)
                if groups.count > 1 {
                    for group in groups where !group.isTail && !seen.contains(group.text) {
                        seen.insert(group.text)
                        await cleaner.prewarmGroup(group.text, options: options, continuesSentence: group.continuesSentence,
                        previousRaw: group.index > 0 ? groups[group.index - 1].text : nil)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        try? await Task.sleep(until: start + .seconds(speechSeconds), clock: .continuous)
        let released = ContinuousClock.now
        let output = await cleaner.clean(final, options: options)
        let ms = ModelPace.ms(ContinuousClock.now - released)
        prewarmer.cancel()
        await cleaner.clearPrewarmedGroups()
        return (ms, output)
    }
}
