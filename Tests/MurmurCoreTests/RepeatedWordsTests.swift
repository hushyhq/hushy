import Testing
@testable import MurmurCore

@Suite("LegitDoubles and StutterCollapse")
struct RepeatedWordsTests {
    // MARK: LegitDoubles — the closed legitimate set

    @Test("legitimate doubles are found in context", arguments: [
        ("It was very very cold.", ["very"]),
        ("She had had the same problem.", ["had"]),
        ("He said that that approach would not scale.", ["that"]),
        ("Okay, bye bye, talk soon.", ["bye"]),
        ("the demo went so so but the investors asked", ["so"]),
        ("honestly it was so so", ["so"]),
        ("what it is is a timing bug", ["is"]),
        ("all it was was a typo", ["was"]),
        ("I like like buttons more than dislike buttons.", ["like"]),
        ("No no, that's fine.", ["no"]),
        ("much much better than before", ["much"]),
        ("knock knock", ["knock"]),
    ])
    func legitimateInContext(text: String, expected: [String]) {
        #expect(LegitDoubles.legitimateDoubles(in: text) == expected)
    }

    @Test("stutters and discourse-marker doubles are not legitimate", arguments: [
        "actually actually the export works",
        "it it fails on large files",
        "it's it's a three second thing",
        "the second one is is that it hangs",
        "so so we should ship it",
        "the the button",
        "it was like like three hours",
        "we we should go",
        "basically basically done",
        "I'm I'm not sure",
    ])
    func stuttersAreNotLegitimate(text: String) {
        #expect(LegitDoubles.legitimateDoubles(in: text).isEmpty)
    }

    @Test("a doubling split by a sentence end is not a double")
    func notAcrossSentences() {
        #expect(LegitDoubles.legitimateDoubles(in: "It was very. Very cold.").isEmpty)
    }

    // MARK: StutterCollapse — positives

    @Test("collapses unambiguous single-word stutters", arguments: [
        ("it's it's a three second thing", "it's a three second thing"),
        ("the import it it fails", "the import it fails"),
        ("the second one is is that it hangs", "the second one is that it hangs"),
        ("we we should ship the the fix", "we should ship the fix"),
        ("It's it's fine.", "It's fine."),
        ("i i had to restart", "i had to restart"),
        ("show a a gentle reminder", "show a gentle reminder"),
        ("because it's, it's not ready", "because it's not ready"),
    ])
    func collapsesWordStutters(input: String, expected: String) {
        #expect(StutterCollapse.apply(input) == expected)
    }

    @Test("collapses exact multi-word phrase repeats", arguments: [
        ("we should we should probably ship", "we should probably ship"),
        ("i'm not i'm not a hundred percent sure", "i'm not a hundred percent sure"),
        ("the problem is the problem is that it hangs", "the problem is that it hangs"),
        ("when you when you drag a file", "when you drag a file"),
        ("and then and then nothing happens", "and then nothing happens"),
        ("i've already i've already started typing", "i've already started typing"),
        ("can you can you send me the link", "can you send me the link"),
        ("yeah i don't think we should i don't think we should rename it", "yeah i don't think we should rename it"),
    ])
    func collapsesPhraseRepeats(input: String, expected: String) {
        #expect(StutterCollapse.apply(input) == expected)
    }

    @Test("drops an abandoned negated restart, keeping the later attempt", arguments: [
        ("we should not we should never load it", "we should never load it"),
        ("i do not i do want it", "i do want it"),
    ])
    func dropsNegatedRestart(input: String, expected: String) {
        #expect(StutterCollapse.apply(input) == expected)
    }

    // MARK: StutterCollapse — negatives (must stay exactly as spoken)

    @Test("leaves legitimate doubles and ordinary speech untouched", arguments: [
        "It was very very cold in the office.",
        "She had had the same problem before.",
        "He said that that approach would not scale.",
        "Okay, bye bye, talk soon.",
        "the demo went so so but the investors asked",
        "what it is is a timing bug",
        "I like like buttons more than dislike buttons.",
        "I told you you were right.",
        "I gave her her keys back.",
        "they do do it every week",
        "The IT IT budget line",
        "It is. Is it ready?",
        "No no, that's fine.",
        "we should not ship it",
        "it not it",
        "Send the report to the manager.",
        "one by one",
        "The value should be 10, not 9.",
    ])
    func negatives(text: String) {
        #expect(StutterCollapse.apply(text) == text)
    }

    @Test("repeated digit words in a spoken number are never collapsed", arguments: [
        "call me back on four one five five five five zero one nine eight",
        "the code is two two two two",
        "my pin is five five five one",
        "dial four one five one five zero now",
        "the account ends in seven oh seven oh",
        "room twenty five twenty five",
    ])
    func keepsRepeatedDigits(text: String) {
        #expect(StutterCollapse.apply(text) == text)
    }

    @Test("a repeated phrase that holds a number still collapses")
    func collapsesRepeatedPhraseWithNumber() {
        #expect(StutterCollapse.apply("we need we need two chairs") == "we need two chairs")
        #expect(StutterCollapse.apply("at nine at nine tomorrow") == "at nine tomorrow")
    }

    @Test("the rules draft keeps every spoken digit of a phone number")
    func rulesKeepPhoneDigits() {
        let cleaned = TextCleaner().clean("call me back on four one five five five five zero one nine eight").text
        #expect(cleaned == "Call me back on 415-555-0198.")
    }

    @Test("preserves line structure")
    func keepsLines() {
        #expect(StutterCollapse.apply("the the list:\n- a a item") == "the list:\n- a item")
    }

    @Test("ASR capitalization, punctuation, and longer stutters", arguments: [
        ("Tell tell me how to add them myself", "Tell me how to add them myself"),
        ("Tell, tell me again", "Tell me again"),
        ("Tell- tell me again", "Tell me again"),
        ("I- I need help", "I need help"),
        ("I, I, I need help", "I need help"),
        ("the, the file", "the file"),
        ("the the the file", "the file"),
        ("We, we, we can go", "We can go"),
        ("It- it works", "It works"),
        ("It's, it's, it's ready", "It's ready"),
        ("Tell tell tell her", "Tell her"),
        ("She, she called", "She called"),
        ("My- my notes", "My notes"),
        ("And, and then", "And then"),
        ("They- they left", "They left"),
        ("The- the report", "The report"),
    ])
    func asrStutters(input: String, expected: String) {
        #expect(StutterCollapse.apply(input) == expected)
    }

    @Test("protected doubles and quoted spans", arguments: [
        "She had had enough.", "That that works is surprising.", "What it is is a delay.",
        "It was very very good.", "The result was so so.", "Bye bye for now.",
        "No no, thank you.", "May May is a name.", "I told you you were right.",
        "The value 11-11 is a code.", "Use foo_foo in code.", "The IT IT team.",
        "He said \"the the problem\".", "She wrote “I I agree”.",
        "The report says 'the the issue'.", "It is. Is it ready?",
    ])
    func protectedRepeats(text: String) {
        #expect(StutterCollapse.apply(text) == text)
    }
}
