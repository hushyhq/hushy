import Testing
@testable import MurmurCore

/// A clause-level "I mean" that clarifies must never delete the complete clause before it, and the
/// facts it carries (found by the fine-tune agent's v5 filter, 2026-09-28). Only a same-slot repair
/// resolves ("Tuesday, I mean Wednesday"). Cases written from scratch.
@Suite("Clarifying I mean and same-slot repairs")
struct ClarifyingIMeanTests {
    let cleaner = TextCleaner()

    @Test("a clarifying I mean keeps the clause before it", arguments: [
        "The team meeting is at 9 AM, I mean the standup starts then.",
        "The review is on Friday, I mean the design review, not the code review.",
        "I sent the file to Priya, I mean the whole design team has it now.",
        "The launch was on March 3, I mean the beta went out then.",
    ])
    func clarificationKeepsClause(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("a same-slot repair still resolves", arguments: [
        ("The meeting is at 9, I mean 10.", "The meeting is at 10."),
        ("The review is on Tuesday, I mean Wednesday.", "The review is on Wednesday."),
        ("Let's go to the park, no, to the beach.", "Let's go to the beach."),
        ("Send it to the design team, I mean to the product team.", "Send it to the product team."),
        ("Send it to John, sorry, Sarah.", "Send it to Sarah."),
        // Sentence-initial "The" is casing, not a name the replacement must repeat.
        ("The team lead, sorry, the hiring manager agreed with me.", "The hiring manager agreed with me."),
    ])
    func sameSlotRepair(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("a sentence-initial capital is not part of the name being corrected", arguments: [
        ("Ask Maria, sorry, Mark about the invoice.", "Ask Mark about the invoice."),
        ("Tell Priya, sorry, Dana the deck is ready.", "Tell Dana the deck is ready."),
        ("Ask Maria, sorry, Mark Smith about the invoice.", "Ask Mark Smith about the invoice."),
    ])
    func sentenceInitialVerbKept(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("a two-word name is still replaced by a two-word name")
    func twoWordName() {
        #expect(cleaner.clean("Sarah Connor, sorry, John Smith will call you.").text == "John Smith will call you.")
        #expect(SelfCorrection.apply("Mark Smith, sorry, John Brown will call you.").text == "John Brown will call you.")
    }

    /// A month, weekday or opening capital used to be enough. The span back to that token was
    /// replaced even when it held the rest of the clause ("March is the launch window, sorry,
    /// June is…" became "June is…").
    @Test("a kind cue leaves a clause that is not one slot", arguments: [
        "March is the launch window, sorry, June is only the rehearsal.",
        "Monday is the deadline, sorry, Tuesday is only a target.",
        "Twenty is the limit, sorry, thirty is only a target.",
        "9am is the deadline, sorry, 10am is only a target.",
        "Sarah is the lead, sorry, John is only the reviewer.",
        "March slipped badly, sorry, June is only the rehearsal.",
        "Sarah arrived early, sorry, John stayed late.",
        "We slipped. Ship the patch tonight, sorry, Finance already signed off.",
    ])
    func kindCueLeavesAClause(input: String) {
        #expect(SelfCorrection.apply(input).text == input)
    }

    @Test("a same-kind slot still resolves when the clause opens on that slot", arguments: [
        ("Tuesday, no, Wednesday.", "Wednesday."),
        ("March, sorry, June.", "June."),
        ("Sarah, sorry, John will call you.", "John will call you."),
        ("Meet on Monday, sorry, Tuesday.", "Meet on Tuesday."),
        ("The launch is in March, sorry, June.", "The launch is in June."),
        ("The limit is twenty five, sorry, fifteen.", "The limit is fifteen."),
        ("Meet at 9am, sorry, 10am.", "Meet at 10am."),
        ("Book for four people, no, six people.", "Book for six people."),
    ])
    func openingSlotStillResolves(input: String, expected: String) {
        #expect(SelfCorrection.apply(input).text == expected)
    }
}
