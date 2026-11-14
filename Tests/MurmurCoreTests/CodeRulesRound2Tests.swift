import Testing
@testable import MurmurCore

/// Code-context dictation rules, round two (Task 83). Every sentence is invented for these tests.
/// Each rule has two sides: the spoken shape that must convert, and a look-alike in ordinary speech
/// that must stay words, because the same words are plain English outside a code line.
@Suite("Code dictation rules, round two", .timeLimit(.minutes(1)))
struct CodeRulesRound2Tests {
    private func code(_ spoken: String) -> String {
        TextCleaner(options: CleanupOptions(level: .clean, voiceCommandsEnabled: true, isCodeContext: true))
            .clean(spoken).text
    }

    private func check(_ cases: [(String, String)]) {
        for (spoken, expected) in cases {
            let actual = code(spoken)
            #expect(actual == expected, Comment(rawValue: "\(spoken) -> \(actual) (wanted \(expected))"))
        }
    }

    // MARK: 1. A casing command ends where the next clause starts

    @Test("a casing command that opens the line stops at a clause word or a determiner phrase")
    func casingStopsAtClause() {
        check([
            ("snake case request id and then retry", "request_id and then retry"),
            ("camel case load config then call it", "loadConfig then call it"),
            ("pascal case job runner but skip the tests", "JobRunner but skip the tests"),
            ("kebab case release notes because the file moved", "release-notes because the file moved"),
            ("camel case parse header in the module and then stop", "parseHeader in the module and then stop"),
            ("snake case user name or the group name", "user_name or the group name"),
        ])
    }

    @Test("a casing command keeps a conjunction or preposition that sits inside the name")
    func casingKeepsInnerWords() {
        check([
            ("snake case read and write mode", "read_and_write_mode"),
            ("camel case sync to disk after saving", "syncToDiskAfterSaving"),
            ("pascal case save in memory", "SaveInMemory"),
            ("camel case user name should be required", "userNameShouldBeRequired"),
        ])
    }

    // MARK: 2. Number words that are whole elements of a bracket or parenthesis

    @Test("a lone digit word between separators inside brackets is a digit")
    func bracketNumbers() {
        check([
            ("grid open bracket row comma four close bracket", "grid[row, 4]"),
            ("open paren seven comma eight comma nine close paren", "(7, 8, 9)"),
            ("scale open paren x comma two close paren", "scale(x, 2)"),
            ("cells open bracket six close bracket open bracket one close bracket", "cells[6][1]"),
        ])
    }

    @Test("a number word that belongs to a phrase inside brackets stays a word")
    func bracketNumbersKeepWords() {
        check([
            ("note it open paren two of the three cases close paren", "note it (two of the three cases)"),
            ("sleep open paren three seconds close paren", "sleep (three seconds)"),
            ("pick one of the two", "pick one of the two"),
        ])
    }

    // MARK: 3. dash plus a number word

    @Test("dash and a digit after a command is a numeric flag")
    func numericFlag() {
        check([
            ("kill dash six", "kill -6"),
            ("head dash four server dot log", "head -4 server.log"),
            ("sudo kill dash nine", "sudo kill -9"),
            ("tail dash eight events dot log", "tail -8 events.log"),
        ])
    }

    @Test("dash and a number in a sentence about a dash stays words")
    func numericFlagKeepsWords() {
        check([
            ("it was a dash six times", "it was a dash six times"),
            ("run the dash two laps", "run the dash two laps"),
            ("a long dash seven miles", "a long dash seven miles"),
            ("the relay dash three times", "the relay dash three times"),
        ])
    }

    // MARK: 4. No space between a call name and its parenthesis

    @Test("a call name that opens a statement or follows an operator takes its parenthesis tight")
    func callSpacing() {
        check([
            ("emit open paren event close paren", "emit(event)"),
            ("total equals sum open paren values close paren", "total = sum(values)"),
            ("return parse open paren line close paren", "return parse(line)"),
            ("n equals len open paren rows close paren", "n = len(rows)"),
            ("clamp open paren x comma zero comma ten close paren", "clamp(x, 0, 10)"),
        ])
    }

    @Test("a keyword or a word inside a sentence keeps its space before a parenthesis")
    func callSpacingKeepsSpace() {
        check([
            ("for open paren item close paren", "for (item)"),
            ("switch open paren mode close paren", "switch (mode)"),
            ("the old name open paren legacy close paren", "the old name (legacy)"),
            ("see below open paren two options close paren", "see below (two options)"),
        ])
    }

    // MARK: 5. Openers that follow each other

    @Test("an opener right after another opener takes no space")
    func openerRuns() {
        check([
            ("open bracket open brace a close brace close bracket", "[{a}]"),
            ("open paren open bracket x close bracket close paren", "([x])"),
            ("call open paren open paren a close paren close paren", "call((a))"),
            ("open bracket open paren one comma two close paren close bracket", "[(1, 2)]"),
        ])
    }

    @Test("an opener after a word or an operator keeps its space")
    func openersKeepSpace() {
        check([
            ("total equals open paren a comma b close paren", "total = (a, b)"),
            ("and open paren ready close paren", "and (ready)"),
            ("yield open paren a close paren", "yield (a)"),
        ])
    }

    // MARK: 6. Words inside a spoken quoted string stay words

    @Test("symbol words inside a spoken quote pair are text")
    func quotedStringWords() {
        check([
            ("print quote start dot end quote", "print \"start dot end\""),
            ("log single quote open paren ok close paren single quote", "log 'open paren ok close paren'"),
            ("title equals quote camel case name quote", "title = \"camel case name\""),
            ("fail quote the arrow is missing quote", "fail \"the arrow is missing\""),
        ])
    }

    @Test("a quote pair around one symbol word spells that symbol")
    func quotedSymbol() {
        check([
            ("split on quote colon quote", "split on \":\""),
            ("join with quote dash quote", "join with \"-\""),
            ("strip quote dot quote", "strip \".\""),
            ("print quote hello quote", "print \"hello\""),
        ])
    }

    // MARK: 7. A path that ends in a slash, then ordinary words

    @Test("a path that ends in a slash before a function word keeps the slash")
    func trailingSlash() {
        check([
            ("cd logs slash then ls", "cd logs/ then ls"),
            ("ls build slash and cat notes dot txt", "ls build/ and cat notes.txt"),
            ("rm out slash to start clean", "rm out/ to start clean"),
            ("ls src slash lib slash and then stop", "ls src/lib/ and then stop"),
        ])
    }

    @Test("slash used as a verb or after a pronoun stays a word")
    func slashVerb() {
        check([
            ("they slash and then rebuild the budget", "they slash and then rebuild the budget"),
            ("we slash the price to the bone", "we slash the price to the bone"),
            ("prices slash and then recover", "prices slash and then recover"),
        ])
    }

    // MARK: 8. dot and arrow in ordinary speech

    @Test("dot and arrow after a determiner or before a function word or verb are nouns")
    func ordinaryDotArrow() {
        check([
            ("the dot in the corner is gray", "the dot in the corner is gray"),
            ("the arrow points down", "the arrow points down"),
            ("an arrow to the exit", "an arrow to the exit"),
            ("a blue dot on the chart", "a blue dot on the chart"),
            ("this arrow looks wrong", "this arrow looks wrong"),
        ])
    }

    @Test("dot and arrow between code words still convert")
    func codeDotArrow() {
        check([
            ("order dot total", "order.total"),
            ("settings dot json", "settings.json"),
            ("node arrow next", "node->next"),
            ("self dot items arrow count", "self.items->count"),
            ("package dot json arrow name", "package.json->name"),
        ])
    }
    // MARK: 9. Names, paths and numbers spoken in pieces

    @Test("a one or two letter part inside a dotted or slashed chain is kept")
    func chainKeepsShortParts() {
        check([
            ("x dot y dot z", "x.y.z"),
            ("cfg dot db dot host", "cfg.db.host"),
            ("src slash a slash b", "src/a/b"),
            ("node arrow p arrow q", "node->p->q"),
            // Outside a separator chain a stray letter inside a repeated lead-in is still dropped.
            ("in the w in the above sentence", "in the above sentence"),
        ])
    }

    @Test("dash joins the parts of a hyphenated name where a path or a name command shows it")
    func kebabNames() {
        check([
            ("src slash user dash profile slash components", "src/user-profile/components"),
            ("git checkout dash b feature slash login dash page", "git checkout -b feature/login-page"),
            ("cd my dash app", "cd my-app"),
            ("open login dash page dot tsx", "open login-page.tsx"),
            ("cd packages slash my dash lib dash core", "cd packages/my-lib-core"),
        ])
    }

    @Test("dash after an article or before a function word stays a word")
    func dashKeepsWords() {
        check([
            ("the dash on the left is too long", "the dash on the left is too long"),
            ("the em dash looks wrong here", "the em dash looks wrong here"),
            ("press dash to go back", "press dash to go back"),
            ("touch the dash file", "touch the dash file"),
        ])
    }

    @Test("dots that stand for the parent or current directory keep a space before them")
    func relativePaths() {
        check([
            ("cd dot dot", "cd .."),
            ("cd dot dot slash dot dot slash lib", "cd ../../lib"),
            ("ls dot slash src", "ls ./src"),
            ("cat dot dot slash config dot yaml", "cat ../config.yaml"),
        ])
        check([
            ("dot product of two vectors", "dot product of two vectors"),
            ("the dot slash is a path prefix", "the dot slash is a path prefix"),
        ])
    }

    @Test("digits read out one after another are one number, a plain count is not")
    func digitRuns() {
        check([
            ("docker run dash p eight zero eight zero colon eighty", "docker run -p 8080:80"),
            ("set timeout to one two zero", "set timeout to 120"),
            ("list open bracket zero colon three close bracket", "list[0:3]"),
            ("one two three go", "one two three go"),
            ("count down five four three two one", "count down five four three two one"),
            ("one two", "one two"),
        ])
    }
}
