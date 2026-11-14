import Foundation
import MurmurCore

/// `murmur-eval style [--contract v1|v2] [--golden path.json] [--min-pass 0.NN] [--report path.json]`
///
/// Scores `StyleFormatter` (formatting-only rules) through the exact production path —
/// `DictationPipeline.clean` — rather than calling `StyleFormatter.apply` directly, so this
/// cannot silently drift from what the app actually does. Styles must never change words:
/// word-preservation (normalized words identical to the input) is scored as a hard, separate
/// pass/fail signal from exact-match/format checks, and is required to be 100% for every
/// non-aspirational case.
///
/// Cleanup runs with `level: .clean, voiceCommandsEnabled: false, strategy: .rules` rather than
/// `.verbatim`: `DictationPipeline.clean` skips styling entirely when the level is `.verbatim`
/// (see `processTranscript`), and voice commands ("new line", "scratch that") must not fire on
/// style-golden inputs that happen to contain those words as ordinary text. `.clean` + `.rules`
/// still cannot invoke the on-device model (`strategy: .rules` never asks it), so on already-
/// cleaned input the rule pass is expected to be a word-preserving no-op ahead of styling.
enum StyleRunner {
    struct StyleCase: Decodable {
        let id: String
        let input: String
        let context: String
        let style: String
        let expected: String
        let aspirational: Bool?
        let notes: String?

        var isAspirational: Bool { aspirational ?? false }
    }

    struct StyleResult {
        let item: StyleCase
        let actual: String
        let wordsPreserved: Bool
        let exactMatch: Bool
        let formatOK: Bool

        /// A case only counts as passing when it preserves every input word (non-negotiable)
        /// and produces the expected formatting exactly.
        var passed: Bool { wordsPreserved && exactMatch }
    }

    static func run(_ args: Arguments) async throws {
        let requestedContract = args.string("contract")
        let contractVersion: String
        let defaultGolden: String
        switch requestedContract {
        case "v1": contractVersion = "v1"; defaultGolden = "style-golden.json"
        case "v2", nil: contractVersion = "v2"; defaultGolden = "style-golden-v2.json"
        default: throw EvalError.missing("Style contract must be v1 or v2")
        }
        let customGolden = args.string("golden")
        let url = customGolden.map { URL(fileURLWithPath: $0) }
            ?? Paths.root.appendingPathComponent(defaultGolden)
        let reportedContract = requestedContract == nil && customGolden != nil ? "custom" : contractVersion
        let cases = try JSONDecoder().decode([StyleCase].self, from: Data(contentsOf: url))
        guard !cases.isEmpty, Set(cases.map(\.id)).count == cases.count else {
            throw EvalError.missing("Style golden set must be nonempty with unique IDs")
        }

        let cleaner = SmartCleaner()
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        // .clean (not .verbatim) so DictationPipeline.clean actually applies styling; .rules
        // strategy keeps it deterministic (no on-device model call). Voice commands are disabled
        // so literal words like "new line" in golden text are never treated as commands.
        let cleanupOptions = CleanupOptions(level: .clean, voiceCommandsEnabled: false)

        var results: [StyleResult] = []
        for item in cases {
            guard let context = StyleContext(rawValue: item.context), let style = WritingStyle(rawValue: item.style) else {
                throw EvalError.missing("Unknown context/style in case \(item.id): \(item.context)/\(item.style)")
            }
            let settings = PipelineSettings(cleanupOptions: cleanupOptions, style: (context, style))
            let result = await pipeline.clean(item.input, settings: settings, strategy: .rules)
            let wordsPreserved = EvalMetrics.normalizedWords(item.input) == EvalMetrics.normalizedWords(result.text)
            let exact = result.text == item.expected
            let formatOK = EvalMetrics.formatMatches(item.expected, result.text)
            results.append(StyleResult(item: item, actual: result.text, wordsPreserved: wordsPreserved, exactMatch: exact, formatOK: formatOK))
        }

        report(results, args: args, contractVersion: reportedContract, goldenFile: url.lastPathComponent)
        try await checkDictationGoldenThroughStyles(args: args)
    }

    /// Part B step 6: runs the existing dictation golden set (Evals/dictation-golden.json)
    /// through cleanup once (as `cleanup` does) to get the pre-style cleaned text, then applies
    /// every style valid for each of the 4 contexts on top, and reports word-preservation
    /// (normalized words identical to the *cleaned* text, since cleanup — not styling — is what's
    /// allowed to touch words) which must be 100%: styling must never introduce a word change,
    /// regardless of what cleanup-level rewriting already happened upstream.
    private static func checkDictationGoldenThroughStyles(args: Arguments) async throws {
        let goldenURL = args.string("dictation-golden").map { URL(fileURLWithPath: $0) } ?? Paths.golden
        guard FileManager.default.fileExists(atPath: goldenURL.path) else { return }
        let cases = try JSONDecoder().decode([Runners.GoldenCase].self, from: Data(contentsOf: goldenURL))
        let cleaner = SmartCleaner()
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)

        var totalChecked = 0
        var preserved = 0
        var failures: [String] = []
        for item in cases {
            // First, cleanup only (no style), to get the word set styling must not disturb.
            let cleanedOnly = await pipeline.clean(item.spoken, settings: PipelineSettings(), strategy: .rules)
            guard !cleanedOnly.text.isEmpty else { continue }
            let cleanedWords = EvalMetrics.normalizedWords(cleanedOnly.text)
            for context in StyleContext.allCases {
                for style in context.styles {
                    let settings = PipelineSettings(style: (context, style))
                    let result = await pipeline.clean(item.spoken, settings: settings, strategy: .rules)
                    totalChecked += 1
                    let ok = EvalMetrics.normalizedWords(result.text) == cleanedWords
                    if ok {
                        preserved += 1
                    } else {
                        failures.append("\(item.id) [\(context.rawValue)/\(style.rawValue)]: cleaned=\"\(cleanedOnly.text)\" styled=\"\(result.text)\"")
                    }
                }
            }
        }
        print("\n### Dictation golden set through every style · \(cases.count) golden cases × context/style combinations")
        print("- Word preservation vs cleaned (pre-style) text: **\(preserved)/\(totalChecked) (\(pct(safeDiv(preserved, totalChecked))))**")
        if !failures.isEmpty {
            print("Word-preservation failures:")
            for failure in failures.prefix(20) { print("  ✘ \(failure)") }
        }
    }

    private static func report(_ results: [StyleResult], args: Arguments, contractVersion: String, goldenFile: String) {
        let nonAspirational = results.filter { !$0.item.isAspirational }
        let aspirational = results.filter(\.item.isAspirational)

        let wordPreservationFailures = results.filter { !$0.wordsPreserved }
        let nonAspirationalPassed = nonAspirational.filter(\.passed).count
        let aspirationalPassed = aspirational.filter(\.passed).count

        print("### Style formatting · contract \(contractVersion) · \(results.count) cases (\(nonAspirational.count) scored, \(aspirational.count) aspirational)")
        print("- Word preservation: \(results.count - wordPreservationFailures.count)/\(results.count) (\(pct(wordPreservationFailures.isEmpty ? 1 : Double(results.count - wordPreservationFailures.count) / Double(results.count))))")
        print("- Non-aspirational pass rate: **\(nonAspirationalPassed)/\(nonAspirational.count) (\(pct(safeDiv(nonAspirationalPassed, nonAspirational.count))))**")
        print("- Aspirational pass rate (informational, not gated): \(aspirationalPassed)/\(aspirational.count) (\(pct(safeDiv(aspirationalPassed, aspirational.count))))")

        // Per context x style breakdown, non-aspirational only (the gated signal).
        let grouped = Dictionary(grouping: nonAspirational, by: { "\($0.item.context)/\($0.item.style)" })
        print("\n| Context / style | Pass | Rate |")
        print("|---|---:|---:|")
        for key in grouped.keys.sorted() {
            let items = grouped[key]!
            let passed = items.filter(\.passed).count
            print("| \(key) | \(passed)/\(items.count) | \(pct(safeDiv(passed, items.count))) |")
        }

        if !wordPreservationFailures.isEmpty {
            print("\nWord-preservation failures (hard failures — a style rule changed words):")
            for failure in wordPreservationFailures {
                print("  ✘ \(failure.item.id): input \"\(failure.item.input)\" -> got \"\(failure.actual)\"")
            }
        }

        let formatFailures = nonAspirational.filter { !$0.passed }
        if !formatFailures.isEmpty {
            print("\nNon-aspirational formatting mismatches:")
            for failure in formatFailures {
                print("  ✘ \(failure.item.id) [\(failure.item.context)/\(failure.item.style)]")
                print("      input:    \(failure.item.input)")
                print("      expected: \(failure.item.expected.replacingOccurrences(of: "\n", with: " ⏎ "))")
                print("      got:      \(failure.actual.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }

        if let path = args.string("report") {
            writeReport(results, to: path, contractVersion: contractVersion, goldenFile: goldenFile)
        }

        if let minimum = args.string("min-pass") {
            guard let value = Double(minimum), (0...1).contains(value) else {
                fatalError("--min-pass must be a fraction in 0...1")
            }
            guard wordPreservationFailures.isEmpty else {
                FileHandle.standardError.write(Data("word preservation must be 100% (\(wordPreservationFailures.count) failure(s))\n".utf8))
                exit(1)
            }
            guard safeDiv(nonAspirationalPassed, nonAspirational.count) >= value else {
                FileHandle.standardError.write(Data("Non-aspirational pass rate below required \(value)\n".utf8))
                exit(1)
            }
        }
    }

    private static func writeReport(_ results: [StyleResult], to path: String, contractVersion: String, goldenFile: String) {
        let cases: [[String: Any]] = results.map { result in
            [
                "id": result.item.id, "context": result.item.context, "style": result.item.style,
                "input": result.item.input, "expected": result.item.expected, "actual": result.actual,
                "aspirational": result.item.isAspirational, "wordsPreserved": result.wordsPreserved,
                "exactMatch": result.exactMatch, "passed": result.passed,
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 2, "title": "Style formatting", "contractVersion": contractVersion,
            "goldenFile": goldenFile,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "total": results.count, "cases": cases,
        ]
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private static func safeDiv(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
    private static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}
