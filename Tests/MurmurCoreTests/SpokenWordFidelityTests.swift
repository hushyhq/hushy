import Testing
@testable import MurmurCore

/// The cleanup model may remove fillers, resolve self-corrections, punctuate, capitalise, format
/// numbers, contract and fix a misspelling. It may not swap a word the speaker said for a
/// different word (a shortened or expanded name, a renamed product). These tests pin both sides.
@Suite("Spoken word fidelity")
struct SpokenWordFidelityTests {
    /// A tiny deterministic dictionary, so the tests do not depend on `/usr/share/dict/words`.
    private static let dictionary: Set<String> = [
        "ask", "about", "the", "rollout", "send", "report", "meeting", "noon", "ship", "it", "we", "need",
        "servers", "have", "time", "can", "you", "before", "deploy", "update", "check", "tomorrow",
        "please", "review", "design", "doc", "dictation", "rotation", "and", "reports", "yesterday",
    ]

    private func enforce(_ answer: String, draft: String, low: Set<String>? = nil) -> SpokenWordFidelity.Result {
        SpokenWordFidelity.enforce(answer: answer, draft: draft, lowConfidenceWords: low, knownWords: Self.dictionary)
    }

    private func expectKept(_ answer: String, draft: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let result = enforce(answer, draft: draft)
        #expect(result.text == answer, Comment(rawValue: "changed: \(answer) -> \(result.text)"), sourceLocation: sourceLocation)
        #expect(!result.fired, sourceLocation: sourceLocation)
    }

    // MARK: The speaker's word wins

    @Test("a shortened name is restored, keeping the model's capital")
    func shortenedName() {
        let draft = "Hi priyanka thanks so much for sending over the sdk docs they were super helpful cheers dan."
        let answer = "Hi Priya,\n\nThanks so much for sending over the SDK docs. They were super helpful.\n\nCheers,\nDan"
        let result = enforce(answer, draft: draft)
        #expect(result.text == "Hi Priyanka,\n\nThanks so much for sending over the SDK docs. They were super helpful.\n\nCheers,\nDan")
        #expect(result.wordRepairs == 1)
    }

    @Test("a renamed product is restored; the model's number formatting stays")
    func renamedProduct() {
        let draft = "So basically the tldr is we're moving to postgres 16 next quarter."
        let answer = "The TLDR is: we're moving to PostgreSQL 16 next quarter."
        #expect(enforce(answer, draft: draft).text == "The TLDR is: we're moving to Postgres 16 next quarter.")
    }

    @Test("a product renamed over a spoken number keeps the digits")
    func renamedProductWithSpokenNumber() {
        let draft = "we are moving to postgres sixteen next quarter"
        let answer = "We are moving to PostgreSQL 16 next quarter."
        #expect(enforce(answer, draft: draft).text == "We are moving to Postgres 16 next quarter.")
    }

    @Test("an expanded word is restored to the form the speaker used")
    func expandedWord() {
        let result = enforce("Update the configuration before we deploy.", draft: "update the config before we deploy")
        #expect(result.text == "Update the config before we deploy.")
    }

    @Test("a shortened common word is restored")
    func shortenedCommonWord() {
        let result = enforce("Please check the repo.", draft: "please check the repository")
        #expect(result.text == "Please check the repository.")
    }

    @Test("an unrelated name replacing an unknown name is restored")
    func unrelatedName() {
        let result = enforce("Ask Maya about the rollout.", draft: "ask kavya about the rollout")
        #expect(result.text == "Ask Kavya about the rollout.")
    }

    @Test("the repair only touches the one word")
    func repairIsLocal() {
        let draft = "send it to priyanka before the meeting at noon"
        let answer = "Send it to Priya before the meeting at noon."
        #expect(enforce(answer, draft: draft).text == "Send it to Priyanka before the meeting at noon.")
    }

    @Test("a hyphen change in one word restores the spoken spelling")
    func hyphenMeaning() {
        #expect(enforce("I will resign the contract.", draft: "I will re-sign the contract").text == "I will re-sign the contract.")
        #expect(enforce("I will re-sign the contract.", draft: "I will resign the contract").text == "I will resign the contract.")
        // Conservative protection also keeps a harmless hyphen.
        #expect(enforce("Send an email.", draft: "send an e-mail").text == "Send an e-mail.")
    }

    @Test("a changed number returns to the spoken value while equivalent formatting stays")
    func numberValue() {
        #expect(enforce("Need 60 servers.", draft: "need sixteen servers").text == "Need 16 servers.")
        #expect(enforce("Need sixty servers.", draft: "need sixteen servers").text == "Need sixteen servers.")
        #expect(enforce("Need 16 servers.", draft: "need sixteen servers").text == "Need 16 servers.")
        #expect(enforce("Need 26 servers.", draft: "need twenty five servers").text == "Need 25 servers.")
        #expect(enforce("Need 60 servers.", draft: "need sixteen servers", low: ["sixteen"]).text == "Need 60 servers.")
        // Digits in the draft are the fact guard's to veto; this step leaves them alone.
        #expect(enforce("Send it at 6.", draft: "send it at 5").text == "Send it at 6.")
    }

    @Test("a moved strong relation is repaired only when its partner is unique")
    func movedWord() {
        #expect(enforce("Send a note to Priya.", draft: "send priyanka a note").text == "Send a note to Priyanka.")
        #expect(enforce("Send a note to Priya or Priyan.", draft: "send priyanka a note").text == "Send a note to Priya or Priyan.")
        #expect(enforce("Send a note to Maya.", draft: "send priyanka a note").text == "Send a note to Maya.")
    }

    @Test("identical text returns without repairs")
    func identicalText() {
        let result = enforce("Send the report.", draft: "Send the report.")
        #expect(result.text == "Send the report.")
        #expect(!result.fired)
    }

    @Test("agreement after a restored expansion is a known limit")
    func restoredExpansionAgreement() {
        // Known limit: the guard restores the spoken noun but cannot infer the intended agreement.
        #expect(enforce("The applications are ready.", draft: "the app are ready").text == "The app are ready.")
    }

    @Test("a low-confidence word may be corrected by the model")
    func lowConfidenceWordMayChange() {
        let result = enforce("Ask Maya about the rollout.", draft: "ask kavya about the rollout", low: ["kavya"])
        #expect(result.text == "Ask Maya about the rollout.")
    }

    // MARK: What the model is supposed to do

    @Test("fixing a misspelling of the same word is allowed")
    func misspelling() {
        expectKept("The meeting is at noon.", draft: "the meting is at noon")
        expectKept("Please send the report.", draft: "please send the reeport")
        expectKept("Please receive it.", draft: "please recieve it")
    }

    @Test("ok becomes OK; okay becomes OK")
    func okayVariants() {
        expectKept("OK, ship it.", draft: "ok ship it")
        expectKept("OK, ship it.", draft: "okay ship it")
    }

    @Test("number words become digits")
    func numberWords() {
        expectKept("We need 16 servers.", draft: "we need sixteen servers")
        expectKept("We need 3 servers.", draft: "we need three servers")
    }

    @Test("contractions are allowed in both directions")
    func contractions() {
        expectKept("We don't have time.", draft: "we dont have time")
        expectKept("We don't have time.", draft: "we do not have time")
        expectKept("We're going to ship it.", draft: "we are going to ship it")
        expectKept("We're gonna ship it.", draft: "we are gonna ship it")
    }

    @Test("a filler dropped next to a name leaves the name alone")
    func fillerNextToName() {
        expectKept("Priyanka, can you send the report?", draft: "um priyanka can you send the report")
        expectKept("Can you send the report, Priyanka?", draft: "can you send the report um priyanka")
    }

    @Test("a self-correction resolves to the corrected name")
    func selfCorrection() {
        expectKept("Send it to Priyanka.", draft: "send it to priya no wait priyanka")
        expectKept("Meet on Wednesday.", draft: "meet on tuesday no wednesday")
    }

    @Test("capitalising the same word is allowed")
    func capitalisation() {
        expectKept("Hi Priyanka, thanks.", draft: "hi priyanka thanks")
        expectKept("Ask the API team.", draft: "ask the api team")
    }

    @Test("inflection and tense repair are allowed")
    func inflection() {
        expectKept("We shipped the report.", draft: "we ship the reports")
        expectKept("We deployed it yesterday.", draft: "we deploy it yesterday")
        expectKept("Please review the design docs.", draft: "please review the design doc")
    }

    @Test("joining or splitting a compound is not a different word")
    func joinsAndSplits() {
        expectKept("Send an email about the webhook.", draft: "send an e mail about the web hook")
        expectKept("Send an e-mail about the web hook.", draft: "send an email about the webhook")
    }

    @Test("a spoken word replaced by a different dictionary word is left to the older guards")
    func dictionaryWordSwapIsNotRepairedHere() {
        expectKept("Review the rotation.", draft: "review the dictation")
    }

    @Test("a count mismatch with no relation between the words is left alone")
    func ambiguousRegionIsLeftAlone() {
        expectKept("Ask Maya and Joe about the rollout.", draft: "ask kavya about the rollout")
    }

    @Test("without a dictionary only shortened or expanded words are repaired")
    func noDictionary() {
        let none = SpokenWordFidelity.enforce(
            answer: "Ask Maya about the rollout.", draft: "ask kavya about the rollout", lowConfidenceWords: nil, knownWords: [])
        #expect(none.text == "Ask Maya about the rollout.")
        let prefix = SpokenWordFidelity.enforce(
            answer: "Ask Priya about the rollout.", draft: "ask priyanka about the rollout", lowConfidenceWords: nil, knownWords: [])
        #expect(prefix.text == "Ask Priyanka about the rollout.")
    }

    // MARK: Converted tokens keep their case

    @Test("a converted token keeps its exact case through the model")
    func convertedTokenCase() {
        expectCase("Traffic is shifted to us-east-1, and P99 latency dropped.",
                   draft: "Traffic is shifted to us-east-1 and p99 latency dropped",
                   becomes: "Traffic is shifted to us-east-1, and p99 latency dropped.")
        expectCase("US-East-1 is down.", draft: "us-east-1 is down", becomes: "us-east-1 is down.")
        expectCase("Run it with --Force.", draft: "run it with --force", becomes: "Run it with --force.")
        expectCase("Edit Config/staging.yaml first.", draft: "edit config/staging.yaml first", becomes: "Edit config/staging.yaml first.")
        expectCase("Open package.JSON.", draft: "open package.json", becomes: "Open package.json.")
    }

    @Test("a model change that is not case-only is not undone by the case rule")
    func caseRuleLeavesWordsAlone() {
        expectKept("Latency is P99 today.", draft: "latency is Dev today")
        expectKept("Ship the Patch.", draft: "ship the patch")
    }

    private func expectCase(_ answer: String, draft: String, becomes expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let result = enforce(answer, draft: draft)
        #expect(result.text == expected, Comment(rawValue: "\(answer) -> \(result.text)"), sourceLocation: sourceLocation)
        #expect(result.caseRestores >= 1, sourceLocation: sourceLocation)
    }
}

@Suite("Converted token shapes")
struct ConvertedTokenShapeTests {
    @Test("the shapes the technical-token rules write are case-sensitive")
    func shapes() {
        for token in ["p99", "p50", "p999", "us-east-1", "eu-west-2", "--force", "--dry-run", "--no-verify",
                      "config/staging.yaml", "src/api/user.ts", "package.json", "webpack.config.js", "feature/retry-logic"] {
            #expect(ConvertedTokenShape.isCaseSensitive(token), Comment(rawValue: token))
        }
    }

    @Test("punctuation around a token does not hide its shape")
    func surroundingPunctuation() {
        #expect(ConvertedTokenShape.isCaseSensitive("p99,"))
        #expect(ConvertedTokenShape.isCaseSensitive("(p99)"))
        #expect(ConvertedTokenShape.isCaseSensitive("package.json."))
    }

    @Test("ordinary words, names and abbreviations are not")
    func notShapes() {
        for token in ["pass", "price", "p", "p9x", "peak", "Priya", "P99", "e.g.", "a/b", "and/or", "Dr.", "x.", "ok", "I'm",
                      "us-east", "notes.pdfs", "mid-sentence", "well-known", "re-run"] {
            #expect(!ConvertedTokenShape.isCaseSensitive(token), Comment(rawValue: token))
        }
    }

    @Test("sentence capitalisation leaves a case-sensitive token alone")
    func capitaliserSkipsShapes() {
        #expect(Punctuation.capitalizeSentences("p99 latency dropped. config.yaml has it. --force is needed.")
                == "p99 latency dropped. config.yaml has it. --force is needed.")
        #expect(Punctuation.capitalizeSentences("us-east-1 is down. pass the salt. p value is high.")
                == "us-east-1 is down. Pass the salt. P value is high.")
    }

    @Test("the style formatter keeps a converted token at a sentence start")
    func styleKeepsToken() {
        for context in [StyleContext.workMessages, .email] {
            let out = StyleFormatter.apply(.formal, to: "p99 latency dropped from 800 ms to 120", in: context)
            #expect(out == "p99 latency dropped from 800 ms to 120.", Comment(rawValue: out))
        }
    }
}

@Suite("Greeting addressee")
struct GreetingAddresseeTests {
    private func format(_ text: String, _ context: StyleContext, _ style: WritingStyle = .formal) -> String {
        StyleFormatter.apply(style, to: text, in: context)
    }

    @Test("a lower-case name after a greeting is capitalised in email")
    func emailAddressee() {
        #expect(format("hi dev, I looked into the leak. Thanks, Lena", .email).hasPrefix("Hi Dev,\n\n"))
        #expect(format("hey priyanka, thanks for the docs.", .email).hasPrefix("Hey Priyanka,\n\n"))
        #expect(format("hello kavya, thanks for the docs.", .email).hasPrefix("Hello Kavya,\n\n"))
        #expect(format("dear priyanka, thanks for the docs.", .email).hasPrefix("Dear Priyanka,\n\n"))
    }

    @Test("a lower-case name after a greeting is capitalised in work messages")
    func workAddressee() {
        #expect(format("hi dev, can you look at the leak", .workMessages) == "Hi Dev, can you look at the leak.")
        #expect(format("hey priyanka, the docs were great", .workMessages, .casual) == "Hey Priyanka, the docs were great")
    }

    @Test("a greeting already on its own line is capitalised too")
    func laidOutGreeting() {
        #expect(format("hi dev,\n\nI looked into the leak.\n\nThanks,\nLena", .email) == "Hi Dev,\n\nI looked into the leak.\n\nThanks,\nLena")
        #expect(format("hi there,\n\nquick note.", .email).hasPrefix("Hi there,\n\n"))
        #expect(format("hi all of you,\n\nquick note.", .email).hasPrefix("Hi all of you,\n\n"))
    }

    @Test("the greeting patterns that refuse stay quiet")
    func staysQuiet() {
        #expect(format("hi all of you, thanks for coming", .workMessages) == "Hi all of you, thanks for coming.")
        #expect(format("hi there, quick note for you", .workMessages) == "Hi there, quick note for you.")
        #expect(format("hi there, quick note for you", .email).hasPrefix("Hi there,\n\n"))
        #expect(format("hi all, quick reminder", .email).hasPrefix("Hi all,\n\n"))
        #expect(format("hi everyone, quick reminder", .workMessages) == "Hi everyone, quick reminder.")
        #expect(format("hi team, quick reminder", .email).hasPrefix("Hi team,\n\n"))
        #expect(format("hi can you send this", .workMessages) == "Hi can you send this.")
        #expect(format("dear customer success team, thanks", .email).hasPrefix("Dear customer success team,\n\n"))
        #expect(format("hi again, thanks", .workMessages) == "Hi again, thanks.")
        #expect(format("hi sorry, I was late", .workMessages) == "Hi sorry, I was late.")
    }

    @Test("other contexts and a name that is already capitalised are unchanged")
    func otherContexts() {
        #expect(format("hi dev, are you free", .personalMessages) == "Hi dev, are you free.")
        #expect(format("hi dev, are you free", .other) == "Hi dev, are you free.")
        #expect(format("Hi Dev, thanks", .workMessages) == "Hi Dev, thanks.")
        #expect(format("hi dev, are you free", .workMessages, .excited) == "Hi Dev, are you free!")
    }
}

@Suite("Existing guards and the swapped word")
struct ExistingGuardBaselineTests {
    private let nameDraft = "Hi priyanka thanks so much for sending over the sdk docs they were super helpful and we should be able to integrate by the end of the month cheers dan."
    private let nameAnswer = "Hi Priya, thanks so much for sending over the SDK docs. They were super helpful and we should be able to integrate by the end of the month. Cheers, Dan."
    private let productDraft = "So basically the tldr is we're moving to postgres 16 next quarter and there's no downtime expected it's a five minute cutover thanks nina."
    private let productAnswer = "The TLDR is: we're moving to PostgreSQL 16 next quarter, and there's no downtime expected. It's a five-minute cutover. Thanks, Nina."

    @Test("Polished accepts a shortened name and a renamed product: the invented-word budget and the stem allowance let them through")
    func polishedAccepts() {
        #expect(OutputGuard.check(nameAnswer, raw: nameDraft, draft: nameDraft, profile: .grammarRepair) == .accepted(nameAnswer))
        #expect(OutputGuard.check(productAnswer, raw: productDraft, draft: productDraft, profile: .grammarRepair) == .accepted(productAnswer))
    }

    @Test("Clean's disfluency-only profile catches the renamed product and the shortened name")
    func cleanProfile() {
        #expect(OutputGuard.check(productAnswer, raw: productDraft, draft: productDraft, profile: .disfluencyOnly)
            == .rejected("dropped content words: [\"postgres\"]"))
        #expect(OutputGuard.check(nameAnswer, raw: nameDraft, draft: nameDraft, profile: .disfluencyOnly)
            == .rejected("dropped content words: [\"priyanka\"]"))
    }

    @Test("the fidelity guard repairs both and the older guards then accept the repaired text")
    func repairedTextPassesTheOlderGuards() {
        let name = SpokenWordFidelity.enforce(answer: nameAnswer, draft: nameDraft, lowConfidenceWords: nil)
        #expect(name.text.hasPrefix("Hi Priyanka, thanks"))
        let product = SpokenWordFidelity.enforce(answer: productAnswer, draft: productDraft, lowConfidenceWords: nil)
        #expect(product.text.contains("Postgres 16"))
        for profile in [OutputGuard.Profile.grammarRepair, .disfluencyOnly] {
            #expect(OutputGuard.check(name.text, raw: nameDraft, draft: nameDraft, profile: profile) == .accepted(name.text))
            #expect(OutputGuard.check(product.text, raw: productDraft, draft: productDraft, profile: profile) == .accepted(product.text))
        }
    }
}
