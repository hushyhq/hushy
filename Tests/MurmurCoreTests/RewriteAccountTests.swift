import Testing
@testable import MurmurCore

/// `RewriteAccount`: how much of a text is made of its source, in counts. Invented text only.
@Suite struct RewriteAccountTests {
    @Test func aTextMadeOfItsSourceIsAllInOrder() {
        let account = RewriteAccount.measure("Send the report on Friday.", against: "send the report on friday")
        #expect(account.words == 5)
        #expect(account.inOrder == 5)
        #expect(account.added == 0)
        #expect(account.share == 100)
    }

    @Test func removedFillersAndRestartsCostNothing() {
        let account = RewriteAccount.measure(
            "I think we should move the review.", against: "um so I I think we should we should move the the review")
        #expect(account.added == 0)
        #expect(account.inOrder == 7)
    }

    @Test func aReplyIsNotMadeOfItsSource() {
        let account = RewriteAccount.measure("Sorry, that makes no sense here.", against: "could you carry these for me")
        #expect(account.inOrder == 0)
        #expect(account.elsewhere == 0)
        #expect(account.added == 6)
        #expect(account.share == 0)
    }

    @Test func aRepairedSpellingAndAnInflectionAreTheSameWord() {
        let account = RewriteAccount.measure("She shipped the calender updates.", against: "she ship the calendar update")
        #expect(account.added == 0)
        #expect(account.inOrder == 5)
    }

    @Test func wordsWrittenTogetherOrApartAreAccountedFor() {
        #expect(RewriteAccount.measure("Something for the website", against: "some thing for the web site").added == 0)
        #expect(RewriteAccount.measure("some thing for the web site", against: "something for the website").added == 0)
    }

    @Test func aContractionAndItsLongFormAreAccountedFor() {
        #expect(RewriteAccount.measure("I don't think you're late", against: "i do not think you are late").added == 0)
        #expect(RewriteAccount.measure("I do not think you are late", against: "i don't think you're late").added == 0)
    }

    @Test func aFullClauseReversalIsStillARewrite() {
        // Two whole clauses swapped, nothing new. Putting a sentence in order is what a rewrite does.
        let account = RewriteAccount.measure(
            "the ferry leaves before noon and the harbour office opens at nine",
            against: "the harbour office opens at nine and the ferry leaves before noon")
        #expect(account.added == 0)
        #expect(account.elsewhere > 0)
        #expect(account.inOrder > 0)
        #expect(account.isRewrite)
    }

    @Test func aRepeatedContentWordPaddedIntoAReplyIsStillRefused() {
        // "no thanks" is a reply. "report" is only repeated so the answer looks made of the source.
        // One copy can stand in order; the extras are not a second copy of what was said.
        let account = RewriteAccount.measure(
            "no thanks report report report report",
            against: "send the quarterly report")
        #expect(account.inOrder > 0)
        #expect(account.elsewhere > 0)
        #expect(!account.isRewrite)
    }

    @Test func aMovedClauseIsElsewhereNotNew() {
        let account = RewriteAccount.measure("If the tests pass, we ship tomorrow.", against: "we ship tomorrow if the tests pass")
        #expect(account.added == 0)
        #expect(account.elsewhere > 0)
        #expect(account.inOrder + account.elsewhere == 7)
    }

    @Test func aReorderedRewriteWithOneNewWordPasses() {
        // The counts of a real dictation refused on 2026-10-14: 38 letters kept in order, 10 moved, 8 new.
        let account = RewriteAccount(words: 18, letters: 56, inOrder: 13, inOrderLetters: 38, elsewhere: 4, elsewhereLetters: 10)
        #expect(account.isRewrite)
    }

    @Test func aReplyMadeOfTheQuestionsWordsWithThePronounsTurnedIsStillRefused() {
        #expect(!RewriteAccount.measure("I am able to help you.", against: "are you able to help me").isRewrite)
        #expect(!RewriteAccount.measure("Yes, I can hear you.", against: "can you hear me").isRewrite)
    }

    @Test func aWordFromTheSecondSourceCountsButOrderIsTheFirstSources() {
        let account = RewriteAccount.measure("Meet at 3 tomorrow", against: "meet at three tomorrow", also: "meet at 3 tomorrow")
        #expect(account.added == 0)
    }

    @Test func lettersWeighTheShare() {
        // "understand" is new and outweighs the three short words the source has.
        let account = RewriteAccount.measure("I do not understand", against: "do not i")
        #expect(account.added == 1)
        #expect(account.share < 50)
    }

    @Test func emptyTextsDoNotTrap() {
        #expect(RewriteAccount.measure("", against: "anything at all").share == 100)
        let nothing = RewriteAccount.measure("Hello there", against: "")
        #expect(nothing.added == 2)
        #expect(nothing.share == 0)
    }

    @Test func aLongTextIsMeasuredInsideTheBand() {
        let sentence = "the harbour office opens at nine and the ferry leaves before noon "
        let source = String(repeating: sentence, count: 90)
        let account = RewriteAccount.measure(source, against: source)
        #expect(account.words == 1080)
        #expect(account.inOrder == 1080)
    }
}

/// `RewriteDistance`: the per-dictation log line. Counts and fixed words only.
@Suite struct RewriteDistanceTests {
    private func trace(_ words: Int, _ outcome: ModelOutcome) -> GroupTrace {
        GroupTrace(words: words, outcome: outcome, guardCode: nil, edited: outcome == .used, modelMs: nil)
    }

    @Test func theLineCountsWordsAndNamesTheModelsText() {
        let distance = RewriteDistance(
            raw: "can you move the call to friday", text: "Can you move the call to Thursday?",
            groups: [trace(7, .used)], asHeard: false)
        #expect(distance.line == "rewrite heard=7 draft=7 delivered=7 in-order=6 elsewhere=0 new=1 share=70 text=model groups=1 model=1")
    }

    @Test func theRulesDraftAndAsHeardAreToldApart() {
        let rules = RewriteDistance(raw: "see you at noon", text: "See you at noon.", groups: [trace(4, .rejectedByGuard)], asHeard: false)
        #expect(rules.delivered == .rules)
        let asHeard = RewriteDistance(raw: "see you at noon", text: "See you at noon.", groups: [trace(4, .timeout)], asHeard: true)
        #expect(asHeard.delivered == .asHeard)
        #expect(asHeard.line.hasSuffix("share=100 text=as-heard groups=1 model=0"))
    }

    @Test func aLongDictationWithBothKindsIsMixed() {
        let distance = RewriteDistance(
            raw: "first part second part", text: "First part. Second part.",
            groups: [trace(2, .used), trace(2, .timeout)], asHeard: true, usedMode: true)
        #expect(distance.delivered == .mixed)
        #expect(distance.line.hasSuffix("text=mixed groups=2 model=1 mode=1"))
    }

    @Test func theLineHoldsNoWordOfTheDictation() {
        let raw = "walnut orchard ledger"
        let line = RewriteDistance(raw: raw, text: "Walnut orchard ledger.", groups: [trace(3, .used)], asHeard: false).line
        for word in raw.split(separator: " ") { #expect(!line.contains(word)) }
    }
}
