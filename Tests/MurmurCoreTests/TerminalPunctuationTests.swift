import Testing
@testable import MurmurCore

@Suite("TerminalPunctuation")
struct TerminalPunctuationTests {
    let cleaner = TextCleaner()

    @Test("adds a period when a dictation ends without one", arguments: [
        ("Can you send me the report by Friday", "Can you send me the report by Friday?"),
        ("Let's ship the release tonight", "Let's ship the release tonight."),
        ("I think we should go with the blue design", "I think we should go with the blue design."),
    ])
    func addsPeriod(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("adds a question mark only for a clear interrogative opener", arguments: [
        ("Do we have a threshold for this", "Do we have a threshold for this?"),
        ("What time does the meeting start", "What time does the meeting start?"),
        ("Can you send the notes over", "Can you send the notes over?"),
    ])
    func addsQuestionMark(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("leaves already-punctuated text untouched", arguments: [
        "Can you send me the report by Friday?",
        "Let's ship the release tonight.",
        "That's great!",
    ])
    func alreadyPunctuated(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("skips very short fragments", arguments: [
        "Yes",
        "Thanks",
        "Call Sarah",
        "Sure thing",
    ])
    func shortFragmentsUntouched(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("never punctuates through a URL, path or version token", arguments: [
        "Go check out https://example.com/docs",
        "The config file is at /usr/local/etc/config",
        "We shipped version 2.3.1",
        "Open the file at C:\\Users\\test\\file",
    ])
    func literalTokensUntouched(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("does not add punctuation after an already-formatted list's last item")
    func listsUntouched() {
        let formatted = "For the trip we need:\n- Sunscreen\n- Towels\n- Snacks\n- Water"
        #expect(TerminalPunctuation.apply(formatted) == formatted)
    }

    @Test("verbatim level never adds punctuation")
    func verbatimUntouched() {
        let verbatim = TextCleaner(options: CleanupOptions(level: .verbatim))
        #expect(verbatim.clean("Can you send me the report by Friday").text == "Can you send me the report by Friday")
    }
}
