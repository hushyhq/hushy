import Testing
@testable import MurmurCore

/// The whole-transcript value and name checks read numbers and names the way people say them (guard ablation
/// 2026-10-28: the value check was right on 3 of 18 refusals, the name check on 0 of 2). Every row is invented or from a
/// public or committed dev set; the refused answers are the 4B's first answers there.
@Suite("Spoken value reading")
struct SpokenValueReadingTests {
    private func verdict(_ answer: String, _ raw: String, knownNames: [String] = []) -> SmartCleaner.Refinement {
        IntentOutputGuard.check(answer, raw: raw, spellingWords: [], knownNames: knownNames)
    }

    private func accepts(_ answer: String, _ raw: String, knownNames: [String] = []) -> Bool {
        if case .accepted = verdict(answer, raw, knownNames: knownNames) { return true }
        return false
    }

    @Test("a lone ordinal or 'one' is no value; next to a number it is", arguments: [
        ("on second basically thoughts we need to restart the ticket not merge",
         "On second thoughts, we need to restart the ticket, not merge."),
        ("okay so i'm building a landing page for my app first can you suggest three headline options",
         "Suggest three headline options for my app's landing page."),
        ("nobody opened the folder", "No one opened the folder."),
        ("tomas liked the portfolio from like the second one which means alice can run the final interview",
         "Tomas liked the second portfolio, which means Alice can run the final interview."),
        ("i finished the book the one about the lighthouse it picks up after the first hundred pages",
         "I finished the book, the one about the lighthouse. It picks up after the first 100 pages."),
        ("there are three things to fix first the intro second the source try the city report from twenty twenty two third the ending",
         "There are three things to fix.\n\nFirst, the intro. Second, the source: try the city report from 2022.\n\nThird, the ending."),
        ("meet me on the first", "Meet me on the 1st."),
    ])
    func ordinalsAndOne(_ raw: String, _ answer: String) {
        #expect(accepts(answer, raw), "\(raw) -> \(verdict(answer, raw))")
    }

    @Test("a range said with one scale word, or written with a dash, is the same two values", arguments: [
        ("the hosting bill is about two to three hundred dollars a month", "The hosting bill is about $200 to $300 a month."),
        ("we budgeted five to ten thousand dollars for the booth", "We budgeted $5,000 to $10,000 for the booth."),
        ("each license runs six or seven hundred dollars per seat", "Each license runs $600-$700 per seat."),
        ("it should cost between twenty five and thirty thousand euros", "It should cost between 25,000 and 30,000 euros."),
        ("we expect a hundred or a hundred and twenty guests", "We expect 100\u{2013}120 guests."),
        ("we expect 100-120 guests", "We expect 100 or 120 guests."),
    ])
    func ranges(_ raw: String, _ answer: String) {
        #expect(accepts(answer, raw), "\(raw) -> \(verdict(answer, raw))")
    }

    @Test("zero and no, a and one, and 'not a hundred'", arguments: [
        ("i have zero room for anything else this week", "I have no room for anything else this week."),
        ("give me a minute", "Give me one minute."),
        ("nope it costs fifteen hundred not a hundred euros", "Nope, it costs 1,500 euros."),
    ])
    func pairs(_ raw: String, _ answer: String) {
        // "zero room" written "no room" is also refused by the negation check, which this does not change.
        if case .rejected(let reason) = verdict(answer, raw) { #expect(reason != "changed digits", "\(raw)") }
    }

    @Test("a changed, merged, added or retracted value is still refused", arguments: [
        ("can you come to my place at nine? i think nine thirty should work", "Can you come to my place at 9:30? I think 9:30 should work."),
        ("let's do eight or maybe eight thirty tomorrow", "Let's do 8:30 tomorrow."),
        ("so quick note the total hmm is ten so yeah thousand make that sixty euros in the meantime", "Quick note: the total is \u{20AC}600."),
        ("meet me on the second", "Meet me on the 3rd."),
        ("we meet on the first no wait the second", "We meet on the first."),
        ("it takes one or two days", "It takes two days."),
        ("the hosting bill is two to three hundred dollars", "The hosting bill is $200 to $400."),
        ("the repair quote came in at three or four hundred dollars", "The repair quote came in at $400."),
        ("we have zero open bugs", "We have 5 open bugs."),
        ("the first floor is closed", "The second floor is closed."),
        ("call five five five one two three four five six seven", "Call 555-123-4568."),
    ])
    func stillRefused(_ raw: String, _ answer: String) {
        #expect(verdict(answer, raw) == .rejected("changed digits"), "\(raw) -> \(verdict(answer, raw))")
    }

    @Test("a phone number and a date keep their plain reading")
    func chainsStayWhole() {
        #expect(accepts("Call 555-123-4567.", "call five five five one two three four five six seven"))
        #expect(SpokenValueReading.readings("2026-10-28") == ["2026-10-28"])
        #expect(SpokenValueReading.readings("555-123-4567") == ["555-123-4567"])
        #expect(SpokenValueReading.readings("100\u{2013}120 guests") == ["100\u{2013}120 guests", "100 to 120 guests"])
    }

    // MARK: Lists counted aloud

    private let listRaw = "okay so here is the plan 1 write a short intro for the launch post two list the three biggest changes "
        + "3 let's use the quill icon no wait 3 let's use the feather icon four yeah change the button to say try it free "
        + "number five keep the price at nine dollars a month and sixth mention it works on macs from 2020 on"

    @Test("spoken list counters laid out as list numbers or bullets are layout, not changed digits")
    func listCounters() {
        let numbered = "Here is the plan:\n\n1. Write a short intro for the launch post.\n2. List the three biggest changes.\n"
            + "3. Use the feather icon.\n4. Change the button to say \"Try it free\".\n5. Keep the price at $9 a month.\n"
            + "6. Mention it works on Macs from 2020 on."
        #expect(accepts(numbered, listRaw), "\(verdict(numbered, listRaw))")
        let bulleted = numbered.replacingOccurrences(of: "\n1. ", with: "\n- ").replacingOccurrences(of: "\n2. ", with: "\n- ")
            .replacingOccurrences(of: "\n3. ", with: "\n- ").replacingOccurrences(of: "\n4. ", with: "\n- ")
            .replacingOccurrences(of: "\n5. ", with: "\n- ").replacingOccurrences(of: "\n6. ", with: "\n- ")
        #expect(accepts(bulleted, listRaw), "\(verdict(bulleted, listRaw))")
        // A prompt that puts the last items first, as an instruction above the list.
        let prompt = "one fix the export crash two fix the dark mode colors three fix the search box four add them to the board "
            + "and five send the list to the team before ten"
        #expect(accepts("Add these to the board, and send the list to the team before 10.\n\n1. Fix the export crash.\n"
            + "2. Fix the dark mode colors.\n3. Fix the search box.", prompt))
        #expect(!accepts("The fixes to send before 10:\n\n1. Fix the export crash.\n2. Fix the dark mode colors.\n3. Fix the search box.", prompt))
        let ordinals = "first call the bank about the card second book the dentist for next week third pay the electricity bill"
        #expect(accepts("1. Call the bank about the card.\n2. Book the dentist for next week.\n3. Pay the electricity bill.", ordinals))
    }

    @Test("a value inside a list item still binds", arguments: [
        "Here is the plan:\n\n1. Write a short intro for the launch post.\n2. List the three biggest changes.\n3. Use the feather icon.\n"
            + "4. Change the button to say \"Try it free\".\n5. Keep the price at $19 a month.\n6. Mention it works on Macs from 2020 on.",
        "Here is the plan:\n\n1. Write a short intro for the launch post.\n2. List the three biggest changes.\n3. Use the feather icon.\n"
            + "4. Change the button to say \"Try it free\".\n5. Keep the price at $9 a month.\n6. Mention it works on Macs.",
        // An item left out.
        "Here is the plan:\n\n1. Write a short intro for the launch post.\n2. List the three biggest changes.\n3. Use the feather icon.\n"
            + "4. Change the button to say \"Try it free\".\n5. Keep the price at $9 a month.",
        "Here is the plan:\n\n1. Write a short intro for the launch post.\n2. List the three biggest changes.\n3. Use the feather icon.\n"
            + "4. Change the button to say \"Try it free\".\n5. Keep the price at $9 a month.\n6. Mention it works on Macs from 2021 on.",
    ])
    func listValuesBind(_ answer: String) {
        #expect(verdict(answer, listRaw) == .rejected("changed digits"), "\(verdict(answer, listRaw))")
    }

    /// The 4B's own first answers on `Evals/spoken-list-dev.jsonl` (invented): "after one" written "1:00", the last two
    /// items folded into a closing sentence or put first as an instruction, and a clause opened after a colon ("Wednesday: It is the offsite").
    @Test("the 4B's list answers on the invented list set are accepted", arguments: [
        ("so for this week the plan looks like this first on monday i have the dentist at nine thirty so i will be in late around eleven second on tuesday we have the design review at two pm and i need the slides ready by noon the deck is about twenty slides right now third wednesday is the offsite so no meetings that day at all and we leave the office at eight fourth on thursday i am meeting priya about the contractor budget which is forty two hundred dollars for the quarter and we might need another fifteen hundred fifth friday i am working from home in the morning actually no sorry friday i am off after one so please do not book anything in the afternoon and um sixth over the weekend i will finish the report which is due on the third of november and seven remind me to call the landlord about the heating before the end of the week",
         "For this week, the plan looks like this:\n1. On Monday, I have the dentist at 9:30, so I will be in late, around 11.\n2. On Tuesday, we have the design review at 2:00 PM, and I need the slides ready by noon. The deck is about 20 slides right now.\n3. Wednesday is the offsite, so no meetings that day at all, and we leave the office at 8:00.\n4. On Thursday, I am meeting Priya about the contractor budget, which is $4,200 for the quarter, and we might need another $1,500.\n5. Friday I am off after 1:00, so please do not book anything in the afternoon.\n6. Over the weekend, I will finish the report, which is due on the 3rd of November.\n7. Remind me to call the landlord about the heating before the end of the week."),
        ("here are the bugs from the test session today one the export button crashes when the file is over fifty megabytes and it happens about three times out of ten two the dark mode colors are wrong on the settings page especially the toggles 3 the search box drops the first letter if you type fast um number four the onboarding skips step two when you already have an account five the price on the upgrade screen says nineteen dollars but it should say nine dollars six what do you mean by the sync bug we had two reports of it last week but i could not reproduce it so maybe ask them for the version seven the pill flickers for about half a second when you switch apps eight please add all of these to the board with priority one for the crash and the price and nine send the list to the whole team before the stand up tomorrow at ten",
         "Here are the bugs from the test session today:\n1. The export button crashes when the file is over 50 MB, and it happens about three times out of ten.\n2. The dark mode colors are wrong on the settings page, especially the toggles.\n3. The search box drops the first letter if you type fast.\n4. The onboarding skips step 2 when you already have an account.\n5. The price on the upgrade screen says $19, but it should say $9.\n6. What do you mean by the sync bug? We had two reports of it last week, but I could not reproduce it, so maybe ask them for the version.\n7. The pill flickers for about half a second when you switch apps.\n\nPlease add all of these to the board with priority 1 for the crash and the price, and send the list to the whole team before the stand-up tomorrow at 10."),
        ("so for this week the plan looks like this first on monday i have the dentist at nine thirty so i will be in late around eleven second on tuesday we have the design review at two pm and i need the slides ready by noon the deck is about twenty slides right now third wednesday is the offsite so no meetings that day at all and we leave the office at eight fourth on thursday i am meeting priya about the contractor budget which is forty two hundred dollars for the quarter and we might need another fifteen hundred fifth friday i am working from home in the morning actually no sorry friday i am off after one so please do not book anything in the afternoon and um sixth over the weekend i will finish the report which is due on the third of november and seven remind me to call the landlord about the heating before the end of the week",
         "For this week, the plan looks like this:\n\n1. Monday: I have the dentist at 9:30, so I will be in late around 11.\n2. Tuesday: We have the design review at 2 PM, and I need the slides ready by noon. The deck is about 20 slides right now.\n3. Wednesday: It is the offsite, so there are no meetings that day, and we leave the office at 8.\n4. Thursday: I am meeting Priya about the contractor budget, which is $4,200 for the quarter, and we might need another $1,500.\n5. Friday: I am off after 1, so please do not book anything in the afternoon.\n6. Over the weekend: I will finish the report, which is due on November 3.\n7. Remind me to call the landlord about the heating before the end of the week."),
        ("here are the bugs from the test session today one the export button crashes when the file is over fifty megabytes and it happens about three times out of ten two the dark mode colors are wrong on the settings page especially the toggles 3 the search box drops the first letter if you type fast um number four the onboarding skips step two when you already have an account five the price on the upgrade screen says nineteen dollars but it should say nine dollars six what do you mean by the sync bug we had two reports of it last week but i could not reproduce it so maybe ask them for the version seven the pill flickers for about half a second when you switch apps eight please add all of these to the board with priority one for the crash and the price and nine send the list to the whole team before the stand up tomorrow at ten",
         "Add these bugs from today's test session to the board with priority 1 for the crash and the price, and send the list to the whole team before tomorrow's stand-up at 10.\n\n1. The export button crashes when the file is over 50 MB, about 3 times out of 10.\n2. The dark mode colors are wrong on the settings page, especially the toggles.\n3. The search box drops the first letter if you type fast.\n4. The onboarding skips step 2 when you already have an account.\n5. The upgrade screen says $19, but it should say $9.\n6. What do you mean by the sync bug? We had 2 reports of it last week, but I could not reproduce it, so maybe ask them for the version.\n7. The pill flickers for about half a second when you switch apps."),
    ])
    func modelListAnswers(_ raw: String, _ answer: String) {
        #expect(accepts(answer, raw), "\(verdict(answer, raw))")
    }

    @Test("a number after 'at', 'is' or 'costs' is a value, not a counter")
    func valueWordsAreNoCounters() {
        let raw = "one call mom about sunday two meet sam at 3 near the station"
        #expect(SpokenListCounters.removingCounters(from: raw) == "call mom about sunday meet sam at 3 near the station")
        #expect(!accepts("1. Call Mom about Sunday.\n2. Meet Sam at 4 near the station.", raw))
        #expect(SpokenListCounters.removingCounters(from: "we need two people and three chairs") == nil)
        // In a list, a counter may follow the number that ends the item before it, but never splits one number.
        #expect(SpokenListCounters.removingCounters(from: "one it fails three times out of ten two the colors are off")
            == "it fails three times out of ten the colors are off")
        #expect(SpokenListCounters.removingCounters(from: "one buy twenty two apples three bake the pie") == nil)
        // "at 3" stays a time even when the list goes on with "four".
        #expect(SpokenListCounters.removingCounters(from: "one call mom about sunday two meet sam at 3 near the station four pay rent")
            == "call mom about sunday meet sam at 3 near the station four pay rent")
        // "version seven" is a version, unless the list goes on with "eight".
        #expect(SpokenListCounters.removingCounters(from: "one update the app two ask for the version seven ship it")
            == "update the app ask for the version seven ship it")
        #expect(SpokenListCounters.removingCounters(from: "one update the app two ask for the version three ship it four tell sam")
            == "update the app ask for the version ship it tell sam")
    }

    // MARK: Names

    @Test("a built-in product the recogniser heard as a longer word is a repair, in place")
    func builtInProduct() {
        let raw = "send the mockups through figment so the engineers can inspect the spacing"
        #expect(accepts("Send the mockups through Figma so the engineers can inspect the spacing.", raw))
        // Not where the spoken word stood.
        #expect(!accepts("Send Figma the mockups so the engineers can inspect the spacing.", raw))
    }

    @Test("a Dictionary or installed-app name counts only when the person has it")
    func personsNames() {
        let raw = "open the report in zen tricks and share it with the team"
        let answer = "Open the report in Zentrix and share it with the team."
        #expect(!accepts(answer, raw))
        #expect(accepts(answer, raw, knownNames: ["Zentrix"]))
    }

    @Test("an ordinary word is never turned into a name, and an unknown name stays refused")
    func notArbitraryWords() {
        #expect(!KnownProductNames.repairs(
            "Slack", answer: "The rope has some Slack in it.", draft: "the rope has some slacky in it", knownNames: [],
            isOrdinaryWord: { $0 == "slack" }))
        #expect(!accepts("Send the mockups through Figmo so they can inspect it.", "send the mockups through figment so they can inspect it"))
    }

    @Test("forDictation hands the names check the Dictionary and the installed apps")
    func knownNamesWiring() {
        let personalizer = Personalizer(dictionary: [DictionaryEntry(term: "Priyanka")])
        let settings = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: .polished), tone: .standard, mode: Mode.builtIns(userName: "")[0],
            category: .other, bundleID: nil, windowTitle: nil, personalizer: personalizer,
            installedApps: [InstalledAppInfo(bundleID: "com.example.zentrix", name: "Zentrix")])
        #expect(settings.cleanupOptions.knownNames == ["Priyanka", "Zentrix"])
    }
}
