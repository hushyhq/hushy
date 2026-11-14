import Foundation
import MurmurCore

/// `murmur-eval tools`: the voice-actions / tool-calling eval (tools-v1).
///
///   murmur-eval tools [--dataset Evals/actions-tools-dev.json] [--backend apple|mlx|none]
///                     [--mode extractor|catalog] [--limit N] [--category <name>] [--budget-ms N]
///                     [--judge jev] [--show N] [--report path.json]
///   murmur-eval tools --heldout <path>  … (orchestrator only: the sealed set, aggregates only)
///   murmur-eval tools --print-catalog    (prints the tools-v1 JSON-schema catalogue)
///
/// Default mode: `extractor` for apple and none (the shipping baseline), `catalog` for mlx.
/// `--budget-ms`: per-call budget (extractor default = the shipping 2.5 s; catalog default 5 s).
/// Dev runs refuse sealed paths (`SealedEvalGuard`); `--heldout` refuses anything that isn't the
/// pinned sealed file and never prints or writes a case — only aggregate numbers.
enum ToolsRunner {
    static let defaultDataset = "Evals/actions-tools-dev.json"
    static let devPurpose = "murmur-eval tools (dev)"

    static func run(_ args: Arguments) async throws {
        if args.flag("print-catalog") {
            print(VoiceToolCatalog.catalogJSON(), terminator: "")
            return
        }
        let heldout = args.string("heldout")
        let path = heldout ?? args.string("dataset") ?? defaultDataset
        let set = try ToolEvalSet.load(
            URL(fileURLWithPath: path), access: heldout == nil ? .tuning(purpose: devPurpose) : .sealedHeldout)
        var cases = set.cases
        if let category = args.string("category") { cases = cases.filter { $0.category.rawValue == category } }
        cases = Array(cases.prefix(args.int("limit") ?? .max))

        let backendName = args.string("backend") ?? "apple"
        let backend = makeBackend(args, backendName: backendName)
        guard backend.isAvailable || backendName == "none" else {
            print("### Voice tools (\(VoiceToolCatalog.version)) · \(set.name) · \(backend.label)\nSKIPPED: the backend is unavailable on this Mac.")
            return
        }
        backend.prewarm()
        var outcomes: [ToolEvalOutcome] = []
        for item in cases {
            outcomes.append(ToolEvalScoring.score(item, await backend.answer(item)))
        }

        let summary = ToolEvalSummary(outcomes)
        let isHeldout = heldout != nil
        var markdown = ToolEvalReport.markdown(set: set, backend: backend.label, summary: summary, heldout: isHeldout)
        var details = isHeldout ? [] : ToolEvalReport.failureLines(outcomes, limit: args.int("show") ?? 60)
        if args.string("judge") == "jev" {
            if let apiKey = JudgeRunner.loadAPIKey() {
                let jev = ToolJevRubric.markdown(try await ToolJevRubric.judge(outcomes, apiKey: apiKey), showCases: !isHeldout)
                markdown += "\n" + jev.summary
                details += jev.details.isEmpty ? [] : ["Checks × Jev disagreements (read by hand):"] + jev.details
            } else {
                markdown += "\n- Jev second opinion: skipped (no TypeSafe API key)"
            }
        }
        Runners.emit(markdown, details: details)
        if let report = args.string("report") {
            try ToolEvalReport.writeJSON(to: URL(fileURLWithPath: report), set: set, backend: backend.label, summary: summary,
                                         outcomes: isHeldout ? [] : outcomes)
        }
    }

    static func makeBackend(_ args: Arguments, backendName: String) -> any ToolEvalBackend {
        let model = LanguageModels.current
        let defaultMode: ToolEvalMode = backendName == "mlx" ? .catalog : .extractor
        let mode = args.string("mode").flatMap(ToolEvalMode.init(rawValue:)) ?? defaultMode
        switch mode {
        case .extractor: return ExtractorToolBackend(model: model, budget: args.int("budget-ms").map { .milliseconds($0) })
        case .catalog: return CatalogToolBackend(model: model, budget: .milliseconds(args.int("budget-ms") ?? 5_000))
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

enum ToolEvalReport {
    static func markdown(set: ToolEvalSet, backend: String, summary s: ToolEvalSummary, heldout: Bool) -> String {
        func pct(_ value: Double) -> String { Runners.percent(value) }
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "n/a" }
        let negativeShare = pct(Double(s.negatives) / Double(max(s.total, 1)))
        let locales = s.byLocale.map { "\($0.0) \($0.1.count)" }.joined(separator: " / ")
        let toolName = s.toolNameP50 == nil
            ? "n/a — the `LanguageModel` seam doesn't stream, so the tool name is known only at the end (= total)"
            : "\(ms(s.toolNameP50)) / \(ms(s.toolNameP95))"
        var lines = [
            "### Voice tools (\(VoiceToolCatalog.version)) · \(set.name)\(heldout ? " · SEALED HELD-OUT (aggregates only)" : "") · \(backend) · \(s.total) cases",
            "Cases: \(s.positives) commands · \(s.negatives) no-action (\(negativeShare)) · \(s.refusals) refusals; \(locales)",
            "",
            "| Metric | Value |",
            "|---|---|",
            "| Tool-select accuracy (all cases) | **\(pct(s.toolSelectAccuracy))** (per-tool macro \(pct(s.perToolMacroAccuracy))) |",
            "| Call exact match (commands) | \(pct(s.callExactRate)) |",
            "| Call tolerant match (commands) | \(pct(s.callTolerantRate)) |",
            "| Arguments exact / tolerant, given the right tool | \(pct(s.argExactGivenTool)) / \(pct(s.argTolerantGivenTool)) |",
            "| Slot accuracy, tolerant (\(s.slotChecks) slots) | \(pct(s.slotTolerantAccuracy)) |",
            "| **False-fire rate** on no-action cases | **\(pct(s.falseFireRate))** (\(s.falseFires)/\(s.negatives)) |",
            "| Missed commands (answered no action) | \(pct(s.missedCommandRate)) |",
            "| List or calendar named that nobody said | \(s.unaskedTargets)/\(s.targetFreeCommands) |",
            "| Refusal correct: no action / right reason | \(pct(s.refusalLenient)) / \(pct(s.refusalStrict)) |",
            "| Schema-valid answers (tools-v1) | \(pct(s.schemaValidity)) |",
            "| Errors (timeout, refusal, unavailable) | \(s.errors) |",
            "| Model asked | \(s.modelCalls)/\(s.total) |",
            "| False fires that would act at once (no card) | \(s.falseFiresActingAtOnce)/\(s.falseFires) |",
            "| Latency p50 / p95 | \(ms(s.latencyP50)) / \(ms(s.latencyP95)) |",
            "| Time to tool name p50 / p95 | \(toolName) |",
            "",
            "| Category | n | Tool right | Tolerant match |",
            "|---|---|---|---|",
        ]
        lines += s.byCategory.map { row(String(describing: $0.0.rawValue), $0.1) }
        lines += ["", "| Expected tool | n | Tool right | Tolerant match |", "|---|---|---|---|"]
        lines += s.byExpectedTool.map { row($0.0, $0.1) }
        return lines.joined(separator: "\n")
    }

    private static func row(_ label: String, _ group: ToolEvalSummary.Group) -> String {
        let count = Double(max(group.count, 1))
        return "| \(label) | \(group.count) | \(Runners.percent(Double(group.toolCorrect) / count)) | \(Runners.percent(Double(group.tolerant) / count)) |"
    }

    /// Dev runs only: every miss, false fire first.
    static func failureLines(_ outcomes: [ToolEvalOutcome], limit: Int) -> [String] {
        let failing = outcomes.filter { !$0.callTolerant }.sorted { ($0.falseFire ? 0 : 1, $0.item.id) < ($1.falseFire ? 0 : 1, $1.item.id) }
        guard !failing.isEmpty else { return [] }
        let lines = failing.prefix(limit).map { outcome -> String in
            let expected = outcome.item.expect.decision == .call
                ? ToolEvalScoring.describe(outcome.item.expect.call)
                : "no_action(\((outcome.item.expect.reasons ?? []).joined(separator: "|")))"
            return "  ✘ \(outcome.item.id) [\(outcome.item.category.rawValue)] \"\(outcome.item.utterance)\"\n      expected \(expected)\n      got      \(outcome.predictedLabel)"
        }
        return ["Failures (\(failing.count), showing \(lines.count)):"] + lines
    }

    static func writeJSON(
        to url: URL, set: ToolEvalSet, backend: String, summary s: ToolEvalSummary, outcomes: [ToolEvalOutcome]
    ) throws {
        let cases: [[String: Any]] = outcomes.map { outcome in
            [
                "id": outcome.item.id, "category": outcome.item.category.rawValue, "toolCorrect": outcome.toolCorrect,
                "callExact": outcome.callExact, "callTolerant": outcome.callTolerant, "falseFire": outcome.falseFire,
                "got": outcome.predictedLabel, "latencyMs": outcome.answer.latencyMs,
                "unaskedTarget": outcome.namesUnaskedTarget, "tags": outcome.item.tags,
                "missed": outcome.item.expect.decision == .call
                    && (outcome.answer.error != nil || outcome.answer.calls.allSatisfy(\.isNoAction)),
                "slots": outcome.slots.mapValues { $0.tolerant },
                "modelCalled": outcome.answer.modelCalled.map { $0 as Any } ?? NSNull(),
                "actsAtOnce": outcome.answer.actsAtOnce.map { $0 as Any } ?? NSNull(),
            ]
        }
        let payload: [String: Any] = [
            "kind": "tools", "catalog": VoiceToolCatalog.version, "set": set.name, "split": set.split, "backend": backend,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "total": s.total, "toolSelectAccuracy": s.toolSelectAccuracy, "perToolMacroAccuracy": s.perToolMacroAccuracy,
            "callExact": s.callExactRate, "callTolerant": s.callTolerantRate, "falseFireRate": s.falseFireRate,
            "refusalLenient": s.refusalLenient, "refusalStrict": s.refusalStrict, "schemaValidity": s.schemaValidity,
            "modelCalls": s.modelCalls, "falseFiresActingAtOnce": s.falseFiresActingAtOnce,
            "unaskedTargets": s.unaskedTargets, "targetFreeCommands": s.targetFreeCommands,
            "latencyP50Ms": s.latencyP50, "latencyP95Ms": s.latencyP95, "cases": cases,
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
