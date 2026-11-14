import Foundation
import MurmurCore

/// `murmur-eval tools --judge jev`: a second opinion on the arguments (Evals/JUDGES.md policy —
/// checks stay the verdict, Jev flags what they can't express). Asked only for commands where
/// the backend picked the right tool, since tool choice and false fires are exact already.
/// Two Noul questions per case; verdict in code: pass when `same_action` ≥ 0.5 and
/// `invented_value` < 0.5. Cached like every Jev call (`.build/judge-cache/jev/`).
enum ToolJevRubric {
    static let version = "tools-jev-v1"

    static func state(_ outcome: ToolEvalOutcome) -> TypeSafeClient.AnyJSON {
        let predicted = outcome.answer.calls.first { !$0.isNoAction }.map(ToolEvalScoring.describe) ?? "none"
        return .strings([
            "rubric": version,
            "utterance": outcome.item.utterance,
            "context": outcome.item.context.promptLine(),
            "expected_call": ToolEvalScoring.describe(outcome.item.expect.call),
            "predicted_call": predicted,
        ])
    }

    static let questions: [String: TypeSafeClient.Question] = [
        "same_action": TypeSafeClient.Question(
            type: .noul,
            instructions: .string("""
                The speaker's utterance was turned into predicted_call. expected_call is the reference answer; \
                dates in it are already resolved to ISO time while predicted_call may keep the spoken phrase. \
                Would predicted_call do what the speaker asked, the same as expected_call? Small wording \
                differences in titles or bodies are fine. A different date or time, person, list, item, app, \
                shortcut or channel, or a missing detail the speaker gave, is not the same action.
                """),
            criteria: .strings(["true": "does the same thing the speaker asked", "false": "a different or incomplete action"])),
        "invented_value": TypeSafeClient.Question(
            type: .noul,
            instructions: .string("""
                Does predicted_call contain a value the speaker never said or clearly implied — an invented \
                date, time, duration, place, person, list or text?
                """),
            criteria: .strings(["true": "contains an invented value", "false": "every value comes from the utterance"])),
    ]

    struct Verdict: Sendable {
        let sameAction: Double
        let invented: Double
        var passed: Bool { sameAction >= 0.5 && invented < 0.5 }
    }

    static func judge(_ outcomes: [ToolEvalOutcome], apiKey: String) async throws -> [(ToolEvalOutcome, Verdict)] {
        let judge = JevJudge(apiKey: apiKey)
        let eligible = outcomes.filter { $0.item.expect.decision == .call && $0.toolCorrect }
        let verdicts = try await JudgeClient.mapConcurrently(eligible) { outcome in
            let response = try await judge.cachedAsk(state: state(outcome), questions: questions, useCache: true).value
            return Verdict(
                sameAction: response.answers["same_action"]?.noul ?? 0, invented: response.answers["invented_value"]?.noul ?? 1)
        }
        return Array(zip(eligible, verdicts))
    }

    /// Agreement with the tolerant checks, plus the disagreements to read by hand (dev only).
    static func markdown(_ pairs: [(ToolEvalOutcome, Verdict)], showCases: Bool) -> (summary: String, details: [String]) {
        var both = 0, checksOnly = 0, jevOnly = 0, neither = 0
        var details: [String] = []
        for (outcome, verdict) in pairs {
            switch (outcome.callTolerant, verdict.passed) {
            case (true, true): both += 1
            case (true, false): checksOnly += 1
            case (false, true): jevOnly += 1
            case (false, false): neither += 1
            }
            if showCases, outcome.callTolerant != verdict.passed {
                details.append("  \(outcome.callTolerant ? "checks✔ jev✘" : "checks✘ jev✔") \(outcome.item.id) same=\(String(format: "%.2f", verdict.sameAction)) invented=\(String(format: "%.2f", verdict.invented)) — \"\(outcome.item.utterance)\" → \(outcome.predictedLabel)")
            }
        }
        let jevPass = Runners.percent(Double(both + jevOnly) / Double(max(pairs.count, 1)))
        let summary = """
            - Jev second opinion (\(version), \(JevRubric.model); \(pairs.count) commands with the right tool): Jev pass \(jevPass) · \
            tolerant checks × Jev: both pass \(both) · checks only \(checksOnly) · Jev only \(jevOnly) · both fail \(neither)
            """
        return (summary, details)
    }
}
