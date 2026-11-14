import Testing
@testable import MurmurCore

@Suite("WordFragmentStutter")
struct WordFragmentStutterTests {
    @Test func preservesStraightAndTypographicPossessiveTails() {
        for text in ["tomorrow’s session", "tomorrow's session", "let’s start", "let's start", "manager’s schedule", "manager's schedule"] {
            #expect(WordFragmentStutter.remove(text) == text)
        }
        // A lone letter with nothing to mark it as a cut-off is left for the model: it can be a label ("plan b").
        #expect(WordFragmentStutter.remove("s session") == "s session")
    }

    let cleaner = TextCleaner()

    @Test("removes a stuttered word-start fragment before the full word", arguments: [
        ("to actually c c calculate the minutes", "To actually calculate the minutes."),
        ("to actually c- calculate the minutes", "To actually calculate the minutes."),
        ("th the report is due tomorrow", "The report is due tomorrow."),
        ("wh what time does it start", "What time does it start?"),
        ("st- start the meeting now", "Start the meeting now."),
        ("th th the report is ready", "The report is ready."),
    ])
    func fragmentsRemoved(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("keeps a lone letter that can label the word before it, even when the next word starts with it", arguments: [
        "The demo failed on plan b because the staging key had expired.",
        "Please close gate d during the delivery.",
        "We picked option c could be cheaper but slower.",
        "Put the old contract in folder s sorted by date.",
        "Send lot b before noon.",
        "Use building c close to the entrance.",
    ])
    func loneLetterLabelKept(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("a lone letter before a word it starts is left for the model, and the model is asked")
    func loneLetterGoesToTheModel() {
        let ruled = cleaner.clean("to actually c calculate the minutes").text
        #expect(ruled.contains("c calculate"))
        #expect(WordFragmentStutter.mightHaveUnresolvedFragment(ruled))
        #expect(WordFragmentStutter.mightHaveUnresolvedFragment("can we m make the font a little bigger"))
    }

    @Test("keeps real short words that happen to prefix the next word", arguments: [
        "We work well together.",
        "She sells seashells by the seashore.",
        "So sorry about that.",
        "In inside the box there was a note.",
        "Or organize the files first.",
        "A apple a day.",
        "An animal shelter opened downtown.",
        "My mother called this morning.",
    ])
    func realWordsUntouched(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("a repeated real short word leaves one copy before a longer word")
    func repeatedStandaloneWord() {
        #expect(cleaner.clean("We went in in inside the studio.").text == "We went in inside the studio.")
    }

    @Test("a repeated real word before a longer word it starts is never deleted outright")
    func repeatedRealWordKept() {
        #expect(cleaner.clean("the the theory is sound").text == "The theory is sound.")
        // "for" must survive; whether the pair collapses is the model's call, not this rule's.
        #expect(cleaner.clean("book a table for for forty people").text.hasPrefix("Book a table for "))
    }

    @Test("keeps a 3-letter bare word that happens to prefix the next word")
    func threeLetterBareWordUntouched() {
        #expect(cleaner.clean("Cat categories are fun to browse.").text == "Cat categories are fun to browse.")
    }

    @Test("never touches a capitalized fragment", arguments: [
        "C programming is fun to learn.",
        "Grade C average was fine.",
    ])
    func capitalizedFragmentsUntouched(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("drops a Titlecase ASR fragment before the lowercase word it starts; keeps acronyms and names", arguments: [
        ("Click the Gr green button to start.", "Click the green button to start."),
        ("We should look at the PR process again.", "We should look at the PR process again."),
        ("Ask Ed Edwards about it.", "Ask Ed Edwards about it."),
        ("The IT team is on it.", "The IT team is on it."),
        ("In India it is fine.", "In India it is fine."),
    ])
    func titlecaseFragment(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("verbatim level never removes a fragment")
    func verbatimUntouched() {
        let verbatim = TextCleaner(options: CleanupOptions(level: .verbatim))
        #expect(verbatim.clean("to actually c calculate the minutes").text.contains("c calculate"))
    }

    @Test("whole-word stutter on short function words still resolves", arguments: [
        ("So the the main issue is latency.", "So the main issue is latency."),
    ])
    func wholeWordStutterStillWorks(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("'so so' is left unchanged — it's a legitimate idiom (mediocre/unimpressive), not always a stutter")
    func soSoIdiomPreserved() {
        #expect(cleaner.clean("It was so so, nothing special.").text.contains("so so"))
    }
}
