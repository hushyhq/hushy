import Testing
@testable import MurmurCore

/// Frame-aware corrections keep the name or noun the correction refers to (FINETUNE.md §3.9).
@Suite("Frame corrections")
struct FrameCorrectionTests {
    func clean(_ raw: String) -> String {
        TextCleaner(options: CleanupOptions(level: .clean)).clean(raw).text
    }

    @Test("a retarget keeps the frame and the name", arguments: [
        ("Reach out to Raj, wait, scratch that, just text him the meeting location.", "Text Raj the meeting location."),
        ("Can you email Mark, oh actually never mind, just message him on Slack.", "Can you message Mark on Slack?"),
        ("Could you notify Sofia, wait, scratch that, just remind her on Monday morning.", "Could you remind Sofia on Monday morning?"),
        ("could you notify chen no wait just remind him on the filing deadline", "Could you remind chen on the filing deadline?"),
        ("please send sofia no wait just message her the updated documentation", "Please message sofia the updated documentation."),
        ("Please reach out Chen, wait, scratch that, just ping them on Teams.", "Please ping Chen on Teams."),
        ("Can you email the whole team, no, just call them tomorrow.", "Can you call the whole team tomorrow?"),
        ("Let's get Luis, wait, scratch that, just ask him to validate the count.", "Let's ask Luis to validate the count."),
    ])
    func retarget(raw: String, expected: String) {
        #expect(clean(raw) == expected)
    }

    @Test("a head-noun correction keeps the noun", arguments: [
        ("Download the online maps, no, the offline ones before the trip starts.", "Download the offline maps before the trip starts."),
        ("Write tests for the main error handlers, sorry, the critical ones.", "Write tests for the critical error handlers."),
        ("Send the draft proposal, no, the final one to the regional manager today.", "Send the final proposal to the regional manager today."),
        ("Send the proposal, no, the final one to Dana.", "Send the final proposal to Dana."),
        ("I think we should go with the blue design, actually no, the green one.", "I think we should go with the green design."),
        ("Reserve the small table, no wait, the big one for our group.", "Reserve the big table for our group."),
        ("book the window seat i mean the aisle seat", "Book the aisle seat."),
        ("submit the annual report sorry the quarterly one to the executive team", "Submit the quarterly report to the executive team."),
        ("Order the red chairs, I mean the black chairs, for the office.", "Order the black chairs, for the office."),
        ("I want the red one, no, the blue one.", "I want the blue one."),
    ])
    func headNoun(raw: String, expected: String) {
        #expect(clean(raw) == expected)
    }

    @Test("a kept value keeps the thing it applies to", arguments: [
        ("Move the standup to 11, actually leave it at 10, but make it shorter.", "Leave the standup at 10, but make it shorter."),
        ("Can you move the meeting to Friday, actually no, keep it on Wednesday.", "Can you keep the meeting on Wednesday?"),
        ("Change the hotel check-in from 2 PM, never mind, leave it at 3 PM, and add a late arrival note.",
         "Leave the hotel check-in at 3 PM, and add a late arrival note."),
    ])
    func keepValue(raw: String, expected: String) {
        #expect(clean(raw) == expected)
    }

    @Test("look-alikes are left unchanged", arguments: [
        // Retarget look-alikes: literal "no", an apology, no pronoun object, two objects.
        "Tell the kids no, just give them the snacks.",
        "I'm sorry, just text him when you can.",
        "Call Raj later, no, just text him.",
        "Send the report to Raj, no wait, just email him.",
        "I told Raj, sorry, I just called him.",
        // Head-noun look-alikes: no "one(s)" and no repeated noun, or a new clause.
        "I sent the report, sorry, the report was late.",
        "They sold the house, actually, the new owners love it.",
        "Pick the one you like, no, the price doesn't matter.",
        "I liked the old one, actually, the new one is fine too.",
        "Download the maps for the long trip, no, the offline ones.",
        // Keep look-alikes: nothing moved, or "leave it" as a plain instruction.
        "Put the files on the desk and leave it at that.",
        "I like the blue theme, actually, leave it on for now.",
    ])
    func negatives(raw: String) {
        #expect(clean(raw) == raw)
    }

    @Test("verbatim never resolves a frame correction")
    func verbatim() {
        let raw = "Download the online maps, no, the offline ones."
        #expect(TextCleaner(options: CleanupOptions(level: .verbatim)).clean(raw).text == raw)
    }

    @Test("\"no wait\" resolves like the other strong cues")
    func noWaitCue() {
        #expect(clean("Let's meet at 10, no wait, 11.") == "Let's meet at 11.")
    }

    @Test("an anchor swap that would drop the noun is left for the model")
    func anchorSwapDeclines() {
        // "ones" can't be the trip; swapping from the anchor "the" would give "…for the offline
        // ones" and lose "maps".
        let raw = "Download the maps for the long trip, no, the offline ones."
        #expect(clean(raw) == raw)
        // The anchor swap still works when nothing refers back.
        #expect(clean("Go to the park, no, to the beach.") == "Go to the beach.")
    }
}
