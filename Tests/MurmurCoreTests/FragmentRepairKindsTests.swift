import Testing
@testable import MurmurCore

/// The one-word swap (`FragmentRepair`) deleted ordinary words: "we should I mean try like a shorter" lost "should"
/// before the model ever ran, because "I mean" is as often a filler as a correction. It now swaps only when the
/// second word is plainly a replacement for the first (a name for a name, a day for a day, a value for a value).
@Suite("FragmentRepair swaps only like for like")
struct FragmentRepairKindsTests {
    @Test("an ambiguous noun after a cue remains the verb of its subject", arguments: [
        "the dispatcher i mean routes parcels daily",
        "our studio i mean prints posters weekly",
        "the clinic i mean tracks referrals closely",
        "our bakery i mean orders flour monthly",
        "the museum i mean labels exhibits carefully",
        "this office i mean files reports promptly",
        "that shop i mean books appointments online",
    ])
    func subjectAndVerbAreLeftAlone(text: String) {
        #expect(FragmentRepair.apply(text) == text)
    }

    @Test("two nouns on either side of a cue can belong to different clauses")
    func newNounClauseIsLeftAlone() {
        let text = "we archived the minutes i mean editors revise them tomorrow"
        #expect(FragmentRepair.apply(text) == text)
    }

    @Test("i mean leaves plain nouns and adjectives with their cue", arguments: [
        "move the chair i mean table",
        "make it small i mean large",
    ])
    func plainValuesAfterIMeanAreLeftAlone(text: String) {
        #expect(FragmentRepair.apply(text) == text)
    }

    @Test("a strict word prefix is a cut-off with any cue", arguments: [
        ("file it under categ i mean category", "file it under category"),
        ("put it in bask sorry basket", "put it in basket"),
    ])
    func unhyphenatedCutOffSwaps(text: String, expected: String) {
        #expect(FragmentRepair.apply(text) == expected)
    }

    @Test("a cut-off needs two letters and a longer replacement")
    func cutOffBoundary() {
        #expect(FragmentRepairKinds.areAlike(abandoned: "BaSk", replacement: "basket", before: "in", cue: "i mean"))
        #expect(!FragmentRepairKinds.areAlike(abandoned: "b", replacement: "basket", before: "in", cue: "i mean"))
        #expect(!FragmentRepairKinds.areAlike(abandoned: "basket", replacement: "basket", before: "in", cue: "i mean"))
    }

    @Test("plain nouns without a prefix stay with I mean")
    func unrelatedNounsStayWithCue() {
        let text = "put it in basket i mean drawer"
        #expect(FragmentRepair.apply(text) == text)
    }

    @Test("i mean swaps closed-class values", arguments: [
        ("set the timer to six i mean seven minutes", "set the timer to seven minutes"),
        ("set the timer to 6 i mean 7 minutes", "set the timer to 7 minutes"),
        ("the call is on monday i mean tuesday", "the call is on tuesday"),
        ("the call is in march i mean april", "the call is in april"),
    ])
    func closedClassValuesAfterIMeanSwap(text: String, expected: String) {
        #expect(FragmentRepair.apply(text) == expected)
    }

    @Test("other cues still swap plain nouns", arguments: [
        ("move the chair sorry table", "move the table"),
        ("move the chair no wait table", "move the table"),
        ("move the chair i meant table", "move the table"),
    ])
    func plainNounsAfterOtherCuesSwap(text: String, expected: String) {
        #expect(FragmentRepair.apply(text) == expected)
    }

    @Test("a word swapped for a different kind of word is left, with its cue, for the model", arguments: [
        "it does which means we should I mean try like a shorter version",
        "the enterprise column I mean confuses people who just look",
        "so support I mean does not notice small changes",
        "do not merge the branch yet sorry go ahead and merge it",
        "send the revised invoice on tuesday no sorry send it on wednesday",
        "ask priya no wait ask meera to approve the invoice",
        "invite doctor okafor no wait doctor okoye to the review",
        "so i'm off i mean i'm off saturday",
    ])
    func differentKindsAreLeftAlone(text: String) {
        #expect(FragmentRepair.apply(text) == text)
    }

    @Test("a name for a name, a day for a day, a colour for a colour and a number for a number still resolve", arguments: [
        ("send it to dana no sorry elif", "send it to elif"),
        ("the owner is dev oh no wait sana", "the owner is sana"),
        ("the call is on monday no wait tuesday", "the call is on tuesday"),
        ("send it tuesday no wait wednesday", "send it wednesday"),
        ("paint it green sorry blue", "paint it blue"),
        ("set the timer to six sorry seven minutes", "set the timer to seven minutes"),
        ("the front desk took twelve no wait fourteen calls yesterday", "the front desk took fourteen calls yesterday"),
        ("send it to marketing sorry finance", "send it to finance"),
        ("with Ameri sorry Indian accent", "with Indian accent"),
        ("on the Tues- no Wednesday call", "on the Wednesday call"),
        ("send it to Mar I mean Maria", "send it to Maria"),
    ])
    func likeForLikeResolves(text: String, expected: String) {
        #expect(FragmentRepair.apply(text) == expected)
    }

    @Test("a clause that follows a retraction still starts a new sentence")
    func clauseStillBreaks() {
        #expect(FragmentRepair.apply("the update shipped oh sorry dana needs the link") == "the update shipped. dana needs the link")
    }
}
