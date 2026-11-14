import Foundation
import MurmurCore

/// Optional second opinion for `murmur-eval reformat --judge`: Jev with rubric v2 (`JevRubric`,
/// grounded in the level being scored, compared against each case's `reference`). Report only —
/// never gates (policy: `Evals/JUDGES.md`). Skips cleanly (with a message, exit status unchanged)
/// when no key is configured or the API fails; the key itself is never printed. Answers are
/// cached under `.build/judge-cache/jev/`.
enum ReformatJudge {
    typealias Verdict = JevJudgment

    /// Returns level name -> case id -> verdict. Empty when skipped.
    static func judge(_ runs: [ReformatRunner.LevelRun]) async -> [String: [String: Verdict]] {
        guard let apiKey = JudgeRunner.loadAPIKey() else {
            print("\n### Reformat judge (Jev) · skipped — no TYPESAFE_API_KEY or ~/.config/hushy/typesafe_api_key")
            return [:]
        }
        let judge = JevJudge(apiKey: apiKey)
        var all: [String: [String: Verdict]] = [:]
        for run in runs {
            do {
                let level = run.level.rawValue
                let judgments = try await JudgeClient.mapConcurrently(run.cases) { item in
                    (item.id, try await judge.judge(level: level, spoken: item.input, output: item.output, reference: item.reference).value)
                }
                let verdicts = Dictionary(judgments, uniquingKeysWith: { first, _ in first })
                all[level] = verdicts
                printSummary(run, verdicts: verdicts)
            } catch {
                print("\n### Reformat judge (Jev) · \(run.level.rawValue) · skipped — \(error.localizedDescription)")
            }
        }
        return all
    }

    private static func printSummary(_ run: ReformatRunner.LevelRun, verdicts: [String: Verdict]) {
        let values = Array(verdicts.values)
        let count = Double(max(values.count, 1))
        let meaning = values.reduce(0) { $0 + $1.meaning } / count
        func share(_ band: JevJudgment.Band) -> String { ReformatReport.pct(Double(values.filter { $0.band == band }.count) / count) }
        let disagreements = run.cases.filter { item in
            guard let verdict = verdicts[item.id] else { return false }
            return (item.outcome.passed && verdict.band == .fail) || (!item.outcome.passed && verdict.band == .pass)
        }
        Runners.emit("""
            ### Reformat judge (Jev \(JevRubric.version)) · \(run.level.rawValue) · \(values.count) cases
            - Mean meaning: \(String(format: "%.2f", meaning)) / 4
            - Jev pass / unsure / fail: \(share(.pass)) / \(share(.unsure)) / \(share(.fail))
            - Disagreements with the checks (Jev pass & checks fail, or checks pass & Jev fail): \(disagreements.count)
            """, details: disagreements.map { item in
                let verdict = verdicts[item.id]!
                return "  \(item.outcome.passed ? "checks✔ jev✘" : "checks✘ jev✔") \(item.id) pBad=\(String(format: "%.2f", verdict.pBad)) \(verdict.firedFaults())\n    got: \(item.output)"
            })
    }
}
