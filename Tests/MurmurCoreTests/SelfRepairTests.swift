import Testing
@testable import MurmurCore

@Suite("SelfRepair")
struct SelfRepairTests {
    let cleaner = TextCleaner()

    @Test("resolves a near-duplicate self-repair", arguments: [
        ("Please select the stop clock, stopwatch.", "Please select the stopwatch."),
        ("The meeting is on Tues-, Tuesday.", "The meeting is on Tuesday."),
        ("Let's meet on Sat, Saturday morning.", "Let's meet on Saturday morning."),
    ])
    func repairsResolved(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("keeps an ordinary two-item list untouched", arguments: [
        "We need apples, oranges.",
        "Pick red, green.",
        "Bring milk, eggs.",
    ])
    func shortListsUntouched(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("keeps a longer enumerated list untouched")
    func longerListUntouched() {
        let result = cleaner.clean("We need apples, bananas, oranges for the party.")
        #expect(result.text.contains("apples") && result.text.contains("bananas") && result.text.contains("oranges"))
    }

    @Test("keeps unrelated short words that happen to be close in edit distance", arguments: [
        "I have a cat, car and a bike.",
        "Choose red, bed or blue.",
    ])
    func unrelatedShortWordsUntouched(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("keeps a plain repeated word (stutter) handled by the filler rule, not corrupted")
    func stutterUnaffected() {
        #expect(cleaner.clean("So the the main issue is latency.").text == "So the main issue is latency.")
    }

    @Test("keeps a grocery-style list with similar-sounding items untouched")
    func groceryListUntouched() {
        let result = cleaner.clean("For the party we need cups, plates, napkins and ice.")
        #expect(result.text.contains("cups") && result.text.contains("plates"))
    }

    @Test("a repair in a later sentence still resolves even when an earlier sentence has an unrelated comma-separated list")
    func repairAfterUnrelatedListResolves() {
        // Regression test: `resolveFirst` used to inspect only the very first `word, word`
        // shaped match in the whole text and give up entirely if it failed the guards, so a
        // real repair later in a long dictation was silently left untouched whenever an earlier,
        // unrelated list (here "milk, eggs, bread") came first in the text.
        let text = "I need to buy milk, eggs, bread and cheese. Then I need to swap the stop clock, stopwatch battery before Saturday."
        let result = cleaner.clean(text)
        #expect(result.text.contains("stopwatch battery"))
        #expect(!result.text.contains("stop clock"))
        #expect(result.text.contains("milk, eggs, bread"))
    }
}
