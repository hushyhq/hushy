import Foundation
import Testing

@testable import murmur_eval

/// Scoring logic for the held-out reformat eval (`ReformatChecks`). These never call a model:
/// they pin down normalisation, `mustEqualInput`, negation detection and the pass/fail rules so
/// a change to the scorer can't silently move the baseline.
@Suite("Reformat eval checks")
struct ReformatChecksTests {
    private func makeCase(
        input: String, negative: Bool = false, mustEqualInput: Bool? = nil, bucket: String? = nil,
        expectation: ReformatChecks.Expectation
    ) throws -> ReformatChecks.Case {
        let levels: [String: Any] = ["clean": expectationJSON(expectation), "polished": expectationJSON(expectation)]
        var object: [String: Any] = [
            "id": "t", "category": "test", "lengthBucket": bucket ?? ReformatChecks.lengthBucket(for: input),
            "negative": negative, "input": input, "levels": levels,
        ]
        if let mustEqualInput { object["mustEqualInput"] = mustEqualInput }
        return try JSONDecoder().decode(ReformatChecks.Case.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func expectationJSON(_ e: ReformatChecks.Expectation) -> [String: Any] {
        var object: [String: Any] = ["reference": e.reference]
        if let v = e.mustContain { object["mustContain"] = v }
        if let v = e.mustNotContain { object["mustNotContain"] = v }
        if let v = e.maxOccurrences { object["maxOccurrences"] = v }
        if let v = e.minWords { object["minWords"] = v }
        if let v = e.maxWords { object["maxWords"] = v }
        if let v = e.minQuestionMarks { object["minQuestionMarks"] = v }
        if let v = e.minSentences { object["minSentences"] = v }
        return object
    }

    private func expectation(
        _ reference: String, contain: [String]? = nil, notContain: [String]? = nil, max: [String: Int]? = nil,
        minWords: Int? = nil, maxWords: Int? = nil, questions: Int? = nil, sentences: Int? = nil
    ) -> ReformatChecks.Expectation {
        ReformatChecks.Expectation(
            reference: reference, mustContain: contain, mustNotContain: notContain, maxOccurrences: max,
            minWords: minWords, maxWords: maxWords, minQuestionMarks: questions, minSentences: sentences)
    }

    // MARK: Normalisation

    @Test func normalisationIgnoresCasePunctuationAndThousandsSeparators() {
        #expect(ReformatChecks.words("The budget is $45,000 — OK?") == ["the", "budget", "is", "45000", "ok"])
        #expect(ReformatChecks.words("fourteen days, forty users") == ["14", "days", "40", "users"])
        #expect(ReformatChecks.words("a full-screen follow-up") == ["a", "full", "screen", "follow", "up"])
        #expect(ReformatChecks.words("don’t") == ["don't"])
    }

    @Test func compactFormIgnoresWhitespaceButNotRepeats() {
        #expect(ReformatChecks.unchanged(input: "meet at 3pm", output: "Meet at 3 PM."))
        #expect(ReformatChecks.unchanged(input: "the demo went so so", output: "The demo went so-so."))
        #expect(!ReformatChecks.unchanged(input: "she had had enough", output: "She had enough."))
        #expect(!ReformatChecks.unchanged(input: "it was very very cold", output: "It was very cold."))
    }

    @Test func phraseMatchingIsWordAligned() {
        #expect(ReformatChecks.contains("the the", in: "Fix the the bug"))
        #expect(!ReformatChecks.contains("the the", in: "Fix the theme"))
        #expect(!ReformatChecks.contains("w", in: "We saw the window"))
        #expect(ReformatChecks.contains("w", in: "in the w in the sentence"))
        #expect(ReformatChecks.occurrences(of: "actually", in: "Actually, it actually works, actually.") == 3)
        #expect(ReformatChecks.occurrences(of: "it's it's", in: "it's it's it's") == 1)
    }

    // MARK: Negation

    @Test func negationCountsExplicitNegatorsButNotBareNo() {
        #expect(ReformatChecks.negationCount("I don't think it won't work, never.") == 3)
        #expect(ReformatChecks.negationCount("We did not change it; nobody asked.") == 2)
        #expect(ReformatChecks.negationCount("Yeah no, meet at 4, no, 5.") == 0)
        #expect(ReformatChecks.negationCount("It cannot be empty") == 1)
    }

    @Test func droppedNegationIsFlagged() throws {
        let e = expectation("We should never load the whole file.", contain: ["whole file"])
        let item = try makeCase(input: "we should never like load the whole file", expectation: e)
        let outcome = ReformatChecks.evaluate(item, expectation: e, output: "We should load the whole file.")
        #expect(outcome.negationLost)
        #expect(!outcome.contentPreserved)
        #expect(!outcome.passed)
    }

    @Test func inventedNegationIsFlagged() throws {
        let e = expectation("Ship it on Friday.")
        let item = try makeCase(input: "ship it on friday", expectation: e)
        let outcome = ReformatChecks.evaluate(item, expectation: e, output: "Don't ship it on Friday.")
        #expect(outcome.negationAdded)
        #expect(!outcome.passed)
    }

    @Test func keptDuplicateNegationIsNotAFlip() throws {
        let e = expectation("I'm not sure.")
        let item = try makeCase(input: "i'm not i'm not sure", expectation: e)
        let outcome = ReformatChecks.evaluate(item, expectation: e, output: "I'm not, I'm not sure.")
        #expect(!outcome.negationLost)
        #expect(!outcome.negationAdded)
    }

    // MARK: mustEqualInput

    @Test func mustEqualInputPassesOnPunctuationOnlyChanges() throws {
        let e = expectation("The demo went so-so, but they asked for a follow-up.")
        let item = try makeCase(input: "the demo went so so but they asked for a follow up", negative: true, mustEqualInput: true, expectation: e)
        let outcome = ReformatChecks.evaluate(item, expectation: e, output: "The demo went so-so, but they asked for a follow-up.")
        #expect(outcome.unchanged)
        #expect(outcome.passed)
    }

    @Test func mustEqualInputFailsWhenALegitimateRepeatIsRemoved() throws {
        let e = expectation("She had had the same problem.", contain: ["had had"])
        let item = try makeCase(input: "She had had the same problem.", negative: true, mustEqualInput: true, expectation: e)
        let outcome = ReformatChecks.evaluate(item, expectation: e, output: "She had the same problem.")
        #expect(!outcome.unchanged)
        #expect(outcome.failureReasons.contains("changed a must-stay-unchanged input"))
        #expect(!outcome.passed)
    }

    // MARK: Other checks

    @Test func disfluencyAndOccurrenceLimits() throws {
        let e = expectation("I think we should move it.", notContain: ["basically", "the the"], max: ["actually": 1])
        let item = try makeCase(input: "actually i think we should actually basically move the the it", expectation: e)
        let outcome = ReformatChecks.evaluate(item, expectation: e, output: "Actually I think we should actually move the the it.")
        #expect(outcome.disfluencyTargets == 3)
        #expect(outcome.leaked == ["the the", "actually×2"])
        #expect(outcome.disfluencyRemoved == 1)
    }

    @Test func wordBoundsQuestionsAndSentences() throws {
        let e = expectation("Is it ready? Ship it.", minWords: 3, maxWords: 6, questions: 1, sentences: 2)
        let item = try makeCase(input: "is it ready ship it", expectation: e)
        let bad = ReformatChecks.evaluate(item, expectation: e, output: "is it ready ship it")
        #expect(bad.questionShortfall)
        #expect(bad.sentenceShortfall)
        let good = ReformatChecks.evaluate(item, expectation: e, output: "Is it ready? Ship it.")
        #expect(good.passed)
        #expect(good.similarity == 1)
        let long = ReformatChecks.evaluate(item, expectation: e, output: "Is it ready yet or not? Ship it now.")
        #expect(long.wordBoundsViolation != nil)
    }

    @Test func sentenceCountIgnoresDecimals() {
        #expect(ReformatChecks.sentenceCount("Version 2.5 is out. Try it!") == 2)
    }

    // MARK: Golden-set integrity

    @Test func lengthBuckets() {
        #expect(ReformatChecks.lengthBucket(for: "one two three") == "short")
        #expect(ReformatChecks.lengthBucket(for: Array(repeating: "w", count: 10).joined(separator: " ")) == "medium")
        #expect(ReformatChecks.lengthBucket(for: Array(repeating: "w", count: 31).joined(separator: " ")) == "long")
    }

    @Test func validationCatchesStructuralProblems() throws {
        let e = expectation("Hi.")
        let wrongBucket = try makeCase(input: "hi there", bucket: "long", expectation: e)
        let negativeWithoutFlag = try makeCase(input: "hi there", negative: true, expectation: e)
        let problems = ReformatChecks.validate([wrongBucket, negativeWithoutFlag])
        #expect(problems.contains { $0.contains("duplicate id") })
        #expect(problems.contains { $0.contains("lengthBucket") })
        #expect(problems.contains { $0.contains("mustEqualInput") })
    }

    @Test(.enabled(if: PrivateFiles.present("Evals/reformat-golden.json"), "needs a private file: Evals/reformat-golden.json")) func shippedGoldenSetIsValidAndLargeEnough() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Evals/reformat-golden.json")
        let cases = try JSONDecoder().decode([ReformatChecks.Case].self, from: Data(contentsOf: url))
        #expect(ReformatChecks.validate(cases).isEmpty)
        #expect(cases.count >= 60)
        #expect(cases.filter(\.isNegative).count >= 20)
        #expect(Set(cases.map(\.lengthBucket)) == ["short", "medium", "long"])
        // Every reference must satisfy its own level's checks — a scorer sanity check, not a model test.
        for item in cases {
            for (_, expectation) in item.levels {
                let outcome = ReformatChecks.evaluate(item, expectation: expectation, output: expectation.reference)
                #expect(outcome.passed, "\(item.id) reference fails its own checks: \(outcome.failureReasons)")
            }
        }
    }
}
