import Foundation
import MurmurCore

/// `murmur-eval code [--golden Evals/code-golden.json] [--min-pass 0.NN] [--report path.json]`
///
/// Scores the code style (`CleanupOptions.isCodeContext`) through the exact production path —
/// `DictationPipeline.clean` — rather than calling `CasingCommands`/`CodeFileTags` directly, so
/// this cannot silently drift from what the app actually does. Runs with `strategy: .rules`
/// (deterministic, no on-device model call) and `voiceCommandsEnabled: true` so cases can also
/// cover "new line"/"scratch that" still working in a code context.
enum CodeRunner {
    struct VocabularyFixture: Decodable {
        let identifiers: [String]?
        let fileNames: [String]?
    }

    struct CodeCase: Decodable {
        let id: String
        let spoken: String
        let expected: String
        let group: String?
        let vocabulary: VocabularyFixture?
    }

    struct CodeResult {
        let item: CodeCase
        let actual: String
        var passed: Bool { actual == item.expected }
        /// Loose score: the first letter's case and one trailing full stop are ignored. Everything
        /// else (every symbol, space and inner letter) must still match.
        var loosePassed: Bool { looseKey(actual) == looseKey(item.expected) }
    }

    static func looseKey(_ text: String) -> String {
        var key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasSuffix(".") { key.removeLast() }
        guard let first = key.first else { return key }
        return first.lowercased() + key.dropFirst()
    }

    static func run(_ args: Arguments) async throws {
        let url = args.string("golden").map { URL(fileURLWithPath: $0) }
            ?? Paths.root.appendingPathComponent("code-golden.json")
        let cases = try JSONDecoder().decode([CodeCase].self, from: Data(contentsOf: url))
        guard !cases.isEmpty, Set(cases.map(\.id)).count == cases.count else {
            throw EvalError.missing("Code golden set must be nonempty with unique IDs")
        }

        let cleaner = SmartCleaner()
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)

        var results: [CodeResult] = []
        for item in cases {
            let vocabulary = item.vocabulary.map {
                ProjectVocabulary(identifiers: $0.identifiers ?? [], fileNames: $0.fileNames ?? [])
            }
            let cleanupOptions = CleanupOptions(
                level: .clean, voiceCommandsEnabled: true, isCodeContext: true, projectVocabulary: vocabulary)
            let settings = PipelineSettings(cleanupOptions: cleanupOptions)
            let result = await pipeline.clean(item.spoken, settings: settings, strategy: .rules)
            results.append(CodeResult(item: item, actual: result.text))
        }

        report(results, args: args)
    }

    private static func report(_ results: [CodeResult], args: Arguments) {
        let passed = results.filter(\.passed).count
        print("### Code style · \(results.count) cases")
        print("- Pass rate: **\(passed)/\(results.count) (\(pct(safeDiv(passed, results.count))))**")
        let loose = results.filter(\.loosePassed).count
        print("- Loose (first-letter case and one trailing full stop ignored): **\(loose)/\(results.count)**")
        let groups = Dictionary(grouping: results) { $0.item.group ?? "ungrouped" }
        if groups.count > 1 {
            print("\n| Group | Exact | Loose |\n|---|---|---|")
            for name in groups.keys.sorted() {
                let rows = groups[name] ?? []
                print("| \(name) | \(rows.filter(\.passed).count)/\(rows.count) | \(rows.filter(\.loosePassed).count)/\(rows.count) |")
            }
        }

        let failures = results.filter { !$0.passed }
        if !failures.isEmpty {
            print("\nFailures:")
            for failure in failures {
                print("  ✘ \(failure.item.id)")
                print("      spoken:   \(failure.item.spoken)")
                print("      expected: \(failure.item.expected)")
                print("      got:      \(failure.actual)")
            }
        }

        if let path = args.string("report") {
            writeReport(results, to: path)
        }

        if let minimum = args.string("min-pass") {
            guard let value = Double(minimum), (0...1).contains(value) else {
                fatalError("--min-pass must be a fraction in 0...1")
            }
            guard safeDiv(passed, results.count) >= value else {
                FileHandle.standardError.write(Data("Code style pass rate below required \(value)\n".utf8))
                exit(1)
            }
        }
    }

    private static func writeReport(_ results: [CodeResult], to path: String) {
        let cases: [[String: Any]] = results.map { result in
            [
                "id": result.item.id, "spoken": result.item.spoken, "expected": result.item.expected,
                "actual": result.actual, "passed": result.passed, "loosePassed": result.loosePassed,
                "group": result.item.group ?? "",
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1, "title": "Code style", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "total": results.count, "passed": results.filter(\.passed).count,
            "loosePassed": results.filter(\.loosePassed).count, "cases": cases,
        ]
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private static func safeDiv(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
    private static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}
