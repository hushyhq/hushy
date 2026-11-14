import Testing
@testable import MurmurCore

/// Code-context dictation rules (Task 80): casing commands inside a sentence, a closed spoken-symbol
/// grammar, flags, comment delimiters, identifier numbers and the list/paragraph collisions. Every
/// sentence here is invented for these tests; none is from the `code-natural-dev` set.
@Suite("Code dictation rules")
struct CodeRulesTests {
    private func code(_ spoken: String) -> String {
        TextCleaner(options: CleanupOptions(level: .clean, voiceCommandsEnabled: true, isCodeContext: true))
            .clean(spoken).text
    }

    // MARK: Casing commands inside a sentence

    @Test("an embedded casing command ends at a boundary word", arguments: [
        ("rename it to camel case fetch order status", "rename it to fetchOrderStatus"),
        ("call snake case load config after the build finishes", "call load_config after the build finishes"),
        ("the variable is pascal case order line and it is private", "the variable is OrderLine and it is private"),
        ("use kebab case release notes for the file name", "use release-notes for the file name"),
        ("name the flag constant case max batch size please", "name the flag MAX_BATCH_SIZE please"),
        ("set constant max pool size", "set MAX_POOL_SIZE"),
        ("add a field camel case is valid and document it", "add a field isValid and document it"),
    ])
    func embeddedCasing(spoken: String, expected: String) {
        #expect(code(spoken) == expected)
    }

    @Test("a soft preposition stays inside the identifier unless a determiner follows")
    func softPrepositions() {
        #expect(code("call camel case created at after saving") == "call createdAt after saving")
        #expect(code("call snake case number of items in the cart") == "call number_of_items in the cart")
        #expect(code("call snake case sort by the date") == "call sort by the date")
    }

    @Test("known limit: a strong small word cuts an identifier that contains it")
    func documentedLimits() {
        #expect(code("call camel case sync to disk") == "call sync to disk")
        #expect(code("call snake case load from cache") == "call load from cache")
    }

    @Test("a casing command that opens the utterance keeps taking every word")
    func startModeUnchanged() {
        #expect(code("camel case sync to disk after saving") == "syncToDiskAfterSaving")
        #expect(code("pascal case parse header, snake case retry count") == "ParseHeader, retry_count")
        #expect(code("kebab case pull request template") == "pull-request-template")
        #expect(code("constant case default timeout") == "DEFAULT_TIMEOUT")
    }

    @Test("chained casing commands each convert, with a space between")
    func chained() {
        #expect(code("snake case user name camel case user name") == "user_name userName")
    }

    @Test("casing words used as ordinary nouns are left alone", arguments: [
        "the camel case style is popular here",
        "a constant value is needed",
        "that is the camel case",
        "we talked about snake case",
    ])
    func casingNouns(spoken: String) {
        #expect(code(spoken) == spoken)
    }

    // MARK: Symbols

    @Test("assignment and comparison symbols", arguments: [
        ("retries equals three", "retries = 3"),
        ("total double equals zero", "total == 0"),
        ("count colon equals zero", "count := 0"),
        ("user underscore id equals zero", "user_id = 0"),
        ("limit equals open bracket close bracket", "limit = []"),
        ("final double equals zero", "final double = 0"),
        ("let float equals one", "let float = 1"),
        ("stock open bracket key close bracket", "stock[key]"),
    ])
    func assignments(spoken: String, expected: String) {
        #expect(code(spoken) == expected)
    }

    @Test("quotes, brackets and braces")
    func quotesAndBrackets() {
        #expect(code("names equals open bracket quote alpha quote comma quote beta quote close bracket")
            == "names = [\"alpha\", \"beta\"]")
        #expect(code("config equals open brace port colon eight thousand eighty close brace")
            == "config = {port: 8080}")
        #expect(code("triple quote returns the parsed header triple quote") == "\"\"\"returns the parsed header\"\"\"")
        #expect(code("title equals single quote done single quote") == "title = 'done'")
    }

    @Test("fat arrow, member access and calls")
    func arrowsAndCalls() {
        #expect(code("items dot map open paren item fat arrow item dot id close paren") == "items.map(item => item.id)")
        #expect(code("cache dot get open paren key close paren") == "cache.get(key)")
        // Task 83: a name that opens the line is a call, so its parenthesis is tight ("print(x)").
        #expect(code("run open paren job close paren fat arrow job dot id") == "run(job) => job.id")
        #expect(code("get user open paren id close paren") == "get user (id)")
        #expect(CodeSymbols.apply("open paren x close paren then y") == "(x) then y")
    }

    @Test("paths, URLs and ports")
    func pathsAndUrls() {
        #expect(code("copy config slash staging dot yaml to backups slash") == "copy config/staging.yaml to backups/")
        #expect(code("curl http colon slash slash localhost colon eight thousand eighty slash health")
            == "curl http://localhost:8080/health")
        #expect(code("port colon eight thousand eighty") == "port: 8080")
        #expect(code("max equals one thousand") == "max = 1000")
    }

    // MARK: Flags and comment delimiters

    @Test("short and long flags", arguments: [
        ("tar dash x z f archive dot tar dot gz", "tar -xzf archive.tar.gz"),
        ("cargo build dash dash release", "cargo build --release"),
        ("pip install dash dash upgrade requests", "pip install --upgrade requests"),
        ("git commit dash a m quote fix typo quote", "git commit -am \"fix typo\""),
        ("git push dash dash force with lease", "git push --force-with-lease"),
        ("npm install dash dash save dev typescript", "npm install --save-dev typescript"),
        ("git checkout dash dash config dot yaml", "git checkout -- config.yaml"),
        ("dash dash dash dash mode", "-- --mode"),
        ("tar dash x dash f archive dot tar", "tar -x -f archive.tar"),
        ("pip install dash r requirements dot txt", "pip install -r requirements.txt"),
        ("docker run dash dash rm dash p image", "docker run --rm -p image"),
    ])
    func flags(spoken: String, expected: String) {
        #expect(code(spoken) == expected)
    }

    @Test("comment delimiters count at the start of the utterance", arguments: [
        ("slash slash retry only on timeouts", "// retry only on timeouts"),
        ("hash remember to rotate this key every quarter", "# remember to rotate this key every quarter"),
        ("hash keep these entries sorted by name", "# keep these entries sorted by name"),
        ("dash dash fetch the latest rows before filtering them", "-- fetch the latest rows before filtering them"),
        ("slash slash the user underscore id is required", "// the user_id is required"),
    ])
    func comments(spoken: String, expected: String) {
        #expect(code(spoken) == expected)
    }

    @Test("a starting hash before a determiner, possessive or pronoun is the verb, not a comment marker", arguments: [
        "hash the password before storing it",
        "hash a copy of the token before logging it",
        "hash this value with the salt first",
        "hash their emails before sending the report",
        "hash it with sha256 before saving",
        "hash our session ids before they reach the logs",
    ])
    func hashVerbStaysAWord(spoken: String) {
        #expect(code(spoken) == spoken)
    }

    @Test("known limit: a comment that opens with hash and a determiner is not converted")
    func hashCommentWithDeterminerIsMissed() {
        #expect(code("hash the input here so the cache key stays stable") == "hash the input here so the cache key stays stable")
    }

    @Test("a symbol word inside a comment stays a word", arguments: [
        ("slash slash the count equals zero when the list is empty", "// the count equals zero when the list is empty"),
        ("slash slash add a comma after the second argument", "// add a comma after the second argument"),
    ])
    func commentProse(spoken: String, expected: String) {
        #expect(code(spoken) == expected)
    }

    // MARK: Ordinary speech stays as spoken

    @Test("ordinary speech with a symbol word is untouched", arguments: [
        "please add a comma after the name",
        "put a colon at the end of the line",
        "the semicolon is missing here",
        "the quote came from the customer",
        "the answer equals the total of both columns",
        "equals is a method on the comparable protocol",
        "it equals zero most of the time",
        "a dash of salt goes a long way",
        "use an em dash in the headline",
        "the forward slash key is next to the shift key",
        "we slash and burn the old branches",
        "we should underscore the importance of tests",
        "hash map lookups are faster here than list scans",
        "fat arrow functions are hard to read",
        "the comma separated values need quoting",
        "this column holds comma separated values",
        "we need an open bracket here and a close brace there",
        "the single quote and the double quote look alike",
        "a triple quote string has no closer here",
        "add a new paragraph style to the editor",
        "we should use the new paragraph element here",
        "let me know when the build finishes",
    ])
    func ordinarySpeech(spoken: String) {
        #expect(code(spoken) == spoken)
    }

    // MARK: Paragraph breaks and lists

    @Test("new paragraph mid-utterance breaks the text in a code context")
    func newParagraph() {
        #expect(code("fix the stale cache lookup new paragraph the invalidation never ran after deploy")
            == "fix the stale cache lookup\n\nthe invalidation never ran after deploy")
        #expect(code("short one new paragraph two words") == "short one new paragraph two words")
    }

    @Test("dash is a flag word, never a bullet, in a code context")
    func dashNeverBullets() {
        #expect(ListFormatter.format("dash dash dash dash mode", codeContext: true) == "dash dash dash dash mode")
        #expect(ListFormatter.format("dash eggs dash flour").hasPrefix("- "))
    }
}

@Suite("Identifier numbers in code context")
struct CodeIdentifierNumbersTests {
    @Test("colon and equals are identifier nouns only in a code context")
    func codeOnly() {
        #expect(InverseTextNormalizer.apply("localhost colon eight thousand eighty", codeContext: true) == "localhost colon 8080")
        #expect(InverseTextNormalizer.apply("localhost colon eight thousand eighty") == "localhost colon 8,080")
        #expect(InverseTextNormalizer.apply("the ratio equals three thousand") == "the ratio equals 3,000")
        #expect(InverseTextNormalizer.apply("the ratio equals three thousand", codeContext: true) == "the ratio equals 3000")
    }

    @Test("work chat and email keep their thousands separator and their words")
    func proseUnchanged() {
        let chat = TextCleaner(options: CleanupOptions(level: .clean))
        #expect(chat.clean("about two thousand people came").text == "About 2,000 people came.")
        #expect(chat.clean("localhost colon eight thousand eighty").text.contains("8,080"))
        let spoken = "retries equals three and the fat arrow functions need a comma and a slash"
        let out = chat.clean(spoken).text
        for symbol in ["=", "=>", ",", "/"] where symbol != "," { #expect(!out.contains(symbol), Comment(rawValue: out)) }
        #expect(chat.clean("dash eggs dash flour").text.contains("- "))
    }
}
