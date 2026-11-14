import Testing
@testable import MurmurCore

@Suite("A plain negation is not a self-correction")
struct PlainNegationCueTests {
    private let kite = "I am gonna move the paper kite and we do not need the bell"

    private func group(_ answer: String, raw: String) -> SmartCleaner.Refinement {
        OutputGuard.check(answer, raw: raw, draft: raw, lowConfidenceWords: nil, profile: .disfluencyOnly)
    }

    @Test("a noun lost before a plain negation is a dropped content word",
          arguments: [
            ("I am gonna move the paper kite and we do not need the bell", "I am gonna move the paper and we do not need the bell."),
            ("I am gonna move the paper kite and there is no bell", "I am gonna move the paper and there is no bell."),
            ("I am gonna move the paper kite and we never need the bell", "I am gonna move the paper and we never need the bell."),
            ("send the blue folder to marcus and he should not forward it", "Send the folder to Marcus and he should not forward it."),
          ])
    func groupPathObjects(raw: String, answer: String) {
        guard case .rejected(let reason) = group(answer, raw: raw) else {
            Issue.record("expected the dropped word to be refused for: \(raw)")
            return
        }
        #expect(reason.hasPrefix("dropped content words"))
    }

    @Test("the whole-transcript model's hole before a plain negation is put back")
    func intentPathRestores() {
        let verdict = IntentOutputGuard.check("I am gonna move the paper and we do not need the bell.", raw: kite)
        guard case .accepted(let text, _) = verdict else {
            Issue.record("expected the repaired answer, got \(verdict)")
            return
        }
        #expect(text.contains("paper kite"))
        #expect(DroppedContent.lost(answer: "I am gonna move the paper and we do not need the bell.", raw: kite) == ["kite"])
    }

    @Test("a spoken correction still takes its words back",
          arguments: [
            ("send it on tuesday no wednesday to the team", "Send it on Wednesday to the team."),
            ("put the red box not the blue box on the shelf", "Put the red box on the shelf."),
            ("book the dentist for tuesday I mean wednesday", "Book the dentist for Wednesday."),
            ("we should not meet on monday sorry on friday", "We should meet on Friday."),
          ])
    func correctionStillExempt(raw: String, answer: String) {
        let verdict = group(answer, raw: raw)
        if case .rejected(let reason) = verdict { #expect(!reason.hasPrefix("dropped content words"), "\(reason)") }
    }

    @Test("cue detection reads the word before the negation")
    func cueIndices() {
        let said = EvalMetrics.normalizedWords(kite)
        #expect(DisfluencyOnlyGuard.cueIndices(in: said).isEmpty)
        let correction = EvalMetrics.normalizedWords("put the red box not the blue box")
        #expect(DisfluencyOnlyGuard.cueIndices(in: correction) == [4])
    }
}
