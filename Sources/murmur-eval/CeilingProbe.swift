import Foundation
import MurmurCore

/// `murmur-eval ceiling-probe`
///
/// Task 110. How long can a person wait after releasing the key when the cleanup model hangs? A model
/// that never answers is run through the real cleaner with the shipped ceilings, for a one-group Clean
/// dictation, a one-group Polished one and a twelve-group Clean one that has nothing prewarmed. No
/// speaker text and no real model: invented sentences, a scripted model that sleeps until cancelled.
///
/// Task 125 adds the no-progress limit: the same probe shows the wait ending about `noProgressCeiling` after
/// the release, a scripted slow answer inside the per-call ceiling still being used, and, with `--real`, a
/// twelve-group dictation on the real model, where every group the deadline allows must still be answered.
enum CeilingProbe {
    /// Answers with the draft, capitalised and full-stopped, after `delay`.
    final class SlowModel: LanguageModel {
        private let delay: Duration
        init(delay: Duration) { self.delay = delay }
        var identifier: String { "slow" }
        var availability: LanguageModelAvailability { .available }
        func supportsLanguage(_ languageCode: String) -> Bool { true }
        func prewarm(instructions: String) {}
        func prefixCache(instructions: String) async {}
        func respond(
            instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
        ) async throws -> String {
            try await Task.sleep(for: delay)
            let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
            let answer = draft.prefix(1).uppercased() + draft.dropFirst().replacingOccurrences(of: "friday", with: "Friday") + "."
            return String(decoding: try JSONEncoder().encode(["text": answer]), as: UTF8.self)
        }
    }

    final class HungModel: LanguageModel {
        var identifier: String { "hung" }
        var availability: LanguageModelAvailability { .available }
        func supportsLanguage(_ languageCode: String) -> Bool { true }
        func prewarm(instructions: String) {}
        func prefixCache(instructions: String) async {}
        func respond(
            instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
        ) async throws -> String {
            try await Task.sleep(for: .seconds(3_600))
            return ""
        }
    }

    private static func longText(_ sentences: Int) -> String {
        (1...sentences).map { "Part number \($0) says we need to finish the report before Friday and send it to the team." }
            .joined(separator: " ")
    }

    /// A twelve-group dictation, nothing prewarmed, on whatever model `args` selects (the real one by default).
    private static func realModelProbe(_ args: Arguments) async {
        var lines = ["### Ceiling probe · the real model, twelve groups, nothing prewarmed",
                     "| level | groups | wait after release | outcomes | model ms per group |", "|---|---|---|---|---|"]
        for (name, level) in [("Clean", CleanupLevel.clean), ("Polished", .polished)] {
            let cleaner = args.makeCleaner()
            let start = ContinuousClock.now
            let output = await cleaner.clean(longText(12), options: CleanupOptions(level: level))
            let seconds = ModelPace.ms(ContinuousClock.now - start) / 1000
            var counts: [String: Int] = [:]
            for group in output.groups { counts[group.outcome.rawValue, default: 0] += 1 }
            let summary = counts.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }.joined(separator: ", ")
            let times = output.groups.map { $0.modelMs.map(String.init) ?? "-" }.joined(separator: " ")
            lines.append("| \(name) | \(output.groups.count) | \(String(format: "%.1f", seconds)) s | \(summary) | \(times) |")
        }
        print(lines.joined(separator: "\n"))
    }

    static func run(_ args: Arguments) async throws {
        if args.flag("real") { await realModelProbe(args); return }
        func longText(_ sentences: Int) -> String { CeilingProbe.longText(sentences) }
        // `--no-progress-ms 20000` switches the no-progress limit off (the 20 s deadline still holds): the "before".
        let limit = args.int("no-progress-ms").map { Duration.milliseconds($0) } ?? SmartCleaner.noProgressCeiling
        let cases: [(String, CleanupLevel, String)] = [
            ("one group, Clean", .clean, "we need to finish the report before friday"),
            ("one group, Polished", .polished, "we need to finish the report before friday"),
            ("40 groups, Clean, none prewarmed", .clean, longText(40)),
            ("40 groups, Polished, none prewarmed", .polished, longText(40)),
        ]
        var lines = ["### Ceiling probe · a model that never answers (no-progress limit \(limit))", "| dictation | groups | wait after release | outcomes |", "|---|---|---|---|"]
        for (name, level, text) in cases {
            let cleaner = SmartCleaner(model: HungModel(), health: ModelHealth(), noProgressCeiling: limit)
            let start = ContinuousClock.now
            let output = await cleaner.clean(text, options: CleanupOptions(level: level))
            let seconds = ModelPace.ms(ContinuousClock.now - start) / 1000
            var counts: [String: Int] = [:]
            for group in output.groups { counts[group.outcome.rawValue + (group.retries > 0 ? "+retry" : ""), default: 0] += 1 }
            let summary = counts.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }.joined(separator: ", ")
            lines.append("| \(name) | \(output.groups.count) | \(String(format: "%.1f", seconds)) s | \(summary) |")
        }
        // A slow answer that is still inside the per-call ceiling is used, not cut by the no-progress limit.
        lines += ["", "| a model that answers slowly | wait after release | outcome |", "|---|---|---|"]
        for (name, level, delay) in [("one group, Clean, answer after 5 s (ceiling 6 s)", CleanupLevel.clean, 5.0),
                                     ("one group, Polished, answer after 7 s (ceiling 8 s)", .polished, 7.0)] {
            let cleaner = SmartCleaner(model: SlowModel(delay: .seconds(delay)), health: ModelHealth(), noProgressCeiling: limit)
            let start = ContinuousClock.now
            let output = await cleaner.clean("we need to finish the report before friday", options: CleanupOptions(level: level))
            let seconds = ModelPace.ms(ContinuousClock.now - start) / 1000
            lines.append("| \(name) | \(String(format: "%.1f", seconds)) s | \(output.groups[0].outcome.rawValue) |")
        }
        // The same hung model, dictation after dictation: two full allowances, then one short attempt each.
        lines += ["", "| the same hung model, one-group Clean dictations in a row | wait after release | short attempt | outcome |", "|---|---|---|---|"]
        let cleaner = SmartCleaner(model: HungModel(), health: ModelHealth(), noProgressCeiling: limit)
        for number in 1...5 {
            let start = ContinuousClock.now
            let output = await cleaner.clean("we need to finish the report before friday", options: CleanupOptions(level: .clean))
            let seconds = ModelPace.ms(ContinuousClock.now - start) / 1000
            let group = output.groups[0]
            lines.append("| dictation \(number) | \(String(format: "%.1f", seconds)) s | \(group.shortAttempt ? "yes" : "no") | \(group.outcome.rawValue)\(group.retries > 0 ? " after a retry" : "") |")
        }
        print(lines.joined(separator: "\n"))
    }
}
