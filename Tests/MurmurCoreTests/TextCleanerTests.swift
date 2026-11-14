import Testing
@testable import MurmurCore

@Suite("TextCleaner")
struct TextCleanerTests {
    let cleaner = TextCleaner()

    @Test("self-corrections resolve to the corrected value", arguments: [
        ("Let's meet at 10, no, 9 tomorrow in the main conference room.",
         "Let's meet at 9 tomorrow in the main conference room."),
        ("Let's meet at 10, no, 9.", "Let's meet at 9."),
        ("The meeting is on Tuesday, wait no, Friday.", "The meeting is on Friday."),
        ("Send it to John, no, Sarah.", "Send it to Sarah."),
        ("We should go to the park, no, to the beach.", "We should go to the beach."),
        ("The budget is $500, sorry, $600.", "The budget is $600."),
        ("Call me at 3pm, I mean 4pm.", "Call me at 4pm."),
        ("It launches in March, actually, April.", "It launches in April."),
        ("I'll call at 3, no, 4, no, 5.", "I'll call at 5."),
    ])
    func selfCorrections(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("literal uses of correction words are preserved", arguments: [
        "No, I don't think so.",
        "I said no to the offer.",
        "It's fine, actually, I like it.",
        "There is no reason to wait.",
    ])
    func literalWordsUntouched(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("scratch that drops the previous sentence or clause", arguments: [
        ("Let's order pizza. Scratch that. Let's order sushi.", "Let's order sushi."),
        ("Let's order pizza, scratch that, sushi tonight.", "Sushi tonight."),
        ("First line. Second line. Scratch that.", "First line."),
    ])
    func scratchThat(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("new line and new paragraph insert breaks")
    func lineBreaks() {
        #expect(cleaner.clean("Hi Sam, new line, thanks for the update.").text == "Hi Sam\nThanks for the update.")
        #expect(cleaner.clean("Intro done. New paragraph. Next topic.").text == "Intro done.\n\nNext topic.")
    }

    @Test("fillers are removed")
    func fillers() {
        #expect(cleaner.clean("Um, so we, uh, need to ship it.").text == "So we need to ship it.")
        #expect(cleaner.clean("It was, like, really fast.").text == "It was, really fast.")
    }

    /// 2026-09-27 pill-wait report: the recognizer capitalizes a hesitation after a pause even
    /// mid-sentence, and a trailing one ends the dictation. Rules remove both, so a dictation
    /// the model never saw still loses its "uh".
    @Test("hesitations go wherever they sit, capitalized or trailing", arguments: [
        ("is it making tool calls or determining tool calls? Uh what", "Is it making tool calls or determining tool calls? What?"),
        ("determining tool calls Uh what", "Determining tool calls what."),
        ("we need Um the report", "We need the report."),
        ("it was Hmm interesting", "It was interesting."),
        ("we should look at the tool calls uh", "We should look at the tool calls."),
        ("we should look at the tool calls. Um.", "We should look at the tool calls."),
        ("determining tool calls, Uh, what", "Determining tool calls what."),
    ])
    func hesitationsAnywhere(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("hyphenated yeses and millimetres are not hesitations", arguments: [
        ("she said uh-huh and left", "She said uh-huh and left."),
        ("is it tool calls? Mm-hmm.", "Is it tool calls? Mm-hmm."),
        ("the screw is 5 mm long", "The screw is 5 mm long."),
    ])
    func notHesitations(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("filler words only match lowercase, not acronyms that happen to share letters", arguments: [
        "The ER team arrives tomorrow.",
        "Ask the HR department about it.",
        "Send it to IT before Friday.",
        "The AI model finished training.",
    ])
    func fillersDoNotEatAcronyms(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("introduced series becomes a bulleted list")
    func introducedSeries() {
        let result = cleaner.clean("Create a to-do list, tomatoes, onions, beans, ketchup, and Roma tomatoes.")
        #expect(result.text == "Create a to-do list:\n- Tomatoes\n- Onions\n- Beans\n- Ketchup\n- Roma tomatoes")
    }

    @Test("ordinals become a numbered list")
    func ordinals() {
        let result = cleaner.clean("My plan is first, fix the bug. Second, write tests. Third, ship it.")
        #expect(result.text == "My plan is:\n1. Fix the bug\n2. Write tests\n3. Ship it")
    }

    @Test("an ordinal modifying a noun mid-sentence is never mistaken for a list item", arguments: [
        "The pacing in the first half is pretty slow, but it picks up once the second narrator gets introduced.",
        "I read the first chapter and skipped straight to the third one.",
    ])
    func ordinalNounModifierNotAList(input: String) {
        let result = cleaner.clean(input)
        #expect(!result.text.contains("1."))
        #expect(!result.text.contains("\n"))
    }

    @Test("bullets become a bulleted list")
    func bullets() {
        let result = cleaner.clean("Groceries bullet milk bullet eggs bullet bread")
        #expect(result.text == "Groceries:\n- Milk\n- Eggs\n- Bread")
    }

    @Test("ordinary comma sentences are not turned into lists")
    func noFalseLists() {
        let input = "I went to the store, bought milk, and came home."
        #expect(cleaner.clean(input).text == input)
    }

    @Test("an inline series inside a sentence stays a sentence at Clean", arguments: [
        "I need four apples, one orange, and one Bloody Mary.",
        "I need four apples, one orange and one Bloody Mary.",
        "I went to Paris, London, and Rome last year.",
        "Get bread, salt and pepper, and milk.",
    ])
    func inlineSeriesStaysProse(input: String) {
        let result = cleaner.clean(input)
        #expect(result.text == input)
        #expect(!result.text.contains("\n"))
    }

    @Test("a series the speaker introduced as a list is formatted as one", arguments: [
        ("My shopping list, apples, oranges and milk.", "My shopping list:\n- Apples\n- Oranges\n- Milk"),
        ("Three things: first, call Bob, second, email Ann, third, ship it.", "Three things:\n1. Call Bob\n2. Email Ann\n3. Ship it"),
    ])
    func introducedSeriesIsAList(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("press enter is detected only at the end")
    func pressEnter() {
        let result = cleaner.clean("Sounds good, see you then. Press enter.")
        #expect(result.pressEnter)
        #expect(result.text == "Sounds good, see you then.")
        #expect(!cleaner.clean("Press enter to continue the setup.").pressEnter)
    }

    @Test("press enter fires for the whole utterance or a trailing clause")
    func pressEnterPositive() {
        #expect(cleaner.clean("Press enter.").pressEnter)
        #expect(cleaner.clean("press enter").pressEnter)
        #expect(cleaner.clean("Sounds good, press enter").pressEnter)
        #expect(cleaner.clean("Sounds good, press enter").text == "Sounds good")
        #expect(cleaner.clean("Let's ship it. Hit enter.").pressEnter)
    }

    @Test("press enter is literal in reporting, quoting or negated context", arguments: [
        "The instructions say press enter.",
        "The instructions say to press enter.",
        "She said press enter.",
        "He said, press enter.",
        "Type press enter into the field.",
        "The word press enter appears in the manual.",
        "It's called press enter mode.",
        "Don't press enter yet.",
        "Do not press enter yet.",
        "Never press enter here.",
        "Please do not hit enter until it's ready.",
        "\"Press enter\" is what the sign says.",
    ])
    func pressEnterNegative(input: String) {
        let result = cleaner.clean(input)
        #expect(!result.pressEnter)
        #expect(result.text == input)
    }

    @Test("scratch that only fires as a standalone clause")
    func scratchThatStandaloneOnly() {
        let result = cleaner.clean("Tuesday, scratch that, Wednesday works.")
        #expect(result.text == "Wednesday works.")
    }

    @Test("scratch that is literal when followed by a noun or preceded by negation", arguments: [
        "Please do not scratch that surface.",
        "Don't scratch that itch.",
        "I want to scratch that itch later.",
        "Never delete that file without asking.",
        "Please do not delete that record.",
    ])
    func scratchThatLiteral(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("new line and new paragraph only fire as standalone clauses", arguments: [
        "Draw a new line on the chart.",
        "They released a new line of products today.",
        "Start a new paragraph about the product history.",
        "The new paragraph style needs work.",
    ])
    func lineBreaksLiteral(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("verbatim keeps fillers and corrections but honours commands")
    func verbatim() {
        let verbatim = TextCleaner(options: CleanupOptions(level: .verbatim))
        #expect(verbatim.clean("Um, meet at 10, no, 9. New line. Bye.").text == "Um, meet at 10, no, 9.\nBye.")
    }

    @Test("verbatim keeps ordinary casing while applying explicit line commands")
    func verbatimKeepsCasing() {
        let verbatim = TextCleaner(options: CleanupOptions(level: .verbatim))
        #expect(verbatim.clean("hey!! new line, running 5 min late, save me a seat lol")
            .text == "hey!!\nrunning 5 min late, save me a seat lol")
    }

    @Test("Polished rules draft keeps casing in explicit casual context")
    func polishedCasualContextKeepsCasing() {
        var options = CleanupOptions(level: .polished)
        options.isCasualContext = true
        #expect(TextCleaner(options: options).clean("hey, that works for me. see you around 6!").text
            == "hey, that works for me. see you around 6!")
    }

    @Test("recognized texting register keeps lowercase sentence starts")
    func textingMarkersKeepCasing() {
        let options = CleanupOptions(level: .polished)
        #expect(TextCleaner(options: options).clean("hey, see you around 6 lol").text == "hey, see you around 6 lol.")
    }

    @Test("voice commands can be disabled")
    func commandsDisabled() {
        let plain = TextCleaner(options: CleanupOptions(level: .clean, voiceCommandsEnabled: false))
        #expect(plain.clean("Write new line on the board.").text == "Write new line on the board.")
    }

    @Test("empty and whitespace input")
    func empty() {
        #expect(cleaner.clean("   ").text == "")
    }

    @Test("unresolvable strong cue is reported and text kept")
    func unresolved() {
        let result = cleaner.clean("That plan works, no, the other plan does not work at all today")
        #expect(result.text.isEmpty == false)
    }

    @Test("names and technical vocabulary survive cleanup untouched", arguments: [
        "Priya is migrating the database to Supabase this week.",
        "Please loop in Priya on the Supabase migration.",
    ])
    func namesUntouched(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("numbers, money, versions and phone-like digits survive cleanup untouched", arguments: [
        "The invoice total is $1,250 due Friday.",
        "Conversion improved by 12.5% after the change.",
        "Please upgrade to v2.3.1 before the demo.",
        "Let's push the call to 9:30am tomorrow.",
        "Call me back at 555-123-4567 when you land.",
    ])
    func numbersUntouched(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("technical strings survive cleanup untouched", arguments: [
        "Rename the userId field to accountId everywhere.",
        "The bug is in src/app/main.ts near the top.",
        "The staging build is at https://staging.murmur.app/health.",
        "Run the script with --dry-run first to be safe.",
        "Add ada.lovelace+build@murmur.app to the alert list.",
    ])
    func technicalStringsUntouched(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("spoken non-address technical forms are left literal", arguments: [
        "He literally said dash dash dry run in the meeting.",
    ])
    func spokenTechnicalFormsLiteral(input: String) {
        #expect(cleaner.clean(input).text == input)
    }

    @Test("spoken domain normalizes for navigation and stays literal for pronunciation")
    func spokenDomain() {
        #expect(cleaner.clean("Visit murmur dot com for the demo.").text
                == "Visit murmur.com for the demo.")
        #expect(cleaner.clean("Just say murmur dot com out loud for the demo.").text
                == "Just say murmur dot com out loud for the demo.")
    }

    // MARK: Language gating — non-English text skips the English-only stages

    @Test("non-English text is not run through English filler removal")
    func nonEnglishSkipsFillers() {
        let options = CleanupOptions(level: .clean, detectedLanguage: "es")
        let input = "Um, hola, uh, ¿cómo estás?"
        let result = TextCleaner(options: options).clean(input)
        #expect(result.text.contains("Um"))
        #expect(result.text.contains("uh"))
    }

    @Test("non-English text does not get English self-correction cues resolved")
    func nonEnglishSkipsSelfCorrection() {
        // "no" is an ordinary Spanish word here ("no, no hay problema"), not a correction cue —
        // the English self-correction stage must not fire and delete surrounding text.
        let options = CleanupOptions(level: .clean, detectedLanguage: "es")
        let input = "No, no hay problema con la reunión de mañana."
        let result = TextCleaner(options: options).clean(input)
        #expect(result.text.contains("no hay problema"))
    }

    @Test("non-English text skips English inverse-text-normalization")
    func nonEnglishSkipsITN() {
        // English ITN turns "nine" into "9"; that pattern must not apply to non-English number
        // words it was never designed to parse.
        let options = CleanupOptions(level: .clean, detectedLanguage: "fr")
        let input = "Nous avons besoin de neuf chaises pour la réunion."
        let result = TextCleaner(options: options).clean(input)
        #expect(result.text.contains("neuf"))
    }

    @Test("unknown/nil language still runs the full English pipeline (safe default)")
    func nilLanguageRunsFullPipeline() {
        let options = CleanupOptions(level: .clean, detectedLanguage: nil)
        #expect(TextCleaner(options: options).clean("Um, let's meet at 10, no, 9.").text == "Let's meet at 9.")
    }

    @Test("English language code explicitly runs the full pipeline")
    func explicitEnglishRunsFullPipeline() {
        let options = CleanupOptions(level: .clean, detectedLanguage: "en")
        #expect(TextCleaner(options: options).clean("Um, let's meet at 10, no, 9.").text == "Let's meet at 9.")
    }

    @Test("verbatim level skips English-only stages regardless of language")
    func verbatimSkipsEnglishStagesToo() {
        let options = CleanupOptions(level: .verbatim, detectedLanguage: "en")
        let input = "Um, let's meet at 10, no, 9."
        #expect(TextCleaner(options: options).clean(input).text == input)
    }

    @Test("punctuation tidying still runs for non-English text")
    func nonEnglishStillGetsPunctuationTidy() {
        let options = CleanupOptions(level: .clean, detectedLanguage: "de")
        let result = TextCleaner(options: options).clean("Hallo   Welt  .")
        #expect(!result.text.contains("  "))
    }
}
