import Testing
@testable import MurmurCore

/// Spoken technical tokens written the way a developer types them, in work messages and email
/// only. Every class has conversions and sentences that must stay exactly as they are: a wrong
/// conversion is worse than a missed one.
@Suite("Spoken technical tokens")
struct SpokenTechnicalTokensTests {
    private static let plain = TechnicalTokenContext()
    private static let linearTab = TechnicalTokenContext(windowTitle: "ENG-1510 Cache stampede on cold start - Acme - Linear")

    private func apply(_ text: String, _ context: TechnicalTokenContext = plain) -> String {
        SpokenTechnicalTokens.apply(text, context: context)
    }

    private func expectUnchanged(_ inputs: [String], _ context: TechnicalTokenContext = plain) {
        for input in inputs {
            #expect(apply(input, context) == input, Comment(rawValue: "changed: \(input) -> \(apply(input, context))"))
        }
    }

    private func expect(_ pairs: [(String, String)], _ context: TechnicalTokenContext = plain) {
        for (input, expected) in pairs {
            #expect(apply(input, context) == expected, Comment(rawValue: "\(input) -> \(apply(input, context))"))
        }
    }

    // MARK: Paths, branches, flags

    @Test("a file extension is the evidence for a spoken path")
    func extensionPaths() {
        expect([
            ("the config lives in config slash staging dot yaml not in the helm chart",
             "the config lives in config/staging.yaml not in the helm chart"),
            ("look in src slash api slash handlers slash user dot ts for the error",
             "look in src/api/handlers/user.ts for the error"),
            ("the setting is in package dot json", "the setting is in package.json"),
            ("edit user underscore settings slash defaults dot yaml first",
             "edit user_settings/defaults.yaml first"),
            ("it is in webpack dot config dot js", "it is in webpack.config.js"),
        ])
    }

    @Test("two or more slashes between words make a path")
    func multiSlashPaths() {
        expect([("it is under dev slash staging slash prod", "it is under dev/staging/prod")])
    }

    @Test("a branch prefix with git context makes a branch name")
    func branchNames() {
        expect([
            ("i am going to force push to feature slash retry dash logic in five minutes",
             "i am going to force push to feature/retry-logic in five minutes"),
            ("i rebased fix slash token dash refresh onto main", "i rebased fix/token-refresh onto main"),
        ])
    }

    @Test("a double dash is a long flag, and no attaches to the next word")
    func longFlags() {
        expect([
            ("please do not pass dash dash no verify here", "please do not pass --no-verify here"),
            ("run it with dash dash force and see", "run it with --force and see"),
            ("use dash dash dry dash run first", "use --dry-run first"),
        ])
    }

    @Test("ordinary uses of slash, dash, dot and underscore stay words")
    func pathTraps() {
        expectUnchanged([
            "we should slash the budget",
            "i'll dash over after lunch",
            "there is a dot on the screen",
            "he made a dash for the door",
            "use a dash instead of a comma",
            "type underscore twice",
            "there is an underscore in the name",
            "connect the dots between the cards",
            "add a dot after the name",
            "it is a yes slash no question",
            "prices slash costs went up again",
            "this is a feature slash bug in the parser",
            "the test slash prod split is confusing",
            "she said dash dash and left",
            "we can slash the budget and dash out early",
            "the dot com bubble burst",
            "call profile dot name before the check",
            "write the dot go file later",
            "rename the dot yaml extension",
            "release slash patch notes are ready",
        ])
    }

    // MARK: Percentiles

    @Test("p plus a spoken number with latency evidence is a percentile")
    func percentiles() {
        expect([
            ("p 99 latency dropped to 120 milliseconds", "p99 latency dropped to 120 milliseconds"),
            ("traffic is fine and p 95 is two seconds", "traffic is fine and p95 is two seconds"),
            ("our p 50 looks healthy", "our p50 looks healthy"),
            ("the p 999 spiked overnight", "the p999 spiked overnight"),
            ("the response time p 99.9 is flat", "the response time p99.9 is flat"),
        ])
    }

    @Test("a lone p before a number without percentile evidence stays")
    func percentileTraps() {
        expectUnchanged([
            "p 99% of the time it works",
            "see p 50 for details",
            "plan p 90 is for later",
            "option p 75 was rejected",
            "p 99 bottles of beer",
            "p 12 latency is high",
            "the p 99 percent figure is made up",
            "p99 latency dropped",
        ])
    }

    // MARK: PR numbers

    @Test("pr followed by digits is written PR with the number")
    func pullRequests() {
        expect([
            ("fixed in pr 482 will be out next", "fixed in PR 482 will be out next"),
            ("we shipped a hotfix in pr 1187", "we shipped a hotfix in PR 1187"),
            ("PR 482 is merged", "PR 482 is merged"),
        ])
    }

    @Test("pr without a number and counts after issue stay")
    func pullRequestTraps() {
        expectUnchanged([
            "the pr team will review it",
            "i opened the pr 2 days ago",
            "can you review my pr when you have a minute",
            "the issue two of us saw is fixed",
            "we have issue 3 files changed",
            "the issue 482 is closed",
            "pr 5 files changed",
            "pr two of the reviewers agree",
        ])
    }

    // MARK: Regions

    @Test("a region needs prefix, direction and number plus infrastructure evidence")
    func regions() {
        expect([
            ("traffic is shifted to us east one and latency dropped", "traffic is shifted to us-east-1 and latency dropped"),
            ("we failed over to eu west two last night", "we failed over to eu-west-2 last night"),
            ("the bucket lives in ap southeast 2", "the bucket lives in ap-southeast-2"),
            ("the cluster in us west two is healthy", "the cluster in us-west-2 is healthy"),
            ("deploy to eu central one first", "deploy to eu-central-1 first"),
            ("traffic moved to US East 1 overnight", "traffic moved to us-east-1 overnight"),
        ])
    }

    @Test("us east one in an ordinary sentence is not a region")
    func regionTraps() {
        expectUnchanged([
            "give us east one of those boxes",
            "he drove us east one more mile",
            "they told us west two weeks ago",
            "send us east 100 miles of cable",
            "a map of the us east coast",
            "walk with us east one block",
            "tell us west two and we will go",
            "the eu west two options are open",
            "traffic is shifted to us east and latency dropped",
            "we deployed it and drove us east one mile",
        ])
    }

    // MARK: Ticket IDs

    @Test("a key that is in the tab title becomes a ticket id")
    func ticketFromTitle() {
        expect([
            ("this looks like a duplicate of eng 1423 closing in favor of that one",
             "this looks like a duplicate of ENG-1423 closing in favor of that one"),
            ("see ENG 1423 for context", "see ENG-1423 for context"),
        ], Self.linearTab)
    }

    @Test("a ticket word next to an unfamiliar key is evidence")
    func ticketFromTicketWord() {
        expect([
            ("link the ticket eng 2291 in the description", "link the ticket ENG-2291 in the description"),
            ("this is tracked in issue qzx 4412", "this is tracked in issue QZX-4412"),
            ("jira ticket number zbk 311 covers it", "jira ticket number ZBK-311 covers it"),
        ])
    }

    @Test("without evidence a word and a number stay")
    func ticketTraps() {
        expectUnchanged([
            "this looks like a duplicate of eng 1423 closing in favor of that one",
            "link the ticket age 450 days in the description",
            "update the ticket and let you know",
            "the ticket number 88231 has been open",
            "we had issue web 400 yesterday",
            "the ticket eng 5 was closed",
            "the issue is 500 errors",
            "ops 4412 minutes later",
        ])
        expectUnchanged(["we waited ops 4412 minutes", "the room eng 14 was full"], Self.linearTab)
    }

    @Test("a title key that is not spoken adds nothing, and a different key is not evidence")
    func titleKeyMustMatch() {
        expectUnchanged(["see ops 4412 for context"], Self.linearTab)
    }

    @Test("more ordinary sentences with the same words stay exactly as spoken")
    func moreTraps() {
        expectUnchanged([
            "put a dash between the two numbers and a slash after the date",
            "the company will slash prices and dash to the finish line",
            "she drew a dot and a dash on the board",
            "slash and burn farming is banned",
            "we are in the us and the eu west of here",
            "our eu west one team handles support",
            "dot dot dot and then the end",
            "meet us west of one hundred main street",
            "the pr we talked about is the one i opened last week",
            "ticket prices went up 500 dollars",
            "the p of success is about 99 percent",
        ], Self.linearTab)
    }

    // MARK: Whole pipeline

    @Test("the rules pipeline writes spoken numbers as digits first, only with the context set")
    func throughTextCleaner() {
        var options = CleanupOptions(level: .clean)
        options.technicalTokens = Self.plain
        let on = TextCleaner(options: options)
        let off = TextCleaner(options: CleanupOptions(level: .clean))
        let spoken = "traffic is shifted to us east one and p ninety nine latency dropped"
        #expect(on.clean(spoken).text.contains("us-east-1"))
        #expect(on.clean(spoken).text.contains("p99"))
        #expect(!off.clean(spoken).text.contains("us-east-1"))
        #expect(on.clean("fixed in pr four hundred eighty two today").text.contains("PR 482"))
        #expect(on.clean("p ninety nine percent of the time it works").text.contains("p ninety nine") == false)
        #expect(!on.clean("p ninety nine percent of the time it works").text.contains("p99"))
        #expect(on.clean("we should slash the budget").text.lowercased().contains("slash the budget"))
    }

    @Test("code, terminal, ai prompt, personal and document contexts get no context object")
    func contextOnlyForWorkAndEmail() {
        let title = "ENG-1 Something"
        #expect(TechnicalTokenContext.make(category: .workMessages, bundleID: "com.tinyspeck.slackmacgap", windowTitle: title) != nil)
        #expect(TechnicalTokenContext.make(category: .email, bundleID: "com.apple.mail", windowTitle: title) != nil)
        for category in [AppCategory.code, .aiPrompts, .personalMessages, .documents, .other] {
            #expect(TechnicalTokenContext.make(category: category, bundleID: "com.google.Chrome", windowTitle: title) == nil)
        }
    }

    @Test("only a browser tab title is evidence")
    func titleOnlyFromBrowsers() {
        let browser = TechnicalTokenContext.make(category: .workMessages, bundleID: "com.google.Chrome", windowTitle: "ENG-1 Linear")
        let native = TechnicalTokenContext.make(category: .workMessages, bundleID: "com.linear", windowTitle: "ENG-1 Linear")
        #expect(browser?.windowTitle == "ENG-1 Linear")
        #expect(native?.windowTitle == nil)
    }
}
