import Foundation
import MurmurCore

/// `murmur-eval context [--golden Evals/context-golden.json] [--min-pass 0.NN] [--report path]`
///
/// Scores "Context awareness" (`ContextExtractor` + `ContextSpellingFixer`, MurmurCore) against
/// a golden set of `{contextText, spoken}` → `expected` triples: `contextText` stands in for the
/// text `ContextReader` would have read from the focused app (no Accessibility API involved
/// here — this eval never touches a real app or reads real context, it only exercises the pure
/// extraction/fix logic against fixed strings), and `spoken` stands in for the raw ASR
/// transcript. This is text-only, like `StyleRunner`/`cleanup`'s golden path — no audio, no
/// network — so it always runs, including in `--quick`.
///
/// About 40 cases, roughly split between positive fixes (a name/identifier from context corrects
/// a near-miss ASR word) and negatives (no context, unrelated context, an already-correct word,
/// or a word that's numerically close but phonetically different) — negatives matter as much as
/// positives here: a false-positive rewrite is worse than a missed fix, since it silently changes
/// what the user said.
enum ContextRunner {
    struct ContextCase: Decodable {
        let id: String
        let contextText: String
        let spoken: String
        let expected: String
        let note: String?
        let aspirational: Bool?

        var isAspirational: Bool { aspirational ?? false }
    }

    struct ContextResult {
        let item: ContextCase
        let actual: String
        var passed: Bool { actual == item.expected }
    }

    static func run(_ args: Arguments) async throws {
        let url = args.string("golden").map { URL(fileURLWithPath: $0) }
            ?? Paths.root.appendingPathComponent("context-golden.json")
        let cases = try JSONDecoder().decode([ContextCase].self, from: Data(contentsOf: url))
        guard !cases.isEmpty, Set(cases.map(\.id)).count == cases.count else {
            throw EvalError.missing("Context golden set must be nonempty with unique IDs")
        }

        var results: [ContextResult] = []
        for item in cases {
            let terms = ContextExtractor.extract(from: item.contextText)
            let actual = ContextSpellingFixer.fix(item.spoken, terms: terms)
            results.append(ContextResult(item: item, actual: actual))
        }

        report(results, args: args)
    }

    private static func report(_ results: [ContextResult], args: Arguments) {
        let nonAspirational = results.filter { !$0.item.isAspirational }
        let aspirational = results.filter(\.item.isAspirational)
        let nonAspirationalPassed = nonAspirational.filter(\.passed).count
        let aspirationalPassed = aspirational.filter(\.passed).count

        var summaryLines = ["### Context awareness (spelling-fix pass) · \(results.count) cases (\(nonAspirational.count) scored, \(aspirational.count) aspirational)"]
        summaryLines.append("- Non-aspirational pass rate: **\(nonAspirationalPassed)/\(nonAspirational.count) (\(pct(safeDiv(nonAspirationalPassed, nonAspirational.count))))**")
        if !aspirational.isEmpty {
            summaryLines.append("- Aspirational pass rate (informational, not gated): \(aspirationalPassed)/\(aspirational.count) (\(pct(safeDiv(aspirationalPassed, aspirational.count))))")
        }
        Runners.emit(summaryLines.joined(separator: "\n"))

        let failures = nonAspirational.filter { !$0.passed }
        if !failures.isEmpty {
            print("\nFailures:")
            for failure in failures {
                print("  ✘ \(failure.item.id)")
                print("      context:  \(failure.item.contextText)")
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
            guard safeDiv(nonAspirationalPassed, nonAspirational.count) >= value else {
                FileHandle.standardError.write(Data("Non-aspirational pass rate below required \(value)\n".utf8))
                exit(1)
            }
        }
    }

    private static func writeReport(_ results: [ContextResult], to path: String) {
        let cases: [[String: Any]] = results.map { result in
            [
                "id": result.item.id, "contextText": result.item.contextText, "spoken": result.item.spoken,
                "expected": result.item.expected, "actual": result.actual,
                "aspirational": result.item.isAspirational, "passed": result.passed,
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1, "title": "Context awareness", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "total": results.count, "cases": cases,
        ]
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private static func safeDiv(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
    private static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}
