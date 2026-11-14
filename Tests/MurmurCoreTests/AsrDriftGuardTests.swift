import Testing
@testable import MurmurCore

@Suite("AsrDriftGuard")
struct AsrDriftGuardTests {
    /// Small fixed list so the tests never depend on the machine's /usr/share/dict/words.
    private let words: Set<String> = [
        "yes", "no", "thanks", "sounds", "good", "on", "it", "ship", "call", "me", "perfect", "got",
        "see", "you", "soon", "done", "let", "go", "morning", "thank", "so", "much", "the", "build",
        "is", "failing", "main", "branch", "please", "add", "milk", "and", "eggs", "to", "list",
        "invite", "voice", "meet", "at", "nine", "tomorrow", "stop", "run", "late", "today",
    ]

    private func decide(_ text: String) -> AsrDriftGuard.Decision {
        AsrDriftGuard.decision(for: text, englishWords: words)
    }

    // MARK: Long inputs — language ID

    @Test("accepts ordinary English sentences")
    func acceptsEnglishSentence() {
        #expect(decide("Can you send me the report by Friday? Thanks for the quick turnaround.") == .accept)
        #expect(decide("The build is failing on the main branch, please add milk and eggs to the list.") == .accept)
    }

    @Test("falls back on a confident non-English Latin-script sentence (the whisper-into-Polish case)")
    func fallsBackOnPolish() {
        #expect(decide("Dziękuję bardzo, proszę wysłać mi raport do piątku.") == .fallback(.nonEnglishLanguage))
        #expect(decide("Gracias por la respuesta rápida, nos vemos mañana por la mañana.") == .fallback(.nonEnglishLanguage))
    }

    @Test("falls back when an opening sentence drifts but the rest is English")
    func fallsBackOnPartialDrift() {
        #expect(decide("Gracias por la respuesta rápida, nos vemos mañana. The build is failing on the main branch, please add milk and eggs to the list.") == .fallback(.nonEnglishLanguage))
    }

    @Test("falls back on non-Latin script regardless of length")
    func fallsBackOnNonLatinScript() {
        #expect(decide("Спасибо большое") == .fallback(.nonLatinScript))
        #expect(decide("Да") == .fallback(.nonLatinScript))
        #expect(decide("Ευχαριστώ πολύ για την γρήγορη απάντηση") == .fallback(.nonLatinScript))
    }

    // MARK: Short inputs — word list, not language ID

    @Test("accepts 1–3 word English dictations the recognizer cannot classify")
    func acceptsShortEnglish() {
        for phrase in ["Yes.", "No.", "Thanks!", "Sounds good.", "On it.", "Ship it.", "Call me.", "Got it.",
                       "See you soon.", "Let's go.", "Good morning.", "Thank you so much.", "Done."] {
            #expect(decide(phrase) == .accept, "\(phrase)")
        }
    }

    @Test("falls back on 1–3 words that are not English")
    func fallsBackOnShortForeign() {
        #expect(decide("Tak.") == .fallback(.unrecognizedShortWords))
        #expect(decide("Dziękuję bardzo.") == .fallback(.unrecognizedShortWords))
        #expect(decide("Merci beaucoup.") == .fallback(.unrecognizedShortWords))
        #expect(decide("Sí, señor.") == .fallback(.unrecognizedShortWords))
    }

    @Test("a majority of known words carries an unknown name")
    func majorityRuleKeepsNames() {
        #expect(decide("Call Priya.") == .accept)
        #expect(decide("Ship it Priya") == .accept)
    }

    @Test("spoken contractions and fillers count as English")
    func contractionsAreEnglish() {
        #expect(decide("Okay, don't.") == .accept)
        #expect(decide("It's done.") == .accept)
        #expect(decide("Yeah okay") == .accept)
    }

    @Test("digits and punctuation are neutral")
    func digitsAreNeutral() {
        #expect(decide("42") == .accept)
        #expect(decide("...") == .accept)
        #expect(decide("Call me at 9.") == .accept)
    }

    @Test("a short spoken address still gets a second reading")
    func spokenAddressesStillFallBack() {
        for phrase in ["lantern.example", "Openlantern.example"] {
            #expect(decide(phrase) == .fallback(.unrecognizedShortWords), "\(phrase)")
        }
    }

    @Test("a fallback cannot add a repeated piece of the primary reading")
    func rejectsRepeatedFallbackMaterial() {
        #expect(!AsrDriftGuard.acceptsFallback(primary: "Openlantern.example", fallback: "Open lantern.example.example"))
        #expect(!AsrDriftGuard.acceptsFallback(primary: "lantern.example", fallback: "Lantern.example Lantern."))
        #expect(AsrDriftGuard.acceptsFallback(primary: "Openlantern.example", fallback: "Open lantern.example."))
        #expect(AsrDriftGuard.acceptsFallback(primary: "Gracias por favor", fallback: "Please go ahead."))
    }

    @Test("empty transcript is accepted (nothing to fall back for)")
    func emptyIsAccepted() {
        #expect(decide("") == .accept)
        #expect(decide("   \n") == .accept)
    }

    @Test("without a word list the short rule degrades to the script check only")
    func noWordListAcceptsAscii() {
        #expect(AsrDriftGuard.decision(for: "Tak.", englishWords: []) == .accept)
        #expect(AsrDriftGuard.decision(for: "Да", englishWords: []) == .fallback(.nonLatinScript))
    }

    @Test("the shipped word table accepts the eval's short phrases")
    func systemWordListAcceptsEvalPhrases() throws {
        try #require(WordFrequency.shared.entryCount > 50_000)
        for phrase in ["Yes.", "No.", "Thanks!", "Sounds good.", "On it.", "Ship it.", "Call me.", "Perfect.",
                       "Got it.", "See you soon.", "Approved.", "Not today.", "Done.", "Maybe later.", "Love it.",
                       "Running late.", "Agreed.", "Let's go.", "Good morning.", "Thank you so much."] {
            #expect(AsrDriftGuard.decision(for: phrase) == .accept, "\(phrase)")
        }
    }
}
