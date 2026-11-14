import Testing
@testable import MurmurCore

@Suite("ScreenTermShape")
struct ScreenTermShapeTests {
    @Test("code-like tokens are identifiers", arguments: [
        "rl-v9", "TRY-95", "gpt4o", "v2.3", "x86_64", "user_id", "auth.swift", "useEffect", "COVID-19", "qwen3",
    ])
    func identifiers(_ term: String) {
        #expect(ScreenTermShape.kind(of: term) == .identifier)
    }

    @Test("capitalized rare words and multiword names are names", arguments: ["Siobhan", "Wembanyama", "Victor Wembanyama", "VS Code"])
    func names(_ term: String) {
        #expect(ScreenTermShape.kind(of: term) == .name)
    }

    @Test("ordinary words, UI labels, quantities and abbreviations are neither", arguments: [
        "Next", "Text", "text", "middle", "issue", "initiative", "Notion", "3pm", "1st", "90s", "10kg", "e.g.", "U.S.",
        "follow-up", "leftovers", "Monday", "ab",
    ])
    func neither(_ term: String) {
        #expect(ScreenTermShape.kind(of: term) == nil)
        #expect(!ScreenTermShape.isNameOrCodeLike(term))
    }
}

@Suite("Screen identifiers")
struct ScreenIdentifierTests {
    /// Founder, 2026-11-07: "rl-v9" on screen and spoken, "rl-v99" pasted. The spelling fixer matched the letters "Rl-v"
    /// of the heard "Rl-v9" to the screen term and wrote the whole term over them, keeping the heard "9".
    @Test("the spelling fixer never writes a term over the letters of a longer token")
    func founderRow() {
        let heard = "It mistook Rl-v9 as Rl-v9"
        #expect(ContextSpellingFixer.fix(heard, terms: ["rl-v9"]) == heard)
        #expect(ContextSpellingFixer.fix("Ship v9 and auth.swift", terms: ["v99", "auth.swiftly"]) == "Ship v9 and auth.swift")
    }

    @Test("the pipeline writes the screen's identifier and keeps its digits")
    func founderRowThroughPipeline() async {
        let pipeline = DictationPipeline(transcriber: SilentTranscriber())
        let settings = PipelineSettings(contextTerms: ContextExtractor.extractWidened(from: "Run rl-v9 finished at 04:10"))
        let result = await pipeline.clean("It mistook Rl-v9 as Rl-v9", settings: settings, strategy: .rules)
        #expect(result.text.contains("rl-v9"))
        #expect(!result.text.contains("v99"))
    }

    @Test("identifiers with digits are read from the field and the terminal")
    func extraction() {
        let screen = "Training run rl-v9 is done; see TRY-95 and bump v2.3 with gpt4o. Meet at 3pm on the 1st."
        let terms = ContextExtractor.extract(from: screen)
        for term in ["rl-v9", "TRY-95", "v2.3", "gpt4o"] { #expect(terms.contains(term)) }
        for term in ["TRY", "3pm", "1st", "rl"] { #expect(!terms.contains(term)) }
        #expect(TerminalScreenTerms.extract("$ python train.py --run rl-v9").contains("rl-v9"))
        #expect(ContextExtractor.extractWidened(from: screen).contains("TRY-95"))
    }

    @Test("a heard identifier in pieces is written as the screen spells it", arguments: [
        ("ship RL V9 today", "ship rl-v9 today"),
        ("ship rl v nine today", "ship rl-v9 today"),
        ("ship rl dash v nine today.", "ship rl-v9 today."),
        ("ship Rl-v9.", "ship rl-v9."),
        ("open TRY 95 now", "open TRY-95 now"),
        ("open TRY ninety five now", "open TRY-95 now"),
        ("bump v two dot three", "bump v2.3"),
        ("swap gpt4o mini now", "swap gpt4o-mini now"),
        ("rerun the R L V nine eval", "rerun the rl-v9 eval"),
        ("tracked in T R Y one oh seven", "tracked in TRY-107"),
        // A spelled letter heard as a word, anchored by a heard token of letters and digits (the founder's sentence).
        ("Let's release our LV9 as the cleanup model.", "Let's release rl-v9 as the cleanup model."),
        ("ship are LV9 today", "ship rl-v9 today"),
    ])
    func joins(_ heard: String, _ expected: String) {
        #expect(ScreenIdentifierJoiner.join(heard, terms: ["rl-v9", "TRY-95", "v2.3", "gpt4o-mini", "TRY-107"]) == expected)
    }

    @Test("ordinary words, other numbers and broken spans are left alone", arguments: [
        "I will try 95 times",
        "try ninety five more",
        "ship rl v99 today",
        "ship rl. V9 today",
        "bump v 23 now",
        "bump v23 now",
        "I bought a 320 gig drive",
        "paste the text into the text box",
        "oh I will try it",
        // "our" is a letter's name only before a heard token of letters and digits that completes the identifier.
        "our L V nine plan",
        "our level nine plan",
        "let's release our V9 build",
        "you 2 can come",
    ])
    func leavesAlone(_ heard: String) {
        #expect(ScreenIdentifierJoiner.join(heard, terms: ["rl-v9", "TRY-95", "v2.3", "A320", "Next", "Text"]) == heard)
    }

    @Test("a letter's name is not read into an identifier when what follows is on screen on its own")
    func letterNameYieldsToAWholeIdentifier() {
        #expect(ScreenIdentifierJoiner.join("are LV9 and LV10 ready", terms: ["rl-v9", "LV9"]) == "are LV9 and LV10 ready")
        #expect(ScreenIdentifierJoiner.join("our LV9 is ready", terms: ["rl-v9"]) == "rl-v9 is ready")
    }

    @Test("a boost never swaps a heard number and an ordinary word for an on-screen identifier")
    func boostKeepsHeardNumber() {
        let vocabulary = VocabularyContext(terms: [VocabularyTerm(text: "TRY-95"), VocabularyTerm(text: "rl-v9")])
        #expect(vocabulary.guarded(original: "I will try 95 times", boosted: "I will TRY-95 times") == "I will try 95 times")
        #expect(vocabulary.guarded(original: "ship RL V 9 today", boosted: "ship rl-v9 today") == "ship rl-v9 today")
    }

    /// accuracy-v1 baseline 2026-11-10, pattern 4.
    @Test("names in any script and with an apostrophe are read whole")
    func wholeNames() {
        let accented = ContextExtractor.extractWidened(from: "Notes · Trade ideas\nWould we move Kristaps Porziņģis for picks?")
        #expect(accented.contains("Porziņģis"))
        #expect(!accented.contains("Porzi"))
        let apostrophe = ContextExtractor.extractWidened(from: "ESPN · Injury report\nDe'Aaron Fox — questionable (ankle)")
        #expect(apostrophe.contains("De'Aaron"))
        #expect(!apostrophe.contains("Aaron Fox"))
        #expect(ContextExtractor.extract(from: "Ask 'Victor Wembanyama' about Victor Wembanyama's minutes.").contains("Victor Wembanyama"))
    }

    @Test("the delivered text keeps the screen's spelling of an identifier")
    func deliveredSpelling() {
        let settings = PipelineSettings(contextTerms: ["GPT-4o", "rl-v10b"])
        #expect(DictationPipeline.screenSpelling("Switch the default model to GPT4o Mini.", settings: settings)
            == "Switch the default model to GPT-4o Mini.")
        #expect(DictationPipeline.screenSpelling("The run name is rl-v910b.", settings: settings) == "The run name is rl-v910b.")
        #expect(DictationPipeline.screenSpelling("GPT 40 is fine", settings: settings) == "GPT 40 is fine")
    }

    @Test("a joined identifier is protected: the model may not add a digit to it")
    func protection() {
        let draft = ScreenIdentifierJoiner.join("It mistook RL V9 as RL V9", terms: ["rl-v9"])
        #expect(draft == "It mistook rl-v9 as rl-v9")
        #expect(ProtectedTermGuard.violation(answer: "It mistook rl-v99 for rl-v99.", draft: draft, terms: ["rl-v9"]) != nil)
        #expect(ProtectedTermGuard.violation(answer: "It mistook rl-v9 for rl-v9.", draft: draft, terms: ["rl-v9"]) == nil)
    }
}

private struct SilentTranscriber: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}
