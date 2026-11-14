import Foundation
import MurmurCore

/// `murmur-eval model-diag --jev-reports a.json,b.json[,…] --max-calls N [--labels A,B,…]`
///
/// Jev pointwise second opinion (rubric v2, with reference) over outputs that `reformat --report`
/// already wrote — so an A/B of backends (quantization, speculation) is judged without re-running
/// the models, and outputs two runs share cost one call (the Jev cache is keyed by request).
/// `--max-calls` caps real API calls across the whole run (cached answers are free); cases that
/// would exceed it are skipped and counted. Prints, per report and level: judged cases, mean
/// pBad, pass / unsure / fail bands (< 0.3 / 0.3–0.7 / ≥ 0.7), and — against the first report —
/// mean pBad on only the cases whose outputs differ. Dev sets only; never pass a sealed file.
enum JevReportsJudge {
    struct Row {
        var level: String
        var id: String
        var input: String
        var reference: String
        var output: String
    }

    static func run(_ args: Arguments) async throws {
        let paths = (args.string("jev-reports") ?? "").split(separator: ",").map(String.init)
        guard !paths.isEmpty else { throw EvalError.missing("--jev-reports needs report paths") }
        for path in paths { try SealedEvalGuard.assertTuningSafe(URL(fileURLWithPath: path), purpose: "murmur-eval jev-reports") }
        guard let apiKey = JudgeRunner.loadAPIKey() else {
            print("### Jev over reports · skipped — no TypeSafe API key")
            return
        }
        let labels = (args.string("labels") ?? "").split(separator: ",").map(String.init)
        let budget = CallBudget(name: "jev", limit: args.int("max-calls") ?? 300)
        var judge = JevJudge(apiKey: apiKey)
        judge.budget = budget
        let reports = try paths.map(load)
        var verdicts: [[String: Double]] = []  // per report: "level|id" → pBad
        var skipped = 0
        for rows in reports {
            var scores: [String: Double] = [:]
            for row in rows {
                do {
                    let verdict = try await judge.judge(level: row.level, spoken: row.input, output: row.output, reference: row.reference).value
                    scores["\(row.level)|\(row.id)"] = verdict.pBad
                } catch is CallBudget.Exhausted {
                    skipped += 1
                }
            }
            verdicts.append(scores)
        }
        var lines = ["### Jev (\(JevRubric.version)) pointwise over reformat reports · real calls \(await budget.used), skipped (budget) \(skipped)", "",
                     "| Report | Level | judged | mean pBad | pass / unsure / fail | differing vs first: n, mean pBad (this) vs (first) |",
                     "|---|---|---|---|---|---|"]
        for (index, rows) in reports.enumerated() {
            let label = index < labels.count ? labels[index] : URL(fileURLWithPath: paths[index]).lastPathComponent
            for level in Array(Set(rows.map(\.level))).sorted() {
                let keys = rows.filter { $0.level == level }.map { "\(level)|\($0.id)" }
                let scores = keys.compactMap { verdicts[index][$0] }
                guard !scores.isEmpty else { continue }
                let mean = scores.reduce(0, +) / Double(scores.count)
                let bands = [scores.filter { $0 < 0.3 }.count, scores.filter { $0 >= 0.3 && $0 < 0.7 }.count, scores.filter { $0 >= 0.7 }.count]
                var differing = "—"
                if index > 0 {
                    let firstOutputs = Dictionary(reports[0].map { ("\($0.level)|\($0.id)", $0.output) }, uniquingKeysWith: { a, _ in a })
                    let changed = rows.filter { $0.level == level && firstOutputs["\(level)|\($0.id)"] != $0.output }
                        .map { "\(level)|\($0.id)" }
                        .filter { verdicts[index][$0] != nil && verdicts[0][$0] != nil }
                    if !changed.isEmpty {
                        let this = changed.compactMap { verdicts[index][$0] }.reduce(0, +) / Double(changed.count)
                        let first = changed.compactMap { verdicts[0][$0] }.reduce(0, +) / Double(changed.count)
                        differing = String(format: "%d, %.3f vs %.3f", changed.count, this, first)
                    } else {
                        differing = "0"
                    }
                }
                lines.append("| \(label) | \(level) | \(scores.count) | " + String(format: "%.3f", mean) + " | \(bands.map(String.init).joined(separator: " / ")) | \(differing) |")
            }
        }
        Runners.emit(lines.joined(separator: "\n"), details: [])
    }

    /// Rows from a `reformat --report` JSON (levels → cases with input/reference/output).
    static func load(_ path: String) throws -> [Row] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let levels = object["levels"] as? [[String: Any]] else {
            throw EvalError.missing("\(path) is not a reformat report")
        }
        return levels.flatMap { level -> [Row] in
            let name = level["level"] as? String ?? "clean"
            return (level["cases"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, let input = item["input"] as? String,
                      let output = item["output"] as? String, let reference = item["reference"] as? String else { return nil }
                return Row(level: name, id: id, input: input, reference: reference, output: output)
            }
        }
    }
}
