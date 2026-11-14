import Testing
@testable import MurmurCore

/// "I mean" is a repair cue only when a replacement follows it in the same breath ("Tuesday,
/// I mean Wednesday", "Mar I mean Maria"). Ending a sentence ("…last forever I mean.") or set off
/// as a filler before a new clause ("…nice I mean, honestly…") it is a discourse marker, and the
/// word before it must survive. Found by the external DisfluencySpeech benchmark (2026-09-28):
/// "That thing will last forever I mean. Oh, yeah…" became "That thing will last Oh, yeah…".
@Suite("I mean as a discourse marker")
struct IMeanDiscourseMarkerTests {
    let cleaner = TextCleaner()

    @Test("FragmentRepair leaves a sentence-final or comma-set I mean alone", arguments: [
        "That thing will last forever I mean. Oh, yeah, it will.",
        "It was fine I mean. We shipped it anyway.",
        "The weather is nice I mean, honestly it could be better.",
        "It was fine I mean, whatever works for you.",
        "We could try it I meant. Nobody asked though.",
    ])
    func fragmentRepairNegatives(text: String) {
        #expect(FragmentRepair.apply(text) == text)
    }

    @Test("the full rules pass keeps the word before a discourse-marker I mean", arguments: [
        ("That thing will last forever I mean. Oh, yeah, it's built really well.", "forever"),
        ("The weather is nice I mean, honestly it could be better.", "nice"),
        ("It was fine I mean. We shipped it anyway.", "fine"),
    ])
    func rulesKeepWordBeforeMarker(input: String, kept: String) {
        let output = cleaner.clean(input).text
        #expect(output.contains(kept), "\(output)")
    }

    @Test("true I mean repairs still resolve", arguments: [
        ("The review is on Tuesday, I mean Wednesday.", "The review is on Wednesday."),
        ("Call me at 3pm, I mean 4pm.", "Call me at 4pm."),
    ])
    func repairsStillResolve(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("an unpunctuated one-word I mean repair still resolves", arguments: [
        ("send it to Mar I mean Maria", "send it to Maria"),
        ("move the review to Tuesday I mean Wednesday", "move the review to Wednesday"),
    ])
    func fragmentRepairStillResolves(input: String, expected: String) {
        #expect(FragmentRepair.apply(input) == expected)
    }
}
