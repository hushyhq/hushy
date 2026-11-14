import Foundation

/// `murmur-eval agent-prompts score --cases Evals/sets/agent-prompts/dev-120.jsonl --outputs run.jsonl [--report path.json]`
///
/// Scores cleanup output for invented spoken agent prompts. Deterministic metrics mirror
/// `scripts/agent_prompts_eval.py` (SCORER_VERSION 1). An optional LLM judge hook is not implemented.
enum AgentPromptsRunner {
    struct Aggregate: Sendable {
        let rows: Int
        let identifierExactAll: Int
        let requirementsKeptAll: Int
        let inventedRequirement: Int
        let answeredInstead: Int
        let listShapeOK: Int
        let meanIdentifierRate: Double
        let meanRequirementsRate: Double
    }

    static func run(_ args: Arguments) async throws {
        try score(args)
    }

    private static func score(_ args: Arguments) throws {
        let casesPath = args.string("cases")
            ?? Paths.root.appendingPathComponent("sets/agent-prompts/dev-120.jsonl").path
        let outputsPath = args.string("outputs")
        guard let outputsPath else { throw EvalError.missing("agent-prompts score needs --outputs <jsonl>") }
        let cases = try AgentPromptsChecks.loadCases(casesPath)
        let outputs = try readOutputs(outputsPath)
        guard Set(cases.map(\.id)) == Set(outputs.keys) else {
            throw EvalError.missing("output IDs must match case IDs")
        }
        var verdicts: [AgentPromptsChecks.Verdict] = []
        for item in cases {
            guard let text = outputs[item.id] else { continue }
            verdicts.append(AgentPromptsChecks.score(item, output: text))
        }
        report(verdicts, cases: cases, args: args)
    }

    private static func readOutputs(_ path: String) throws -> [String: String] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var rows: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String, let output = obj["text"] as? String else {
                throw EvalError.missing("outputs JSONL needs id and text per row")
            }
            rows[id] = output
        }
        return rows
    }

    private static func aggregate(_ verdicts: [AgentPromptsChecks.Verdict]) -> Aggregate {
        let n = verdicts.count
        guard n > 0 else {
            return Aggregate(rows: 0, identifierExactAll: 0, requirementsKeptAll: 0, inventedRequirement: 0,
                             answeredInstead: 0, listShapeOK: 0, meanIdentifierRate: 0, meanRequirementsRate: 0)
        }
        return Aggregate(
            rows: n,
            identifierExactAll: verdicts.filter { $0.identifierExactRate == 1 }.count,
            requirementsKeptAll: verdicts.filter { $0.requirementsKeptRate == 1 }.count,
            inventedRequirement: verdicts.filter(\.inventedRequirement).count,
            answeredInstead: verdicts.filter(\.answeredInsteadOfCleaned).count,
            listShapeOK: verdicts.filter(\.listShapeOK).count,
            meanIdentifierRate: verdicts.map(\.identifierExactRate).reduce(0, +) / Double(n),
            meanRequirementsRate: verdicts.map(\.requirementsKeptRate).reduce(0, +) / Double(n))
    }

    private static func report(
        _ verdicts: [AgentPromptsChecks.Verdict], cases: [AgentPromptsChecks.Case], args: Arguments
    ) {
        let agg = aggregate(verdicts)
        let byApp = Dictionary(grouping: verdicts) { id in cases.first { $0.id == id.id }?.app ?? "?" }
        print("### Agent prompts · \(agg.rows) cases · scorer v\(AgentPromptsChecks.scorerVersion)")
        print("| metric | count | rate |")
        print("|---|---:|---:|")
        print("| identifiers all exact | \(agg.identifierExactAll) | \(pct(agg.identifierExactAll, agg.rows)) |")
        print("| requirements all kept | \(agg.requirementsKeptAll) | \(pct(agg.requirementsKeptAll, agg.rows)) |")
        print("| invented requirement flagged | \(agg.inventedRequirement) | \(pct(agg.inventedRequirement, agg.rows)) |")
        print("| answered instead of cleaned | \(agg.answeredInstead) | \(pct(agg.answeredInstead, agg.rows)) |")
        print("| list shape ok | \(agg.listShapeOK) | \(pct(agg.listShapeOK, agg.rows)) |")
        print("| mean identifier rate | — | \(String(format: "%.1f%%", agg.meanIdentifierRate * 100)) |")
        print("| mean requirements rate | — | \(String(format: "%.1f%%", agg.meanRequirementsRate * 100)) |")
        print("\n| app | cases | id exact | req kept | invented | answered | list ok |")
        print("|---|---:|---:|---:|---:|---:|---:|")
        for app in byApp.keys.sorted() {
            let group = byApp[app] ?? []
            let n = group.count
            print("| \(app) | \(n) | \(group.filter { $0.identifierExactRate == 1 }.count) | "
                + "\(group.filter { $0.requirementsKeptRate == 1 }.count) | "
                + "\(group.filter(\.inventedRequirement).count) | "
                + "\(group.filter(\.answeredInsteadOfCleaned).count) | "
                + "\(group.filter(\.listShapeOK).count) |")
        }
        let worst = verdicts.sorted {
            ($0.identifierExactRate + $0.requirementsKeptRate, $0.id) < ($1.identifierExactRate + $1.requirementsKeptRate, $1.id)
        }.prefix(10)
        if !worst.isEmpty {
            print("\nWorst cases (by combined identifier + requirement rates):")
            for item in worst {
                print("  \(item.id): id \(String(format: "%.0f%%", item.identifierExactRate * 100)) "
                    + "req \(String(format: "%.0f%%", item.requirementsKeptRate * 100))")
            }
        }
        if let path = args.string("report") {
            writeReport(verdicts, aggregate: agg, to: path)
        }
    }

    private static func pct(_ part: Int, _ total: Int) -> String {
        guard total > 0 else { return "—" }
        return String(format: "%.1f%%", Double(part) / Double(total) * 100)
    }

    private static func writeReport(_ verdicts: [AgentPromptsChecks.Verdict], aggregate: Aggregate, to path: String) {
        let cases: [[String: Any]] = verdicts.map { v in
            [
                "id": v.id,
                "identifier_exact_rate": v.identifierExactRate,
                "identifiers_missing": v.identifiersMissing,
                "requirements_kept_rate": v.requirementsKeptRate,
                "requirements_missing": v.requirementsMissing,
                "invented_requirement": v.inventedRequirement,
                "answered_instead_of_cleaned": v.answeredInsteadOfCleaned,
                "list_shape_ok": v.listShapeOK,
                "scorer_version": AgentPromptsChecks.scorerVersion,
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "title": "Agent prompts",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "aggregate": [
                "rows": aggregate.rows,
                "identifier_exact_all": aggregate.identifierExactAll,
                "requirements_kept_all": aggregate.requirementsKeptAll,
                "invented_requirement": aggregate.inventedRequirement,
                "answered_instead_of_cleaned": aggregate.answeredInstead,
                "list_shape_ok": aggregate.listShapeOK,
                "mean_identifier_rate": aggregate.meanIdentifierRate,
                "mean_requirements_rate": aggregate.meanRequirementsRate,
                "scorer_version": AgentPromptsChecks.scorerVersion,
            ],
            "cases": cases,
        ]
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
