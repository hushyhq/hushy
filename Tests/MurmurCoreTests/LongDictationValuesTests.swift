import Testing
@testable import MurmurCore

/// Spoken technical values and spoken corrections that long developer dictations lose: identifier
/// numbers (no thousands separator, digit groups), dotfiles, route paths, percentiles before a
/// preposition, a correction cue that follows another cue, and a restarted opener. Each class has
/// sentences that must keep their normal form.
@Suite("Long dictation values")
struct LongDictationValuesTests {
    private func itn(_ text: String) -> String { InverseTextNormalizer.apply(text) }
    private func tokens(_ text: String) -> String {
        SpokenTechnicalTokens.apply(text, context: TechnicalTokenContext())
    }

    private func expectItn(_ pairs: [(String, String)]) {
        for (input, expected) in pairs {
            #expect(itn(input) == expected, Comment(rawValue: "\(input) -> \(itn(input))"))
        }
    }

    private func expectTokens(_ pairs: [(String, String)]) {
        for (input, expected) in pairs {
            #expect(tokens(input) == expected, Comment(rawValue: "\(input) -> \(tokens(input))"))
        }
    }

    // MARK: Identifier numbers

    @Test("digit groups after an identifier noun are one number")
    func identifierDigitGroups() {
        expectItn([
            ("the nightly job failed in build six fourteen again", "the nightly job failed in build 614 again"),
            ("it first broke in build nine oh two", "it first broke in build 902"),
            ("the page said http four oh four for that route", "the page said http 404 for that route"),
            ("the script quit with exit code one twenty seven", "the script quit with exit code 127"),
            ("compare it with build number twenty twenty four", "compare it with build number 2024"),
        ])
    }

    @Test("a port or pid is written without a thousands separator")
    func identifierNoSeparator() {
        expectItn([
            ("the proxy listens on port six thousand sixty", "the proxy listens on port 6060"),
            ("kill the process with pid forty two thousand", "kill the process with pid 42000"),
            ("bind it to port eighty eighty and restart", "bind it to port 8080 and restart"),
        ])
    }

    @Test("ordinary quantities and small identifiers keep their normal form")
    func identifierNegatives() {
        expectItn([
            ("that cost six thousand sixty dollars", "that cost $6,060"),
            ("six thousand sixty people came", "6,060 people came"),
            ("from the port eight thousand people left", "from the port 8,000 people left"),
            ("we need to build twelve prototypes", "we need to build 12 prototypes"),
            ("the port is closed until friday", "the port is closed until friday"),
            ("I have no idea", "I have no idea"),
            ("the line was long and slow", "the line was long and slow"),
        ])
    }

    // MARK: Dotfiles and routes

    @Test("dot before a dotfile name is a leading dot")
    func dotfiles() {
        expectTokens([
            ("the secrets are read from dot env so check it", "the secrets are read from .env so check it"),
            ("override the value in dot env dot local first", "override the value in .env.local first"),
            ("add the cache folder to dot gitignore", "add the cache folder to .gitignore"),
            ("it is in config dot env", "it is in config.env"),
        ])
    }

    @Test("dot in ordinary speech stays")
    func dotNegatives() {
        let unchanged = [
            "the dot product of the two vectors",
            "put a red dot next to the icon",
            "connect the dot environment map to the plan",
            "dot the i and cross the t",
        ]
        for input in unchanged { #expect(tokens(input) == input, Comment(rawValue: "changed: \(input)")) }
    }

    @Test("a route introducer keeps its space and the path gets a leading slash")
    func routeIntroducer() {
        expectTokens([
            ("the handler is mounted at the route slash api slash orders and returns json",
             "the handler is mounted at the route /api/orders and returns json"),
            ("call the endpoint slash api slash v two slash ping to check", "call the endpoint /api/v2/ping to check"),
            ("the url slash docs slash intro is stale", "the url /docs/intro is stale"),
            // No introducer: the old behavior.
            ("it is under dev slash staging slash prod", "it is under dev/staging/prod"),
        ])
    }

    @Test("slash in ordinary speech stays")
    func slashNegatives() {
        let unchanged = [
            "we should slash the budget this quarter",
            "just reply yes slash no",
            "the path slash trail was closed",
            "the route slash detour is long",
        ]
        for input in unchanged { #expect(tokens(input) == input, Comment(rawValue: "changed: \(input)")) }
    }

    // MARK: Percentile before a preposition

    @Test("a percentile followed by on or at is still a percentile")
    func percentilePreposition() {
        expectTokens([
            ("the p 99 on the search call is slow", "the p99 on the search call is slow"),
            ("our p 95 at peak is climbing", "our p95 at peak is climbing"),
        ])
    }

    @Test("p stays an ordinary letter without percentile evidence")
    func percentileNegatives() {
        let unchanged = [
            "see page p 95 of the manual",
            "the p 99 seconds figure was a typo",
            "mark the box with a p 99 times",
            "plan b is a p",
        ]
        for input in unchanged { #expect(tokens(input) == input, Comment(rawValue: "changed: \(input)")) }
    }

    // MARK: A cue that follows a cue

    @Test("no sorry and actually no wait replace the word before the cue pair")
    func compoundCue() {
        let cases = [
            ("the reviewer is dana no sorry elif for this change", "the reviewer is elif for this change"),
            ("assign it to ravi actually no wait sunil today", "assign it to sunil today"),
            ("the lead is mina nope sorry bruno on that team", "the lead is bruno on that team"),
        ]
        for (input, expected) in cases {
            #expect(FragmentRepair.apply(input) == expected, Comment(rawValue: "\(input) -> \(FragmentRepair.apply(input))"))
        }
    }

    @Test("an ordinary no, no sorry or I'm sorry is not a repair")
    func compoundCueNegatives() {
        let unchanged = [
            "I have no idea",
            "there is no sorry state to return to",
            "I said no sorry I cannot make it",
            "the answer was yes no sorry about that",
            "she was truly sorry about the delay",
        ]
        for input in unchanged {
            #expect(FragmentRepair.apply(input) == input, Comment(rawValue: "changed: \(input)"))
        }
        let comma = "pass, no fail option on this one"
        #expect(SelfCorrection.apply(comma).text == comma)
    }

    @Test("a comma after the cue word starts a new clause, so nothing is repaired")
    func commaAfterCueWordIsNotARepair() {
        let unchanged = [
            "the deploy finished well, sorry Priya for the late notice",
            "the board voted no, sorry Marco that is final",
            "the vendor replied actually, sorry Helen about the mixup",
            "the migration ran oh, sorry Tomas I forgot to tell you",
            "the review came back well, sorry reviewers for the noise",
        ]
        for input in unchanged {
            #expect(FragmentRepair.apply(input) == input, Comment(rawValue: "changed: \(input) -> \(FragmentRepair.apply(input))"))
        }
    }

    @Test("oh, well or actually before sorry, oops or i mean is an aside, not a retraction")
    func asideBeforeApology() {
        // Task 82: the aside plus apology between two clauses is a sentence break. Only the cue is
        // deleted and no word before it is lost; "i mean" stays as a discourse marker.
        let cases = [
            ("the build passed oh sorry kiran owns the fix", "the build passed. kiran owns the fix"),
            ("the invoice arrived actually sorry leo needs approval", "the invoice arrived. leo needs approval"),
            ("the demo went well sorry ines wants a recording", "the demo went well. ines wants a recording"),
            ("the patch merged oh oops zara reviews it", "the patch merged. zara reviews it"),
            ("the call ended actually i mean omar joined late", "the call ended actually i mean omar joined late"),
        ]
        for (input, expected) in cases {
            #expect(FragmentRepair.apply(input) == expected, Comment(rawValue: "\(input) -> \(FragmentRepair.apply(input))"))
        }
    }

    @Test("a retraction cue after a leading word still replaces the word before the run")
    func retractionAfterLeadingWord() {
        let cases = [
            ("the owner is dev oh no wait sana", "the owner is sana"),
            ("the lead is wren actually nope sorry idris", "the lead is idris"),
        ]
        for (input, expected) in cases {
            #expect(FragmentRepair.apply(input) == expected, Comment(rawValue: "\(input) -> \(FragmentRepair.apply(input))"))
        }
    }

    // MARK: An identifier noun used as a verb

    @Test("build, port or line after a subject, modal or let's is a verb, not an identifier")
    func identifierNounAsVerb() {
        let unchanged = [
            "they will build four eighteen foot frames next week",
            "i want to build six fourteen inch shelves",
            "let's build four eighteen foot benches",
            "you should line four eighteen foot rails",
            "we are gonna build five twelve foot decks",
            "she can build nine twenty inch boxes",
        ]
        for input in unchanged { #expect(IdentifierNumbers.apply(input) == input, Comment(rawValue: "changed: \(input)")) }
        expectItn([
            ("they will build six thousand sixty shelves", "they will build 6,060 shelves"),
            ("we should port eight thousand eighty modules", "we should port 8,080 modules"),
        ])
    }

    @Test("an identifier noun after a preposition or article is still an identifier")
    func identifierNounAfterPreposition() {
        expectItn([
            ("it broke on build six fourteen", "it broke on build 614"),
            ("the build four eighteen is red", "the build 418 is red"),
            ("roll back to build nine oh two", "roll back to build 902"),
            ("bind it to port eighty eighty", "bind it to port 8080"),
        ])
    }

    // MARK: A restarted opener

    @Test("a restart that repeats the same opener keeps the second clause")
    func restartedOpener() {
        let cases = [
            ("so the report is so the issue is that the queue is stale", "so the issue is that the queue is stale"),
            ("we looked and so the cause is so the cause is that the lock leaks", "we looked and so the cause is that the lock leaks"),
        ]
        for (input, expected) in cases {
            #expect(RestartedOpener.apply(input) == expected, Comment(rawValue: "\(input) -> \(RestartedOpener.apply(input))"))
        }
    }

    @Test("a purpose clause or an intensifier after so is not a restart")
    func restartedOpenerNegatives() {
        let unchanged = [
            "so this is so the team can plan",
            "the plan is so simple that it works",
            "so the build is slow so the team waits",
            "so the reason is so the rollout is smooth",
            "so the report is late so the issue is open",
        ]
        for input in unchanged { #expect(RestartedOpener.apply(input) == input, Comment(rawValue: "changed: \(input)")) }
    }

    // MARK: Through the full rules pipeline

    @Test("the rules pipeline writes the values in a work message")
    func pipeline() {
        var options = CleanupOptions()
        options.technicalTokens = TechnicalTokenContext()
        let cleaner = TextCleaner(options: options)
        let text = cleaner.clean("it broke in build six fourteen on port six thousand sixty and the p 99 on the cart call is slow").text
        #expect(text.contains("build 614"))
        #expect(text.contains("port 6060"))
        #expect(text.contains("p99 on"))
    }
}
