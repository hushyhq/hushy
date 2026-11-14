import Foundation
import Testing

@testable import murmur_eval

@Suite("Judge calibration perturbations")
struct JudgePerturbationTests {
    @Test func dropNumberRemovesWholeNumberWithOrdinalOrPercent() {
        #expect(JudgePerturbations.dropNumber("We need 412 more units by Friday.") == "We need more units by Friday.")
        #expect(JudgePerturbations.dropNumber("Churn dropped 12.5% after the fix.") == "Churn dropped after the fix.")
        #expect(JudgePerturbations.dropNumber("Move it to the 19th, please.") == "Move it to the, please.")
        #expect(JudgePerturbations.dropNumber("No digits here.") == nil)
    }

    @Test func flipNegationRemovesBeforeItAdds() {
        #expect(JudgePerturbations.flipNegation("I don't want the beta.") == "I do want the beta.")
        #expect(JudgePerturbations.flipNegation("Don't merge it.") == "Do merge it.")
        #expect(JudgePerturbations.flipNegation("The build is green.") == "The build is not green.")
    }

    @Test func insertFillerIsDeterministicAndNeverFirst() {
        let a = JudgePerturbations.insertFiller("Wait for the build to finish.", seed: 12)
        #expect(a == JudgePerturbations.insertFiller("Wait for the build to finish.", seed: 12))
        #expect(a?.hasPrefix("Wait ") == true)
        #expect(JudgePerturbations.insertFiller("Too short", seed: 1) == nil)
    }

    @Test func overEditNeedsTwoSwaps() {
        #expect(JudgePerturbations.overEdit("Tell the team about the demo.") == "Inform the team regarding the demo.")
        #expect(JudgePerturbations.overEdit("Tell the team.") == nil)
    }

    @Test func changeFactSwapsDayOrUnusedName() {
        #expect(JudgePerturbations.changeFact("Ship it by Friday.") == "Ship it by Sunday.")
        // Never swaps a name to one already in the text ("Priya" → "Marcus" when Marcus is present).
        #expect(JudgePerturbations.changeFact("Assign it to Priya. Not Marcus, he's out.") == nil)
        #expect(JudgePerturbations.changeFact("Invite Sam and Lisa.") == "Invite Ben and Lisa.")
    }

    @Test func dropClauseNeedsSubstantialHeadAndTail() {
        #expect(JudgePerturbations.dropClause("Test the login flow. Forget the checkout flow, QA signed off.") == "Test the login flow.")
        #expect(JudgePerturbations.dropClause("Priya and I were thinking the buttons need contrast.") == nil)
    }

    @Test func flattenListJoinsItems() {
        #expect(JudgePerturbations.flattenList("Groceries:\n- Milk\n- Eggs\n- Bread") == "Groceries: Milk, Eggs and Bread.")
        #expect(JudgePerturbations.flattenList("Just a sentence.") == nil)
    }

    @Test func overCleanStripsTheThingsNegativesProtect() {
        #expect(JudgePerturbations.overClean("She had had the same problem.") == "She had the same problem.")
        #expect(JudgePerturbations.overClean("No, I don't want the beta.") == "I don't want the beta.")
        #expect(JudgePerturbations.overClean("Plain sentence here.") == nil)
    }
}

@Suite("Judge calibration metrics")
struct CalibrationMetricsTests {
    @Test func detectionCountsBadAsPositive() {
        let d = CalibrationMetrics.Detection(labelsBad: [true, true, false, false], predictedBad: [true, false, true, false])
        #expect(d.precision == 0.5)
        #expect(d.recall == 0.5)
        #expect(d.falsePositiveRate == 0.5)
        #expect(d.accuracy == 0.5)
    }

    @Test func perfectlyCalibratedBinsHaveZeroECE() {
        let probs = [0.1, 0.1, 0.9, 0.9]
        let labels = [false, false, true, true]
        #expect(CalibrationMetrics.auc(scores: probs, labels: labels) == 1)
        #expect(CalibrationMetrics.expectedCalibrationError(probabilities: [0.5, 0.5], labels: [true, false]) == 0)
        #expect(CalibrationMetrics.brier(probabilities: [1, 0], labels: [true, false]) == 0)
    }

    @Test func aucCountsTiesAsHalf() {
        #expect(CalibrationMetrics.auc(scores: [0.5, 0.5], labels: [true, false]) == 0.5)
    }
}

@Suite("Jev rubric v2")
struct JevRubricTests {
    private func response(meaning: [String: Double], nouls: [String: Double], layout: String = "layout_ok") -> TypeSafeClient.Response {
        var answers: [String: TypeSafeClient.Answer] = [
            "meaning": .init(type: .score, noul: nil, choice: nil, score: 2.9, confidence: 0.9, probabilities: meaning, legend: nil),
            "list_layout": .init(type: .choice, noul: nil, choice: layout, score: nil, confidence: 0.9,
                                 probabilities: [layout: 0.9, "list_missing": 0.1], legend: nil),
        ]
        for (key, value) in nouls {
            answers[key] = .init(type: .noul, noul: value, choice: nil, score: nil, confidence: nil, probabilities: nil, legend: nil)
        }
        return TypeSafeClient.Response(model: "jev-1.13.0", answers: answers, usage: nil)
    }

    private let cleanNouls: [String: Double] = [
        "dropped_content": 0.1, "changed_fact": 0.1, "disfluency_left": 0.1, "correction_left": 0.1,
        "over_edited": 0.1, "reads_clean": 0.9,
    ]

    @Test func cleanAnswersPass() throws {
        let judgment = try JevJudgment.decode(response(meaning: ["0": 0, "1": 0.02, "2": 0.08, "3": 0.9], nouls: cleanNouls))
        #expect(judgment.passed())
        #expect(abs(judgment.meaning - 3.88) < 0.001)
        #expect(judgment.firedFaults().isEmpty)
    }

    @Test func anySingleFaultFailsTheVerdict() throws {
        var nouls = cleanNouls
        nouls["disfluency_left"] = 0.8
        let judgment = try JevJudgment.decode(response(meaning: ["3": 1], nouls: nouls))
        #expect(!judgment.passed())
        #expect(judgment.firedFaults() == ["disfluency_left"])
    }

    @Test func missingAnswerIsADecodingError() {
        var nouls = cleanNouls
        nouls["over_edited"] = nil
        #expect(throws: TypeSafeClient.ClientError.self) {
            try JevJudgment.decode(response(meaning: ["3": 1], nouls: nouls))
        }
    }

    @Test func questionsAreGroundedInTheLevel() {
        #expect(JevRubric.promise(for: "clean").contains("no synonyms"))
        #expect(JevRubric.promise(for: "polished").contains("grammar"))
        #expect(JevRubric.questions(hasReference: true).count == 8)
        let withoutRef = JevRubric.state(level: "clean", spoken: "a", output: "b", reference: nil)
        guard case .object(let fields) = withoutRef else { Issue.record("state must be an object"); return }
        #expect(fields["reference"] == nil)
    }

    @Test func cacheKeyChangesWithOutput() {
        let q = JevRubric.questions(hasReference: false)
        let a = JevRubric.cacheKey(state: JevRubric.state(level: "clean", spoken: "x", output: "y", reference: nil), questions: q)
        let b = JevRubric.cacheKey(state: JevRubric.state(level: "clean", spoken: "x", output: "z", reference: nil), questions: q)
        #expect(a != b)
        #expect(a.hasPrefix("jev__jev-1.13.0__v2__"))
    }
}

@Suite("Judge sampling")
struct JudgeSamplingTests {
    @Test func failsPlusKeepsAllFailuresAndSomePasses() throws {
        let items = (0..<200).map { (id: "case-\($0)", passed: $0 % 4 != 0) }
        let spec = try JudgeSampling.parse("fails+20")
        let chosen = JudgeSampling.select(items, spec: spec, passed: \.passed, id: \.id)
        #expect(chosen.filter { !$0.passed }.count == 50)
        let passes = chosen.filter(\.passed).count
        #expect(passes > 10 && passes < 55)
        #expect(chosen.map(\.id) == JudgeSampling.select(items, spec: spec, passed: \.passed, id: \.id).map(\.id))
    }

    @Test func rejectsBadSpecs() {
        #expect(throws: EvalError.self) { try JudgeSampling.parse("some") }
        #expect(throws: EvalError.self) { try JudgeSampling.parse("fails+200") }
        #expect((try? JudgeSampling.parse("all")) == .all)
    }
}
