import Foundation
import Testing
@testable import MurmurCore

/// Three checks that threw away a correct rewrite, or let a wrong one through, each fixed at its source.
@Suite("Guard false alarms", .timeLimit(.minutes(2)), .serialized)
struct GuardFalseAlarmTests {
    // MARK: A filler the opening is built on is not what the opening says

    @Test("a filler said at the start of two clauses can be removed from both")
    func fillerOpeningCanGo() {
        let draft = "Alright so the answer is whoever wrote like the draft and we should you know keep like the review under an hour."
        let answer = "Alright so the answer is whoever wrote the draft and we should keep the review under an hour."
        for grammarRepair in [true, false] {
            let reason = DisfluencyOnlyGuard.violation(answer: answer, raw: draft.lowercased(), draft: draft, grammarRepair: grammarRepair)
            #expect(reason == nil, "\(grammarRepair) \(String(describing: reason))")
        }
    }

    @Test("an opening with content words is still seen to be lost")
    func contentOpeningIsStillCounted() {
        let draft = ["we", "should", "move", "the", "tuesday", "sync", "we", "should", "move", "the", "friday", "retro", "and", "book", "the", "room"]
        let answer = ["book", "the", "room"]
        #expect(RepeatedFrame.violation(draftWords: draft, answerWords: answer) != nil)
    }

    // MARK: A verb that takes back nothing named before is a request

    @Test("a verb whose object was never named is the speaker's request, even after a purpose phrase")
    func unnamedObjectIsARequest() {
        #expect(RetractionGuard.violation(
            answer: "Can we drop the second vendor to cut costs?", draft: "Can we to cut costs actually drop the second vendor?") == nil)
        #expect(RetractionGuard.violation(
            answer: "We should cancel the Friday retro to save time.", draft: "We should to save time actually cancel the Friday retro.") == nil)
    }

    @Test("a verb that takes back an item named before is still a retraction, whatever stands in front of it")
    func namedObjectIsStillARetraction() {
        // Named before, with a subject and a modal earlier in the clause.
        #expect(RetractionGuard.violation(
            answer: "We need to bring pens and pencils.", draft: "we need to bring pens and pencils actually forget the pencils") != nil)
        // A three-letter item, no subject in front.
        #expect(RetractionGuard.violation(
            answer: "Bring cake and pie.", draft: "bring cake and pie actually forget the pie") != nil)
    }

    // MARK: A word that ends one sentence and opens the next is not a stutter

    @Test("the words that end a sentence and open the next are found, one article or filler aside")
    func boundaryWordsAreFound() {
        #expect(BoundaryRepeatGuard.repeatedWords(in: "Please check the budget. Budget numbers look off.") == ["budget"])
        #expect(BoundaryRepeatGuard.repeatedWords(in: "Dana will send the report. The report is late again.") == ["report"])
        // No sentence end the recogniser marked, a filler word, a short word, a different word: nothing to read.
        #expect(BoundaryRepeatGuard.repeatedWords(in: "please check the budget budget numbers look off").isEmpty)
        #expect(BoundaryRepeatGuard.repeatedWords(in: "I like it. It is fine.").isEmpty)
        #expect(BoundaryRepeatGuard.repeatedWords(in: "Please check the budget. Costs look off.").isEmpty)
    }

    @Test("an answer that loses the word at both ends fuses two sentences and is refused")
    func fusedSentencesAreRefused() {
        let draft = "Please check the budget. Budget numbers look off after the audit."
        let fused = "Please check numbers look off after the audit."
        let reason = BoundaryRepeatGuard.violation(answer: fused, draft: draft)
        #expect(reason.map { GuardCode(reason: $0) } == .droppedContentWords, "\(String(describing: reason))")
        // Both sentences kept, joined, or reworded around the word: fine.
        #expect(BoundaryRepeatGuard.violation(answer: draft, draft: draft) == nil)
        #expect(BoundaryRepeatGuard.violation(answer: "Please check the budget; numbers look off after the audit.", draft: draft) == nil)
        #expect(BoundaryRepeatGuard.violation(answer: "Please check the budget, whose numbers look off after the audit.", draft: draft) == nil)
        // A word corrected to a near spelling at both places is kept.
        #expect(BoundaryRepeatGuard.violation(
            answer: "Please check the reminder. Reminder numbers look off.", draft: "Please check the remainder. Remainder numbers look off.") == nil)
    }

    @Test("a fused rewrite of two sentences that share a word falls back to the plain text")
    func fusedRewriteFallsBack() async {
        let spoken = "Please check the budget. Budget numbers look off after the audit."
        let cleaner = SmartCleaner(
            budget: .seconds(6), correctionBudget: .seconds(6), polishedBudget: .seconds(6), segmentBudget: .seconds(6),
            model: MarkedEditModel { _ in "Please check numbers look off after the audit." }, health: ModelHealth())
        let output = await cleaner.clean(spoken, options: CleanupOptions(level: .polished))
        #expect(output.groups.first?.outcome == .rejectedByGuard, "\(output.text)")
        #expect(output.groups.first?.guardCode == .droppedContentWords)
        #expect(output.text.contains("Budget numbers"), "\(output.text)")
    }

    @Test("a rewrite that keeps both sentences is used")
    func keptSentencesAreUsed() async {
        let spoken = "Please check the budget. Budget numbers look off after the audit."
        let cleaner = SmartCleaner(
            budget: .seconds(6), correctionBudget: .seconds(6), polishedBudget: .seconds(6), segmentBudget: .seconds(6),
            model: MarkedEditModel { $0 }, health: ModelHealth())
        let output = await cleaner.clean(spoken, options: CleanupOptions(level: .polished))
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
        #expect(output.text.contains("budget. Budget numbers"), "\(output.text)")
    }
}
