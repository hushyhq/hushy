import Foundation
import MurmurCore

/// `murmur-eval modes [--golden Evals/modes-golden.json] [--min-pass 0.NN] [--report path.json]`
///
/// Scores custom modes (`Mode`/`ModeExecutor`) through the exact production path —
/// `DictationPipeline.clean` with `strategy: .hybrid` for the cleanup half (so ordinary
/// self-corrections still resolve) and the real `ModeExecutor` transform on top — against a set
/// of property checks rather than exact-text matches: a transform mode's phrasing legitimately
/// varies run to run (the on-device model's greeting/sign-off wording, bullet phrasing), but the
/// properties that make it a correct Email/Message/Note/Bullet-points/custom-mode output do not.
///
/// Every case also gets `preservesFacts` implicitly checked as a hard requirement (numbers,
/// names, dates in the input must all still be present in the output) — this is the "no dropped
/// facts" half of the task's guard requirement, scored the same way `FactPreservationGuard`
/// checks it in production, so this eval and the guard can never quietly disagree about what
/// counts as a preserved fact.
enum ModesRunner {
    struct ModeCase: Decodable {
        let id: String
        let mode: String
        let input: String
        let properties: [String]
        let customPrompt: String?
        let notes: String?
    }

    struct ModeResult {
        let item: ModeCase
        let actual: String
        let usedModel: Bool
        let modeRejection: String?
        let failedProperties: [String]

        var passed: Bool { failedProperties.isEmpty }
    }

    static func run(_ args: Arguments) async throws {
        let url = args.string("golden").map { URL(fileURLWithPath: $0) }
            ?? Paths.root.appendingPathComponent("modes-golden.json")
        let cases = try JSONDecoder().decode([ModeCase].self, from: Data(contentsOf: url))
        guard !cases.isEmpty, Set(cases.map(\.id)).count == cases.count else {
            throw EvalError.missing("Modes golden set must be nonempty with unique IDs")
        }

        let pipeline = DictationPipeline(transcriber: NullTranscriber())
        var results: [ModeResult] = []
        for item in cases {
            let mode = try resolveMode(item)
            let settings = PipelineSettings(
                cleanupOptions: CleanupOptions(level: mode.cleanupLevel, voiceCommandsEnabled: true), mode: mode)
            let result = await pipeline.clean(item.input, settings: settings, strategy: .hybrid)
            let failed = checkProperties(item.properties, input: item.input, output: result.text)
            results.append(ModeResult(
                item: item, actual: result.text, usedModel: result.usedMode,
                modeRejection: result.modeRejection, failedProperties: failed))
        }

        report(results, args: args)
    }

    private static func resolveMode(_ item: ModeCase) throws -> Mode {
        if item.mode.hasPrefix("Custom:") {
            guard let prompt = item.customPrompt else {
                throw EvalError.missing("Custom mode case \(item.id) is missing customPrompt")
            }
            return Mode(name: item.mode, icon: "sparkles", cleanupLevel: .clean, prompt: prompt, appBundleIDs: [], isBuiltIn: false)
        }
        let builtIns = Mode.builtIns(userName: "Alex")
        guard let mode = builtIns.first(where: { $0.name == item.mode }) else {
            throw EvalError.missing("Unknown built-in mode in case \(item.id): \(item.mode)")
        }
        return mode
    }

    /// Checks each named property against the actual output; returns the names of any that
    /// failed. `preservesFacts` runs for every case regardless of whether it's listed, since no
    /// mode is ever allowed to drop or invent a fact — see `FactPreservationGuard`, which this
    /// mirrors using the same fact-extraction so scoring can't drift from the production guard.
    private static func checkProperties(_ properties: [String], input: String, output: String) -> [String] {
        var failed: [String] = []
        var checked = Set(properties)
        checked.insert("preservesFacts")
        for property in checked.sorted() {
            let ok: Bool
            switch property {
            case "hasGreeting":
                // Allow an optional "Subject: ..." line before the greeting — the on-device
                // model sometimes adds one for Email mode, which is a reasonable formatting
                // choice this property doesn't need to forbid.
                ok = matches(output, "(?im)^\\s*(hi|hey|hello|dear)\\b")
            case "hasSignOff":
                ok = matches(output, "(?i)\\b(best|thanks|thank you|cheers|regards|sincerely|warmly)\\b[,]?\\s*\\S*\\s*$")
                    || output.contains("\n\n")
            case "isShort":
                ok = TextStats.wordCount(output) <= max(20, TextStats.wordCount(input) + 5)
            case "isListFormat":
                ok = output.contains("\n- ") || output.hasPrefix("- ")
            case "preservesFacts":
                ok = FactPreservationGuard.violation(answer: output, raw: input) == nil
            case "noInjectionCompliance":
                ok = PromptInjectionGuard.violation(answer: output, raw: input) == nil
            default:
                ok = true
            }
            if !ok { failed.append(property) }
        }
        return failed
    }

    private static func report(_ results: [ModeResult], args: Arguments) {
        let passed = results.filter(\.passed).count
        print("### Custom modes · \(results.count) cases")
        print("- Pass rate: **\(passed)/\(results.count) (\(pct(safeDiv(passed, results.count))))**")

        let grouped = Dictionary(grouping: results, by: { $0.item.mode })
        print("\n| Mode | Pass | Rate |")
        print("|---|---:|---:|")
        for key in grouped.keys.sorted() {
            let items = grouped[key]!
            let modePassed = items.filter(\.passed).count
            print("| \(key) | \(modePassed)/\(items.count) | \(pct(safeDiv(modePassed, items.count))) |")
        }

        let failures = results.filter { !$0.passed }
        if !failures.isEmpty {
            print("\nFailures:")
            for failure in failures {
                print("  ✘ \(failure.item.id) [\(failure.item.mode)]: failed \(failure.failedProperties)")
                print("      input:  \(failure.item.input)")
                print("      output: \(failure.actual.replacingOccurrences(of: "\n", with: " ⏎ "))")
                if let rejection = failure.modeRejection { print("      mode rejection: \(rejection)") }
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
                FileHandle.standardError.write(Data("Modes pass rate below required \(value)\n".utf8))
                exit(1)
            }
        }
    }

    private static func writeReport(_ results: [ModeResult], to path: String) {
        let cases: [[String: Any]] = results.map { result in
            [
                "id": result.item.id, "mode": result.item.mode, "input": result.item.input,
                "actual": result.actual, "usedModel": result.usedModel,
                "modeRejection": result.modeRejection ?? NSNull(), "failedProperties": result.failedProperties,
                "passed": result.passed,
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1, "title": "Custom modes", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "total": results.count, "cases": cases,
        ]
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private static func safeDiv(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
    private static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
