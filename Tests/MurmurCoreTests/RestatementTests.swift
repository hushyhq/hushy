import Testing
@testable import MurmurCore

@Suite("Restatement corrections")
struct RestatementTests {
    func clean(_ raw: String) -> String {
        TextCleaner(options: CleanupOptions(level: .clean)).clean(raw).text
    }

    @Test("a restated request replaces the earlier one", arguments: [
        ("I need one tomato, one potato, two beans and two carrots. No, I just need two carrots",
         "I just need two carrots."),
        ("Let's meet on Monday. Actually, let's meet on Tuesday.", "Let's meet on Tuesday."),
        ("I want the red one, no, I want the blue one", "I want the blue one."),
        ("We should ship on Friday. Wait, we should ship on Thursday.", "We should ship on Thursday."),
    ])
    func replaces(raw: String, expected: String) {
        #expect(clean(raw) == expected)
    }

    @Test("earlier sentences are kept")
    func keepsContext() {
        #expect(clean("Thanks for the update. I need one tomato. No, I only need two carrots.")
                == "Thanks for the update. I only need two carrots.")
    }

    @Test("different subject or verb is not a restatement", arguments: [
        "I need two carrots. No, you can't have them.",
        "We shipped the app. No, we did not ship the docs.",
        "I told him no. I need a break.",
    ])
    func leavesAlone(raw: String) {
        #expect(clean(raw) == raw)
    }
}

@Suite("Object restatements")
struct ObjectRestatementTests {
    func clean(_ raw: String) -> String {
        TextCleaner(options: CleanupOptions(level: .clean)).clean(raw).text
    }

    @Test("a corrected quantity replaces the listed items", arguments: [
        ("I need two carrots, two beans, no, just one carrot", "I need just one carrot."),
        ("Get three apples and two pears. No, only one pear.", "Get only one pear."),
        ("Book a table for four people, no, six people", "Book a table for six people."),
    ])
    func replaces(raw: String, expected: String) {
        #expect(clean(raw) == expected)
    }

    @Test("additions and literal uses are left alone", arguments: [
        "We need three servers, no, one more.",
        "I have two kids. No, just kidding.",
        "Order two pizzas. No, we also need a salad.",
    ])
    func leavesAlone(raw: String) {
        #expect(clean(raw) == raw)
    }
}
