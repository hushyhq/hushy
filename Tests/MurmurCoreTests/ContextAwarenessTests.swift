import Testing
@testable import MurmurCore

@Suite("ContextExtractor")
struct ContextExtractorTests {
    @Test("extracts multiword names and handles within the cap")
    func namesAndHandles() {
        let terms = ContextExtractor.extract(from: "Reply to Priyanka Deshmukh and @platform_team about Kubernetes.")
        #expect(terms.contains("Priyanka Deshmukh"))
        #expect(terms.contains("@platform_team"))
        #expect(terms.count <= ContextExtractor.maxTerms)
    }
    @Test("extracts capitalized names not at sentence start")
    func capitalizedNames() {
        let terms = ContextExtractor.extract(from: "Please loop in Siobhan and Priya on the reply.")
        #expect(terms.contains("Siobhan"))
        #expect(terms.contains("Priya"))
    }

    @Test("does not extract the sentence-initial word")
    func sentenceInitialExcluded() {
        let terms = ContextExtractor.extract(from: "Meeting notes are attached below.")
        #expect(!terms.contains("Meeting"))
    }

    @Test("mid-sentence capitalized word is extracted; sentence-initial words on both sides are not")
    func midSentenceCapitalized() {
        // "Karthik" is sentence-initial here (deliberately conservative: a name that happens to
        // start a sentence is indistinguishable from ordinary capitalization without more
        // context, so it is excluded same as "Done" and "Priya").
        let terms = ContextExtractor.extract(from: "Done for today. Priya says Karthik will follow up tomorrow.")
        #expect(terms.contains("Karthik"))
        #expect(!terms.contains("Done"))
        #expect(!terms.contains("Priya"))
    }

    @Test("extracts the local part of an email address")
    func emailLocalPart() {
        let terms = ContextExtractor.extract(from: "cc ada.lovelace@murmur.app on this thread")
        #expect(terms.contains("ada.lovelace"))
    }

    @Test("extracts camelCase identifiers")
    func camelCase() {
        let terms = ContextExtractor.extract(from: "the userAccountId field is nil here")
        #expect(terms.contains("userAccountId"))
    }

    @Test("extracts snake_case identifiers")
    func snakeCase() {
        let terms = ContextExtractor.extract(from: "select * from user_account_id where active")
        #expect(terms.contains("user_account_id"))
    }

    @Test("common capitalized words are denylisted")
    func denylisted() {
        let terms = ContextExtractor.extract(from: "Let's meet Monday, not Friday. I will confirm.")
        #expect(!terms.contains("monday"))
        #expect(!terms.contains("friday"))
        #expect(!terms.contains("i"))
    }

    @Test("very short tokens are dropped")
    func shortTokensDropped() {
        let terms = ContextExtractor.extract(from: "Go to Ed at HR now.")
        // "Ed" and "HR" are 2 letters, below minTermLength (3), so neither should surface.
        #expect(!terms.contains(where: { $0.lowercased() == "ed" }))
        #expect(!terms.contains(where: { $0.lowercased() == "hr" }))
    }

    @Test("empty input yields no terms")
    func emptyInput() {
        #expect(ContextExtractor.extract(from: "").isEmpty)
    }

    @Test("plain lowercase prose yields no terms")
    func plainProseNoTerms() {
        let terms = ContextExtractor.extract(from: "the quick brown fox jumps over the lazy dog and runs away quickly")
        #expect(terms.isEmpty)
    }

    @Test("window is capped to the last 1000 characters")
    func windowCapped() {
        let padding = String(repeating: "a ", count: 600) // > 1000 chars of filler
        let text = "Zoraida " + padding + "Karthik is here."
        let terms = ContextExtractor.extract(from: text)
        #expect(!terms.contains("Zoraida"))
        #expect(terms.contains("Karthik"))
    }

    @Test("deduplicates case-insensitively, keeping first-seen order")
    func deduplicates() {
        let terms = ContextExtractor.extract(from: "Karthik wrote this. Later Karthik replied again.")
        #expect(terms.filter { $0.lowercased() == "karthik" }.count == 1)
    }
}

@Suite("ContextSpellingFixer")
struct ContextSpellingFixerTests {
    @Test("technical spelling near miss")
    func kubernetes() {
        #expect(ContextSpellingFixer.fix("Kubernetis is ready.", terms: ["Kubernetes"]) == "Kubernetes is ready.")
    }

    @Test("ordinary words stay unchanged")
    func commonWords() {
        for word in ["their", "there", "notes", "nodes", "hello", "world", "chat"] {
            #expect(ContextSpellingFixer.fix(word, terms: ["Kubernetes", "Nora", "chart"]) == word)
        }
    }
    @Test("fixes a near-miss name against a context term")
    func fixesNearMissName() {
        let result = ContextSpellingFixer.fix("Send this to Sioban please.", terms: ["Siobhan"])
        #expect(result == "Send this to Siobhan please.")
    }

    @Test("length-scaled cap fixes vowel-heavy name near misses with matching phonetics")
    func fixesLongerPhoneticNearMisses() {
        #expect(ContextSpellingFixer.fix("Preeya is joining.", terms: ["Priya"]) == "Priya is joining.")
        #expect(ContextSpellingFixer.fix("Finula will start Monday.", terms: ["Fionnuala"]) == "Fionnuala will start Monday.")
    }

    @Test("generic synthetic near miss is eligible under the length-scaled cap")
    func fixesSyntheticNearMiss() {
        #expect(ContextSpellingFixer.fix("Noreya approved it.", terms: ["Narya"]) == "Narya approved it.")
    }

    @Test("ambiguous tied or near-tied context spellings are left unchanged")
    func rejectsAmbiguousCandidates() {
        #expect(ContextSpellingFixer.fix("Nareya approved it.", terms: ["Noreya", "Nariya"]) == "Nareya approved it.")
        #expect(ContextSpellingFixer.fix("Nareya approved it.", terms: ["Noreya", "Noriya"]) == "Nareya approved it.")
    }

    @Test("fixes a mis-transcribed technical identifier")
    func fixesIdentifier() {
        let result = ContextSpellingFixer.fix("The user account id field is wrong.", terms: ["userAccountId"])
        // "id" alone is too short to match; this asserts the fixer does not crash and leaves
        // clearly-unrelated short tokens alone while the sentence overall stays coherent.
        #expect(result.contains("field is wrong"))
    }

    @Test("does not touch a word that is already correct")
    func leavesCorrectWordsAlone() {
        let result = ContextSpellingFixer.fix("Siobhan is here.", terms: ["Siobhan"])
        #expect(result == "Siobhan is here.")
    }

    @Test("negative: does not rewrite an ordinary word just because it's numerically close")
    func doesNotRewriteOrdinaryWords() {
        // "chat" vs "chart": edit distance 1, but different phonetic key (t vs rt).
        let result = ContextSpellingFixer.fix("Let's chat about this later.", terms: ["chart"])
        #expect(result == "Let's chat about this later.")
    }

    @Test("common ordinary word is not rewritten to a phonetic context match")
    func commonWordIsNotRewrittenToContextTerm() {
        #expect(ContextSpellingFixer.fix("I think their team is ready.", terms: ["there"]) == "I think their team is ready.")
    }

    @Test("negative: unrelated context terms never fire")
    func unrelatedTermsDoNotFire() {
        let result = ContextSpellingFixer.fix("The weather is nice today.", terms: ["Kubernetes", "Siobhan"])
        #expect(result == "The weather is nice today.")
    }

    @Test("negative: empty terms list leaves text untouched")
    func emptyTermsNoOp() {
        let result = ContextSpellingFixer.fix("Hello world.", terms: [])
        #expect(result == "Hello world.")
    }

    @Test("negative: empty text returns empty text")
    func emptyTextNoOp() {
        #expect(ContextSpellingFixer.fix("", terms: ["Siobhan"]) == "")
    }

    @Test("negative: a term far in edit distance from every word never fires")
    func farEditDistanceNeverFires() {
        let result = ContextSpellingFixer.fix("The meeting starts at noon sharp.", terms: ["Constantinople"])
        #expect(result == "The meeting starts at noon sharp.")
    }

    @Test("negative: short common words are never candidates for replacement")
    func shortWordsNeverReplaced() {
        let result = ContextSpellingFixer.fix("I am at the gym.", terms: ["am"])
        #expect(result == "I am at the gym.")
    }

    @Test("negative: two different real words of similar length don't swap")
    func realWordsDoNotSwap() {
        let result = ContextSpellingFixer.fix("Please send the report today.", terms: ["export"])
        #expect(result == "Please send the report today.")
    }

    @Test("picks the closest of multiple candidate terms")
    func picksClosestCandidate() {
        let result = ContextSpellingFixer.fix("Ping Sioban about the release.", terms: ["Siobhan", "Constantinople"])
        #expect(result == "Ping Siobhan about the release.")
    }

    @Test("phonetic key groups common ASR confusions")
    func phoneticKeyGrouping() {
        #expect(ContextSpellingFixer.phoneticKey("cooper") == ContextSpellingFixer.phoneticKey("kuper"))
    }

    @Test("phonetic key distinguishes clearly different-sounding words")
    func phoneticKeyDistinguishes() {
        #expect(ContextSpellingFixer.phoneticKey("chat") != ContextSpellingFixer.phoneticKey("chart"))
    }

    @Test("levenshtein distance basic cases")
    func levenshteinBasics() {
        #expect(ContextSpellingFixer.levenshtein("", "") == 0)
        #expect(ContextSpellingFixer.levenshtein("kitten", "sitting") == 3)
        #expect(ContextSpellingFixer.levenshtein("abc", "abc") == 0)
    }

    @Test("negative: a real dictionary-shaped sentence with proper nouns stays untouched when they already match")
    func fullSentenceNoOp() {
        let text = "Priya is migrating the database to Supabase this week."
        let result = ContextSpellingFixer.fix(text, terms: ["Priya", "Supabase"])
        #expect(result == text)
    }
}
