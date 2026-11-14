import Testing
@testable import MurmurCore

/// Rules bugs found by the fine-tune data builders (2026-09-28): a correction cue over-triggering
/// on an apology or a discourse marker, and money ITN on digits plus a scale word.
@Suite("Correction cues that are not corrections, and digit-scale money")
struct CueOverTriggerTests {
    let cleaner = TextCleaner()

    @Test("an apology after a vocative name keeps the name and the apology", arguments: [
        ("Elena, sorry I'm late to the call, just start without me.", "Elena, sorry I'm late to the call, just start without me."),
        ("Raj, sorry I've been slow on this, I'll reply tonight.", "Raj, sorry I've been slow on this, I'll reply tonight."),
        ("Dana, sorry I'll miss the standup tomorrow.", "Dana, sorry I'll miss the standup tomorrow."),
    ])
    func apologyAfterVocative(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("a name corrected with sorry still resolves", arguments: [
        ("Send it to John, sorry, Sarah.", "Send it to Sarah."),
        ("Send the invite to Maria, sorry, Mark.", "Send the invite to Mark."),
    ])
    func nameRepairStillResolves(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("actually opening a new clause is a discourse marker, not a head-noun correction", arguments: [
        ("I tested both algorithms on the dataset, actually, the second one runs faster.",
         "I tested both algorithms on the dataset, actually, the second one runs faster."),
        ("We looked at the old laptop, actually, the new one handled the load fine.",
         "We looked at the old laptop, actually, the new one handled the load fine."),
    ])
    func actuallyOpensClause(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("a real head-noun correction still keeps the noun", arguments: [
        ("Download the online maps, no, the offline ones.", "Download the offline maps."),
        ("Send the draft, actually, the final one.", "Send the final draft."),
    ])
    func headNounStillResolves(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("digits plus a scale word plus dollars become one amount", arguments: [
        ("The budget is 18 thousand dollars.", "The budget is $18,000."),
        ("We raised 2 million dollars.", "We raised $2,000,000."),
        ("It came to 1.5 million dollars.", "It came to $1,500,000."),
        ("About 3 hundred dollars.", "About $300."),
        ("Eighteen thousand dollars.", "$18,000."),
    ])
    func digitScaleMoney(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("digits plus a scale word without currency are left alone", arguments: [
        "We have 18 thousand users.",
        "It sold 2 million copies.",
    ])
    func digitScaleWithoutCurrency(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }
}
