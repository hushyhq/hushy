import Foundation
import Testing
@testable import MurmurCore

@Suite("Word-frequency table")
struct WordFrequencyTests {
    private let table = WordFrequency.shared

    @Test("the shipped table is the size the generator reported, between 1 and 2 MB at most, and sorted")
    func shippedTable() {
        #expect(table.entryCount == WordFrequencyData.entryCount)
        #expect(table.entryCount > 80_000)
        #expect(table.tableByteCount < 2 * 1_048_576)
        // Binary search only works on a sorted table: every word must find its own grade.
        for word in ["a", "aaron", "email", "kubernetes", "the", "zebra", "zoom"] where table.zipf(word) > 0 {
            #expect(table.exact(word) > 0, "\(word)")
        }
    }

    @Test("everyday modern words are ordinary and names and brands that are not words are not")
    func ordinaryAndNot() {
        for word in ["email", "website", "podcast", "screenshot", "inbox", "database", "workflow", "meeting", "the", "of"] {
            #expect(table.isOrdinary(word), "\(word) \(table.zipf(word))")
        }
        for word in ["codex", "anthropic", "kubernetes", "priya", "siobhan", "karthik", "sarah", "hushy", "abaft"] {
            #expect(!table.isOrdinary(word), "\(word) \(table.zipf(word))")
        }
        // A name that is also a word stays a word.
        for word in ["mark", "will", "grace", "notion", "linear"] { #expect(table.isOrdinary(word), "\(word)") }
    }

    @Test("grades order words by how common they are")
    func grades() {
        #expect(table.zipf("the") > table.zipf("email"))
        #expect(table.zipf("email") > table.zipf("podcast"))
        #expect(table.zipf("podcast") > table.zipf("livestream"))
        #expect(table.zipf("the") >= 7 && table.zipf("xqzvk") == 0)
    }

    @Test("regular inflections are known through their stem, case and curly apostrophes do not matter")
    func inflections() {
        for word in ["voices", "invited", "inviting", "stopped", "quickly", "buries"] { #expect(table.isOrdinary(word), "\(word)") }
        #expect(table.isOrdinary("Email") && table.isOrdinary("EMAIL"))
        #expect(table.isKnown("don\u{2019}t") == table.isKnown("don't"))
        #expect(table.zipf("") == 0 && table.zipf("e-mail") == 0 && table.zipf("naïve") == 0)
    }

    @Test("one- and two-letter abbreviations are not ordinary words; the real two-letter words are")
    func shortWords() {
        for word in ["vs", "pm", "tv", "pc", "id"] { #expect(!table.isOrdinary(word), "\(word)") }
        for word in ["to", "of", "in", "is", "go", "am", "we"] { #expect(table.isOrdinary(word), "\(word)") }
    }

    @Test("a table in the shipped format is searched correctly at its edges")
    func formatEdges() {
        let small = WordFrequency(table: "aZabBabcCmidDzzF")
        #expect(small.entryCount == 5)
        #expect(small.exact("a") == 1.5 + 0.25 * 25)
        #expect(small.exact("ab") == 1.5 + 0.25)
        #expect(small.exact("abc") == 1.5 + 0.5)
        #expect(small.exact("mid") == 1.5 + 0.75)
        #expect(small.exact("zz") == 1.5 + 1.25)
        for missing in ["", "b", "abcd", "m", "zzz", "aa", "A", "a1"] { #expect(small.exact(missing) == 0, "\(missing)") }
    }

    @Test("the learner and the guards use the table: a spoken product name is not protected, a plain word is")
    func consumers() {
        #expect(LearningLexicon.isCommonWord("podcast") && !LearningLexicon.isCommonWord("codex"))
        #expect(LearningLexicon.isCommonWord("don't") && LearningLexicon.isCommonWord("i'm"))
        // The drift guard counts a modern word as English; with the system dictionary it did not.
        #expect(AsrDriftGuard.decision(for: "Email Priya today.") == .accept)
        #expect(AsrDriftGuard.decision(for: "Download the podcast.") == .accept)
    }
}
