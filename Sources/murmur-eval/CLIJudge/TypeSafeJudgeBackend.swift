import Foundation

/// Adapts Jev (rubric v2, `JevJudge`) to the single-verdict `CLIJudgeBackend` shape so a caller
/// that only needs pass/fail + a 1–4 meaning score can use Jev interchangeably with the CLI
/// judges. `rubric` is ignored: Jev's rubric is the typed question set in `JevRubric`, and
/// `level` selects which level promise the judgments are grounded in.
struct TypeSafeJudgeBackend: CLIJudgeBackend {
    let name = "jev"
    let model = JevRubric.model
    let apiKey: String
    var level = "clean"

    func judge(input: String, output: String, reference: String, rubric: String?) async throws -> JudgeVerdict {
        let judgment = try await JevJudge(apiKey: apiKey)
            .judge(level: level, spoken: input, output: output, reference: reference).value
        let faults = judgment.firedFaults()
        return JudgeVerdict(
            passed: judgment.passed(), meaningScore: judgment.meaning,
            reasoning: faults.isEmpty
                ? "Jev \(JevRubric.version): no fault ≥ 0.5 (pBad \(String(format: "%.2f", judgment.pBad)))"
                : "Jev \(JevRubric.version) faults: \(faults.joined(separator: ", "))")
    }
}
