import Foundation
import MurmurCore

/// The `--backend jev` path of `murmur-eval judge`, plus the case preparation and sampling shared
/// with the CLI backends.
extension JudgeRunner {
    typealias Prepared = (item: Runners.GoldenCase, output: SmartCleaner.Output, exactMatchPassed: Bool)

    /// Cleans every case locally (cheap) before any judge call, scores exact match, then applies
    /// `--sample`. `--level` reaches the cleaner the same way `cleanup` does.
    static func prepare(_ args: Arguments) async throws -> [Prepared] {
        let cases = try loadCases(args)
        let cleaner = args.makeCleaner()
        cleaner.prewarm()
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: args.cleanupLevel))
        var prepared: [Prepared] = []
        for item in cases {
            let result = await pipeline.clean(item.spoken, settings: settings, strategy: args.strategy)
            let output = SmartCleaner.Output(
                text: result.text, pressEnter: result.pressEnter, usedModel: result.usedModel, rejection: result.rejection)
            let exact = result.pressEnter == (item.expectedPressEnter ?? false) && item.accepted.contains {
                item.exactText == true ? $0 == output.text : EvalMetrics.layoutMatches($0, output.text)
            }
            prepared.append((item, output, exact))
        }
        let spec = try JudgeSampling.parse(args.string("sample") ?? "all")
        let sampled = JudgeSampling.select(prepared, spec: spec, passed: \.exactMatchPassed, id: \.item.id)
        if sampled.count < prepared.count {
            print("Sampling \(spec.description): judging \(sampled.count) of \(prepared.count) cases")
        }
        return sampled
    }

    static func runJev(_ args: Arguments) async throws {
        guard let apiKey = loadAPIKey() else {
            print("### Judge (Jev) · skipped")
            print("No TypeSafe API key found (set TYPESAFE_API_KEY or create ~/.config/hushy/typesafe_api_key).")
            return
        }
        let prepared = try await prepare(args)
        let judge = JevJudge(apiKey: apiKey)
        let level = args.cleanupLevel.rawValue
        let judgments = try await JudgeClient.mapConcurrently(prepared) { entry in
            try await judge.judge(
                level: level, spoken: entry.item.spoken, output: entry.output.text, reference: entry.item.expected
            ).value
        }
        try reportJev(prepared, judgments: judgments, args: args)
    }

    private static func reportJev(_ prepared: [Prepared], judgments: [JevJudgment], args: Arguments) throws {
        let pairs = Array(zip(prepared, judgments))
        let count = Double(max(pairs.count, 1))
        func rate(_ key: String) -> String {
            Runners.percent(Double(judgments.filter { ($0.faults[key] ?? 0) >= 0.5 }.count) / count)
        }
        var bothPass = 0, onlyChecks = 0, onlyJev = 0, bothFail = 0
        for (entry, judgment) in pairs {
            switch (entry.exactMatchPassed, judgment.passed()) {
            case (true, true): bothPass += 1
            case (true, false): onlyChecks += 1
            case (false, true): onlyJev += 1
            case (false, false): bothFail += 1
            }
        }
        let meanMeaning = judgments.reduce(0) { $0 + $1.meaning } / count
        let summary = """
            ### Judge (Jev \(JevRubric.version), \(JevRubric.model)) · \(args.strategy.rawValue) · \(args.cleanupLevel.rawValue) · \(pairs.count) cases
            - Jev pass (no fault ≥ 0.5): \(Runners.percent(Double(bothPass + onlyJev) / count)) · mean meaning \(String(format: "%.2f", meanMeaning)) / 4
            - Faults ≥ 0.5: meaning broken \(rate("meaning_broken")) · dropped \(rate("dropped_content")) · changed fact \(rate("changed_fact")) · disfluency left \(rate("disfluency_left")) · correction left \(rate("correction_left")) · over-edited \(rate("over_edited")) · layout \(rate("layout_wrong"))
            - Jev bands (pBad <0.3 pass / 0.3–0.7 unsure / ≥0.7 fail): \(judgments.filter { $0.band == .pass }.count) / \(judgments.filter { $0.band == .unsure }.count) / \(judgments.filter { $0.band == .fail }.count)
            - Exact match × Jev: both pass \(bothPass) · checks only \(onlyChecks) · Jev only \(onlyJev) · both fail \(bothFail)
            """
        let disagreements = pairs.filter { $0.0.exactMatchPassed != $0.1.passed() }.map { entry, judgment -> String in
            """
              \(entry.exactMatchPassed ? "checks✔ jev✘" : "checks✘ jev✔") [\(judgment.band.rawValue)] \(entry.item.id) pBad=\(String(format: "%.2f", judgment.pBad)) faults=\(judgment.firedFaults())
                spoken:   \(entry.item.spoken.replacingOccurrences(of: "\n", with: " ⏎ "))
                got:      \(entry.output.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                expected: \(entry.item.expected.replacingOccurrences(of: "\n", with: " ⏎ "))
            """
        }
        Runners.emit(summary, details: disagreements.isEmpty ? [] : ["Disagreements (review by hand):"] + disagreements)

        guard let path = args.string("report") else { return }
        let entries: [[String: Any]] = pairs.map { entry, judgment in
            [
                "id": entry.item.id, "tag": entry.item.tag, "spoken": entry.item.spoken, "expected": entry.item.expected,
                "output": entry.output.text, "exactMatchPassed": entry.exactMatchPassed, "jevPassed": judgment.passed(), "jevBand": judgment.band.rawValue,
                "pBad": judgment.pBad, "meaning": judgment.meaning, "faults": judgment.faults,
                "readsClean": judgment.readsClean, "listLayout": judgment.listLayout,
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 2, "kind": "judge", "title": "Judge (Jev \(JevRubric.version))", "model": JevRubric.model,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "arguments": Array(CommandLine.arguments.dropFirst()), "strategy": args.strategy.rawValue,
            "level": args.cleanupLevel.rawValue, "total": pairs.count,
            "gitRevision": (try? command(["rev-parse", "HEAD"])) ?? "unknown", "cases": entries,
        ]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

/// `--sample all|fails+N`: which cases a judge sees. `fails+N` = every check failure plus a
/// deterministic N% of check passes (hash of the case id, so reruns pick the same cases and hit
/// the verdict cache).
enum JudgeSampling {
    enum Spec: Equatable, CustomStringConvertible {
        case all
        case failsPlus(percent: Int)

        var description: String {
            switch self {
            case .all: "all"
            case .failsPlus(let percent): "fails+\(percent)"
            }
        }
    }

    static func parse(_ raw: String) throws -> Spec {
        if raw == "all" { return .all }
        if raw.hasPrefix("fails+"), let percent = Int(raw.dropFirst(6)), (0...100).contains(percent) {
            return .failsPlus(percent: percent)
        }
        throw EvalError.missing("--sample must be 'all' or 'fails+N' (N = 0…100), got '\(raw)'")
    }

    static func select<T>(_ items: [T], spec: Spec, passed: (T) -> Bool, id: (T) -> String) -> [T] {
        guard case .failsPlus(let percent) = spec else { return items }
        return items.filter { !passed($0) || CalibrationSetBuilder.stableHash("sample|" + id($0)) % 100 < percent }
    }
}
