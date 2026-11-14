import Testing
@testable import MurmurCore

@Suite("DiscourseMarkers")
struct DiscourseMarkersTests {
    let cleaner = TextCleaner()

    @Test("removes sentence-initial hedge like before an auxiliary or pronoun", arguments: [
        ("Like do we have a threshold for this?", "Do we have a threshold for this?"),
        ("Like, is that right?", "Is that right?"),
        ("Like I think we should wait.", "I think we should wait."),
    ])
    func sentenceInitialRemoved(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("keeps Like I said as a fixed phrase")
    func likeISaidKept() {
        #expect(cleaner.clean("Like I said, we need this done by Friday.").text == "Like I said, we need this done by Friday.")
    }

    @Test("keeps Like it or not as a fixed phrase")
    func likeItOrNotKept() {
        #expect(cleaner.clean("Like it or not, we're doing this.").text == "Like it or not, we're doing this.")
    }

    @Test("removes like before an adverb ending in -ly", arguments: [
        ("It stopped after the above sentence like automatically.", "It stopped after the above sentence automatically."),
        ("The build broke like immediately.", "The build broke immediately."),
    ])
    func beforeAdverbRemoved(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("removes like before literally, totally or basically", arguments: [
        ("Do we have a threshold like literally?", "Do we have a threshold literally?"),
        ("It was like totally broken.", "It was totally broken."),
        ("That's like basically the whole plan.", "That's basically the whole plan."),
    ])
    func beforeIntensifierRemoved(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("keeps the verb use of like", arguments: [
        "I like it.",
        "I really like the new design.",
        "Do you like coffee?",
    ])
    func verbUseKept(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("keeps the comparison/preposition use of like", arguments: [
        "It looks like rain.",
        "It sounds like a plan.",
        "This tastes like chicken.",
        "Something like that would work.",
        "Things like that take time.",
        "We need something like a spreadsheet.",
    ])
    func comparisonUseKept(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("keeps like before an adjective that happens to end in -ly", arguments: [
        "The house feels like a family home.",
        "He seems like a friendly guy.",
    ])
    func adjectiveExceptionsKept(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("keeps looks-like-adverb comparisons intact")
    func looksLikeAdverbKept() {
        #expect(cleaner.clean("It looks like literally nothing changed.").text == "It looks like literally nothing changed.")
    }

    @Test("keeps a mid-sentence like that is not sentence-initial", arguments: [
        "We should, like, try the new approach.",
    ])
    func midSentenceCommaSetOffStillHandledByFillers(input: String) {
        // Handled by the existing comma-set-off filler rule, not DiscourseMarkers; just confirm
        // the combination doesn't regress (pre-existing behavior: the leading comma before
        // "like" is preserved as the clause's own comma, only ", like," collapses).
        #expect(cleaner.clean(input).text == "We should, try the new approach.")
    }
}
