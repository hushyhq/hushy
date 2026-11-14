import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

/// The whole-dictation scorer (`LongDictationScorer`) and its invented dev set (`Evals/long-dictation-dev.jsonl`). No model:
/// every output here is written by hand, so these pin what each fault kind counts and what it does not.
@Suite("Long dictation scorer")
struct LongDictationScorerTests {
    private func makeCase(
        spoken: String = "so we like should ship on friday no wait monday",
        reference: String = "We should ship on Monday. Then we test.\n\nAfter that, we celebrate.",
        mustKeep: [String] = [], fillers: [LongDictationCase.Filler] = [], repairs: [LongDictationCase.Repair] = [],
        breaks: [[String]] = []
    ) -> LongDictationCase {
        LongDictationCase(id: "t", domain: "test", spoken: spoken, reference: reference, mustKeep: mustKeep, fillers: fillers,
                          repairs: repairs, breaks: breaks)
    }

    private func faults(_ item: LongDictationCase, _ output: String, groups: [String] = [], continues: [Bool] = []) -> LongDictationScorer.Faults {
        LongDictationScorer.score(item, output: output, groupTexts: groups, groupContinues: continues).faults
    }

    // MARK: The dev set

    private var devSetPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Evals/long-dictation-dev.jsonl").path
    }

    @Test("the dev set has 36 sound, invented dictations of 100 to 140 words", .enabled(if: PrivateFiles.present("Evals/long-dictation-dev.jsonl"), "needs a private file: Evals/long-dictation-dev.jsonl"))
    func devSetIsSound() throws {
        let cases = try LongDictationCase.load(devSetPath)
        #expect(cases.count == 36)
        #expect(Set(cases.map(\.id)).count == 36)
        let problems = cases.flatMap { $0.problems() }
        #expect(problems.isEmpty, "\(problems.prefix(8))")
        #expect(cases.allSatisfy { $0.reference.contains("\n\n") || $0.breaks.count > 0 })
        // The kinds of speech the brief asks for are all present across the set.
        let kinds = Set(cases.flatMap { $0.repairs.map(\.kind) })
        #expect(kinds == ["restart", "false_start", "correction"])
    }

    @Test("the reference itself scores clean, so the scorer does not punish text that reads as typed", .enabled(if: PrivateFiles.present("Evals/long-dictation-dev.jsonl"), "needs a private file: Evals/long-dictation-dev.jsonl"))
    func referenceScoresClean() throws {
        let cases = try LongDictationCase.load(devSetPath)
        var bad: [String] = []
        for item in cases {
            let groups = TextSegmentation.groups(item.spoken)
            let result = LongDictationScorer.score(item, output: item.reference, groupTexts: groups.map(\.text), groupContinues: groups.map(\.continuesSentence))
            if !result.faults.isClean { bad.append("\(item.id): \(result.faults)") }
        }
        #expect(bad.isEmpty, "\(bad.prefix(3))")
    }

    @Test("the spoken text itself scores every planted fault, so the scorer sees what it is meant to see", .enabled(if: PrivateFiles.present("Evals/long-dictation-dev.jsonl"), "needs a private file: Evals/long-dictation-dev.jsonl"))
    func spokenScoresDirty() throws {
        let cases = try LongDictationCase.load(devSetPath)
        for item in cases {
            let groups = TextSegmentation.groups(item.spoken)
            let f = LongDictationScorer.score(item, output: item.spoken, groupTexts: groups.map(\.text), groupContinues: groups.map(\.continuesSentence)).faults
            #expect(f.filler == item.fillers.reduce(0) { $0 + $1.hedge }, "\(item.id) fillers")
            #expect(f.restart + f.falseStart + f.correction == item.repairs.count, "\(item.id) repairs")
            #expect(f.runOn > 0, "\(item.id) run-on")
        }
    }

    // MARK: Words

    @Test("words are compared after contractions and numbers are written one way")
    func canonicalWords() {
        #expect(LongDictationScorer.tokens("I can't, won't and don't") == ["i", "can", "not", "will", "not", "and", "do", "not"])
        #expect(LongDictationScorer.tokens("It cannot rain") == LongDictationScorer.tokens("It can not rain"))
        #expect(LongDictationScorer.tokens("sixty percent") == LongDictationScorer.tokens("60%"))
        #expect(LongDictationScorer.tokens("$4,200") == LongDictationScorer.tokens("4200"))
        #expect(LongDictationScorer.tokens("from 2022") == ["from", "2022"])
        #expect(LongDictationScorer.tokens("not one, one the day") == ["not", "one", "one", "the", "day"])
        // Digits written apart are one number, and a hyphen joins words of one number.
        #expect(LongDictationScorer.tokens("555-0142") == LongDictationScorer.tokens("5-5-5-0-1-4-2"))
        #expect(LongDictationScorer.tokens("at 7:15") == LongDictationScorer.tokens("at seven fifteen"))
        #expect(LongDictationScorer.tokens("twenty-eight ounces") == LongDictationScorer.tokens("28 ounces"))
        #expect(LongDictationScorer.tokens("192.168.1.44") == LongDictationScorer.tokens("192 168 1 44"))
        #expect(LongDictationScorer.tokens("simmer for twenty-five thirty") != LongDictationScorer.tokens("simmer for thirty"))
    }

    // MARK: Layout faults

    @Test("a filler left in counts up to the hedges the key names; a real use of the word never counts")
    func fillers() {
        let item = makeCase(fillers: [.init(p: "like", hedge: 2, legit: 1)])
        #expect(faults(item, "We like it. It is like a plan. I like it like this.").filler == 2)
        #expect(faults(item, "I like it. It is a plan.").filler == 0)
        #expect(faults(makeCase(fillers: [.init(p: "you know", hedge: 1, legit: 0)]), "We, you know, ship.").filler == 1)
    }

    @Test("an abandoned phrase left in is one fault of its own kind; either spelling of a correction counts once")
    func repairs() {
        let item = makeCase(repairs: [.init(kind: "restart", abandoned: "we should we should"), .init(kind: "correction", abandoned: "friday|no wait")])
        #expect(faults(item, "We should we should ship on Friday, no wait, Monday.").restart == 1)
        #expect(faults(item, "We should we should ship on Friday, no wait, Monday.").correction == 1)
        let clean = faults(item, "We should ship on Monday.")
        #expect(clean.restart == 0 && clean.correction == 0)
        #expect(faults(makeCase(repairs: [.init(kind: "false_start", abandoned: "i was going to")]), "I was going to say it.").falseStart == 1)
    }

    @Test("a run-on is a long sentence, or a place the key says needs a sentence end that has none")
    func runOns() {
        let item = makeCase(breaks: [["ship on friday", "then we test"]])
        #expect(faults(item, "We ship on Friday, and then we test it all.").runOn == 1)
        #expect(faults(item, "We ship on Friday, and then we test it all.").breaksMissing == 1)
        #expect(faults(item, "We ship on Friday. Then we test it all.").runOn == 0)
        #expect(faults(item, "We ship on Friday.\n\nThen we test it all.").runOn == 0)
        #expect(faults(item, "Nothing like it at all.").breaksUnlocated == 1)
        let long = Array(repeating: "word", count: 45).joined(separator: " ") + "."
        #expect(faults(makeCase(), long).runOn == 1)
        #expect(faults(makeCase(), long).longestSentenceWords == 45)
    }

    @Test("a paragraph break is missing when the reference has more paragraphs than the output")
    func paragraphs() {
        let item = makeCase()
        #expect(faults(item, "One. Two.").missingParagraph == 1)
        #expect(faults(item, "One.\n\nTwo.").missingParagraph == 0)
        #expect(faults(item, "One.\n\nTwo.\n\nThree.\n\nFour.").extraParagraphs == 2)
        #expect(faults(item, "One.\nTwo.").missingParagraph == 1)
    }

    @Test("a bad join is a sentence end where the reference goes on, after a word that cannot end a sentence, or in lowercase")
    func badJoins() {
        let item = makeCase(spoken: "we moved the launch to friday because the vendor was late and then we told the team", reference: "We moved the launch to Friday because the vendor was late and then we told the team.")
        let groups = ["we moved the launch to friday", "because the vendor was late", "and then we told the team"]
        let continues = [false, true, true]
        // A sentence end inserted where the thought goes on.
        #expect(faults(item, "We moved the launch to Friday. Because the vendor was late and then we told the team.", groups: groups, continues: continues).badJoin == 1)
        // Stopping on a word that cannot end a sentence.
        #expect(faults(item, "We moved the launch to. Because the vendor was late, and then we told the team.", groups: groups, continues: continues).badJoin == 1)
        // The reading the reference has.
        #expect(faults(item, "We moved the launch to Friday because the vendor was late, and then we told the team.", groups: groups, continues: continues).badJoin == 0)
        // The group's first words are gone: not placed, not a fault.
        let gone = faults(item, "We moved the launch to Friday and told the team.", groups: groups, continues: continues)
        #expect(gone.badJoin == 0 && gone.seamsUnlocated == 2)
    }

    // MARK: Meaning faults

    @Test("a must-keep item that is missing is a meaning fault, with either spelling accepted")
    func missingItems() {
        let item = makeCase(mustKeep: ["priya", "forty|40", "not ready"])
        #expect(faults(item, "Priya says 40 are not ready.").missingItems == 0)
        #expect(faults(item, "Priya says forty are ready.").missingItems == 1)
        #expect(faults(item, "She says it is ready.").missingItems == 3)
    }

    @Test("a negation added or taken away is a meaning fault, and a left-in correction cue is not counted as an added negation")
    func negations() {
        let item = makeCase(reference: "We are not ready. It will ship Monday.", mustKeep: [])
        #expect(faults(item, "We are ready. It will ship Monday.").negationRemoved == 1)
        #expect(faults(item, "We are not ready. It will not ship Monday.").negationAdded == 1)
        #expect(faults(item, "We are not ready. It will ship Monday.").meaning == 0)
        // "no wait" left in the text: one correction fault, not also an added negation.
        let withCue = makeCase(reference: "It will ship Monday.", repairs: [.init(kind: "correction", abandoned: "no wait")])
        let cue = faults(withCue, "It will ship Friday, no wait, Monday.")
        #expect(cue.correction == 1 && cue.negationAdded == 0)
        // A removed negation that a missing must-keep item already counts is not counted twice.
        let negated = makeCase(reference: "We are not ready.", mustKeep: ["not ready"])
        #expect(faults(negated, "We are ready.").meaning == 1)
    }

    @Test("a number absent from the intended reference is a meaning fault across spoken and written forms")
    func numbers() {
        let item = makeCase(spoken: "it costs forty two dollars", reference: "It costs $42.", mustKeep: ["42"])
        #expect(faults(item, "It costs $42.").numberChanged == 0)
        #expect(faults(item, "It costs $24.").numberChanged == 1)
        #expect(faults(item, "It costs forty two dollars.").numberChanged == 0)
        let corrected = makeCase(spoken: "ship five boxes no wait seven boxes", reference: "Ship seven boxes.")
        #expect(faults(corrected, "Ship five boxes.").numberChanged == 1)
        #expect(faults(corrected, "Ship 7 boxes.").numberChanged == 0)
        let ordinal = makeCase(spoken: "take the third exit", reference: "Take the third exit.")
        #expect(faults(ordinal, "Take the 3rd exit.").numberChanged == 0)
        let ninth = makeCase(spoken: "take the ninth exit", reference: "Take the ninth exit.")
        #expect(faults(ninth, "Take the 9th exit.").numberChanged == 0)
        #expect(faults(makeCase(reference: "Take the 10th exit."), "Take the ninth exit.").numberChanged == 1)
        let time = makeCase(spoken: "meet at seven fifteen", reference: "Meet at 7:15.")
        #expect(faults(time, "Meet at seven fifteen.").numberChanged == 0)
    }

    @Test("two dictations joined for the length probe keep both answer keys", .enabled(if: PrivateFiles.present("Evals/long-dictation-dev.jsonl"), "needs a private file: Evals/long-dictation-dev.jsonl"))
    func pairs() throws {
        let cases = try LongDictationCase.load(devSetPath)
        let pair = cases[0].followed(by: cases[1])
        #expect(pair.id == "ld-01+ld-02")
        #expect(pair.mustKeep.count == cases[0].mustKeep.count + cases[1].mustKeep.count)
        #expect(pair.reference.contains("\n\n"))
        #expect(LongDictationRunner.pairedUp(cases).count == 18)
        // A filler phrase used in both halves is one entry with the counts added, so it is not counted twice.
        let like = pair.fillers.filter { $0.p == "like" }
        #expect(like.count <= 1)
        #expect(pair.problems(wordRange: 200...300).isEmpty)
    }
}
