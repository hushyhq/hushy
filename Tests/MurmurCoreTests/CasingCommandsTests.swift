import Testing
@testable import MurmurCore

@Suite("CasingCommands")
struct CasingCommandsTests {
    @Test("casing conversions", arguments: [
        ("camel case get user by id", "getUserById"),
        ("snake case max retries", "max_retries"),
        ("pascal case user profile", "UserProfile"),
        ("constant max retries", "MAX_RETRIES"),
        ("camel case x", "x"),
        ("snake case a b c", "a_b_c"),
    ])
    func casingConversions(input: String, expected: String) {
        #expect(CasingCommands.apply(input) == expected)
    }

    @Test("casing command mid-sentence converts only its own phrase")
    func midSentence() {
        let result = CasingCommands.apply("call camel case get user by id, then log it")
        #expect(result == "call getUserById, then log it")
    }

    @Test("two casing commands in one utterance each convert independently")
    func twoCommands() {
        let result = CasingCommands.apply("camel case get user by id, snake case max retries")
        #expect(result == "getUserById, max_retries")
    }

    @Test("casing keyword with nothing after it is left alone")
    func noPhrase() {
        #expect(CasingCommands.apply("camel case") == "camel case")
    }
}

@Suite("CodeSymbols")
struct CodeSymbolsTests {
    @Test("symbol words become punctuation", arguments: [
        ("get dot name", "get.name"),
        ("open paren x close paren", "(x)"),
        ("returns arrow void", "returns->void"),
        ("get user open paren id close paren", "get user (id)"),
        ("open paren id close paren", "(id)"),
    ])
    func symbolWords(input: String, expected: String) {
        #expect(CodeSymbols.apply(input) == expected)
    }

    @Test("open paren at the very start of the text gets no leading space")
    func openParenAtStart() {
        #expect(CodeSymbols.apply("open paren x close paren") == "(x)")
    }

    @Test("chained dot access stays dense on both sides")
    func chainedDotAccess() {
        #expect(CodeSymbols.apply("user dot profile dot name") == "user.profile.name")
    }
}

@Suite("Code context in TextCleaner")
struct CodeContextTextCleanerTests {
    @Test("casing commands run only when isCodeContext is set")
    func gatedByCodeContext() {
        let codeCleaner = TextCleaner(options: CleanupOptions(isCodeContext: true))
        #expect(codeCleaner.clean("camel case get user by id").text == "getUserById")

        let proseCleaner = TextCleaner(options: CleanupOptions(isCodeContext: false))
        #expect(proseCleaner.clean("camel case get user by id").text == "Camel case get user by id.")
    }

    @Test("code context never capitalizes or auto-punctuates")
    func noAutoPunctuation() {
        let codeCleaner = TextCleaner(options: CleanupOptions(isCodeContext: true))
        #expect(codeCleaner.clean("const value is five").text == "const value is five")
    }

    @Test("code context preserves an already-typed identifier's casing")
    func preservesLiteralCasing() {
        let codeCleaner = TextCleaner(options: CleanupOptions(isCodeContext: true))
        #expect(codeCleaner.clean("getUserById returns a promise").text == "getUserById returns a promise")
    }

    @Test("non-code prose containing the word dot is untouched", arguments: [
        ("connect the dot to the line", "Connect the dot to the line."),
        ("the arrow points north", "The arrow points north."),
        ("camel case", "Camel case"),
    ])
    func proseWordsUntouched(input: String, expected: String) {
        let proseCleaner = TextCleaner(options: CleanupOptions(isCodeContext: false))
        #expect(proseCleaner.clean(input).text == expected)
    }

    @Test("code context still runs voice commands like new line")
    func voiceCommandsStillWork() {
        let codeCleaner = TextCleaner(options: CleanupOptions(isCodeContext: true))
        #expect(codeCleaner.clean("first line, new line, second line").text == "first line\nsecond line")
    }

    @Test("file tag resolves only when the file exists in project vocabulary")
    func fileTagResolution() {
        let vocabulary = ProjectVocabulary(identifiers: [], fileNames: ["index.tsx", "app.tsx"])
        var options = CleanupOptions(isCodeContext: true)
        options.projectVocabulary = vocabulary
        let cleaner = TextCleaner(options: options)
        #expect(cleaner.clean("open at index dot tsx").text == "open @index.tsx")
        #expect(cleaner.clean("tag file index tsx").text == "@index.tsx")
    }

    @Test("file tag does not fire for a file that doesn't exist in the project")
    func fileTagMisses() {
        let vocabulary = ProjectVocabulary(identifiers: [], fileNames: ["index.tsx"])
        var options = CleanupOptions(isCodeContext: true)
        options.projectVocabulary = vocabulary
        let cleaner = TextCleaner(options: options)
        let result = cleaner.clean("meet me at noon tsx")
        #expect(!result.text.contains("@"))
    }

    @Test("no project vocabulary means at and tag file stay literal words")
    func noVocabularyLeavesLiteral() {
        let cleaner = TextCleaner(options: CleanupOptions(isCodeContext: true))
        #expect(cleaner.clean("meet me at noon").text == "meet me at noon")
    }
}

@Suite("ProjectVocabulary matching")
struct ProjectVocabularyMatchTests {
    @Test("exact match wins")
    func exactMatch() {
        let vocab = ProjectVocabulary(identifiers: ["getUserById"], fileNames: [])
        #expect(vocab.matchIdentifier("getUserById") == "getUserById")
    }

    @Test("near-exact match resolves a single-character miss on a long word")
    func nearExactMatch() {
        let vocab = ProjectVocabulary(identifiers: ["Supabase"], fileNames: [])
        #expect(vocab.matchIdentifier("Supabese") == "Supabase")
    }

    @Test("short words require an exact match")
    func shortWordsExact() {
        let vocab = ProjectVocabulary(identifiers: ["cat"], fileNames: [])
        #expect(vocab.matchIdentifier("car") == nil)
    }

    @Test("no match when nothing is close")
    func noMatch() {
        let vocab = ProjectVocabulary(identifiers: ["getUserById"], fileNames: [])
        #expect(vocab.matchIdentifier("completelyDifferentName") == nil)
    }

    @Test("empty vocabulary matches nothing")
    func emptyVocabulary() {
        #expect(ProjectVocabulary.empty.matchIdentifier("anything") == nil)
    }
}
