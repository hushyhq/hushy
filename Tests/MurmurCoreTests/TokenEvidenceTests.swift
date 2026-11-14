import Testing
@testable import MurmurCore

/// Task 82: the technical-token rules must not rewrite ordinary speech, and a converted token
/// must survive the later stages of the pipeline. Every sentence here is checked through the
/// whole rules path of a work-chat / email target (`TextCleaner`), and the dotfiles also through
/// the rules fallback and the final casing pass the app runs after a rejected model answer.
@Suite("Token evidence in ordinary speech")
struct TokenEvidenceTests {
    private static var options: CleanupOptions {
        var options = CleanupOptions(level: .clean)
        options.technicalTokens = TechnicalTokenContext()
        return options
    }

    private func clean(_ spoken: String) -> String { TextCleaner(options: Self.options).clean(spoken).text }

    /// What the app shows when the local model is skipped or rejected.
    private func viaFallback(_ spoken: String) -> String {
        SmartCleaner.finish(SmartCleaner.rulesFallback(reason: "rejected", draft: clean(spoken)), options: Self.options)
    }

    private func check(_ cases: [(String, String)], _ run: (String) -> String, _ label: String = "") {
        for (spoken, expected) in cases {
            let actual = run(spoken)
            #expect(actual == expected, Comment(rawValue: "\(label)\(spoken) -> \(actual) (wanted \(expected))"))
        }
    }

    // MARK: Identifier numbers

    @Test("a counted noun after an ordinary port is a quantity, with its separator")
    func identifierQuantityFrame() {
        check([
            ("at the port eight thousand passengers arrived", "At the port 8,000 passengers arrived."),
            ("take the port two thousand passengers first", "Take the port 2,000 passengers first."),
            ("from the port eight thousand people left", "From the port 8,000 people left."),
            ("we need to build four eighteen foot shelves", "We need to build four eighteen foot shelves."),
            ("a build four eighteen foot span", "A build four eighteen foot span."),
        ], clean)
    }

    @Test("terse and spoken-technical port, build and status numbers stay identifiers")
    func identifierTechnicalKept() {
        check([
            ("port eight thousand eighty is taken", "Port 8080 is taken."),
            ("the server listens on port eight thousand eighty", "The server listens on port 8080."),
            ("bind the worker to port five thousand one", "Bind the worker to port 5001."),
            ("build six fourteen failed in ci", "Build 614 failed in ci."),
            ("the port eight thousand eighty is taken", "The port 8080 is taken."),
            ("kill whatever holds the port eight thousand eighty now", "Kill whatever holds the port 8080 now."),
            ("status five oh three again", "Status 503 again."),
        ], clean)
    }

    // MARK: Slash chains

    @Test("a slash chain that only joins spoken alternatives before a noun stays words")
    func slashAlternativesStayWords() {
        check([
            ("the route slash detour slash bypass option is still open", "The route slash detour slash bypass option is still open."),
            ("the path slash ridge slash valley walk is closed", "The path slash ridge slash valley walk is closed."),
            ("take the trail slash fire slash service road home", "Take the trail slash fire slash service road home."),
        ], clean)
    }

    @Test("terse and spoken-technical slash chains keep converting")
    func slashTechnicalKept() {
        check([
            ("hit slash api slash users", "Hit /api/users"),
            ("call slash api slash orders after login", "Call /api/orders after login."),
            ("the route slash api slash orders is slow", "The route /api/orders is slow."),
            ("dev slash staging slash prod", "dev/staging/prod"),
            ("curl slash health slash check", "Curl /health/check"),
            ("the endpoint slash v one slash users returns five hundred", "The endpoint /v1/users returns 500."),
            ("open dev slash staging slash prod config", "Open dev/staging/prod config."),
        ], clean)
    }

    // MARK: Dotfiles

    @Test("a converted dotfile survives every later stage, in any position")
    func dotfilesSurvivePipeline() {
        let cases = [
            ("source the dot bashrc file", "Source the .bashrc file."),
            ("dot vimrc is out of date", ".vimrc is out of date."),
            ("load secrets from dot env dot local", "Load secrets from .env.local."),
            ("add it to the dot gitignore", "Add it to the .gitignore."),
            ("create a dot env file for the worker", "Create a .env file for the worker."),
            ("dot env dot local is missing", ".env.local is missing."),
            ("open dot env then restart", "Open .env then restart."),
        ]
        check(cases, clean, "TextCleaner: ")
        check(cases, viaFallback, "fallback: ")
    }

    @Test("other converted tokens that contain a dot also survive the fallback")
    func dottedTokensSurviveFallback() {
        check([
            ("open package dot json and check the version", "Open package.json and check the version."),
            ("edit config slash staging dot yaml now", "Edit config/staging.yaml now."),
            ("the file is config dot yaml", "The file is config.yaml"),
        ], viaFallback)
    }

    @Test("dot env after a determiner and a noun is a mark on a diagram, not a file")
    func dotfileOrdinaryReading() {
        check([
            ("draw a dot env label on the diagram", "Draw a dot env label on the diagram."),
            ("she drew a dot gitignore symbol on the board", "She drew a dot gitignore symbol on the board."),
        ], viaFallback)
        check([
            ("open dot env", "Open .env"),
            ("the dot env is missing", "The .env is missing."),
            ("the dot env needs a fix", "The .env needs a fix."),
        ], viaFallback)
    }

    // MARK: Percentiles

    @Test("p plus a number after an item noun or a survey word is not a percentile")
    func percentileOrdinaryReading() {
        check([
            ("the response to question p ninety five on the survey was slow", "The response to question p 95 on the survey was slow."),
            ("the answer to question p ninety five on the form was slow", "The answer to question p 95 on the form was slow."),
            ("on the survey p ninety nine was the slowest answer", "On the survey p 99 was the slowest answer."),
            ("the part p ninety five of the plan was a delay", "The part p 95 of the plan was a delay."),
            ("the survey response p ninety nine was slow to arrive", "The survey response p 99 was slow to arrive."),
        ], clean)
    }

    @Test("terse and latency-worded percentiles keep converting")
    func percentileTechnicalKept() {
        check([
            ("p ninety five doubled", "p95 doubled"),
            ("our p ninety nine is flat", "Our p99 is flat."),
            ("p ninety nine latency dropped", "p99 latency dropped."),
            ("p ninety five is back to normal", "p95 is back to normal."),
            ("p fifty looks flat", "p50 looks flat."),
            ("traffic is fine and p ninety five is two seconds", "Traffic is fine and p95 is two seconds."),
            ("the p ninety five on the search call is slow", "The p95 on the search call is slow."),
        ], clean)
    }

    // MARK: Version numbers

    @Test("a version spoken as hundreds is one number")
    func versionHundreds() {
        check([
            ("we are on version four hundred six", "We are on version 406."),
            ("version four hundred six is out", "Version 406 is out."),
            ("upgrade to version two", "Upgrade to version 2."),
            ("we shipped version two point three point one", "We shipped version 2.3.1"),
            ("version two thousand twenty five is out", "Version 2025 is out."),
        ], clean)
    }

    // MARK: Correction cues between clauses

    @Test("a retraction cue between two complete clauses ends the first and starts the second")
    func cueBetweenClauses() {
        check([
            ("the update shipped oh sorry dana needs the link", "the update shipped. dana needs the link"),
            ("the ticket is closed no wait dana owns it", "the ticket is closed. dana owns it"),
            ("the invoice has a typo no wait dana fixed it", "the invoice has a typo. dana fixed it"),
        ], FragmentRepair.apply)
        check([
            ("the update shipped oh sorry dana needs the link", "The update shipped. Dana needs the link."),
            ("the ticket is closed no wait dana owns it", "The ticket is closed. Dana owns it."),
        ], clean)
    }

    @Test("an i mean or actually between clauses keeps every content word")
    func cueKeepsContentWords() {
        let spoken = "the deploy is slow i mean sunil owns the fix"
        let out = FragmentRepair.apply(spoken)
        #expect(out.contains("slow"), Comment(rawValue: out))
        #expect(FragmentRepair.apply("the release is blocked actually dana owns it").contains("blocked"))
    }

    @Test("an aside plus sorry still replaces one word")
    func asideReplacesOneWord() {
        check([
            ("ping dana oh sorry dina about the invoice", "ping dina about the invoice"),
            ("send it to dana oh sorry dina", "send it to dina"),
            ("send it to dana no wait dina", "send it to dina"),
            ("assign it to ravi actually no wait sunil today", "assign it to sunil today"),
        ], FragmentRepair.apply)
    }

    @Test("an apology that addresses someone stays")
    func apologyKept() {
        check([
            ("the deploy finished oh sorry priya for the late notice", "the deploy finished oh sorry priya for the late notice"),
        ], FragmentRepair.apply)
    }
}
