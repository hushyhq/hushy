import Foundation
import Testing
@testable import MurmurCore

/// Vocabulary boosting swaps the words it heard for the Dictionary term. When the term contains its heard phrase and the
/// speaker also said the ending ("jimmy lord dot com" for "jimmylord.com"), the ending stayed behind the term and was
/// written twice. Text that already reads as the term is left alone. Invented names only.
@Suite("Boost ending", .timeLimit(.minutes(1)))
struct BoostEndingTests {
    private func guarded(_ original: String, _ boosted: String, terms: [String]) -> String {
        BoostGuard.filter(original: original, boosted: boosted, terms: terms) { _ in false }
    }

    @Test("the spoken ending after a swapped-in term is not written a second time")
    func endingIsNotRepeated() {
        let terms = ["jimmylord.com"]
        #expect(guarded("Jimmy Lord dot com", "Jimmylord.com dot com", terms: terms) == "Jimmylord.com")
        #expect(guarded("open Jimmy Lord dot com please", "open jimmylord.com dot com please", terms: terms) == "open jimmylord.com please")
        #expect(guarded("Jimmy Lord com", "Jimmylord.com com", terms: terms) == "Jimmylord.com")
    }

    @Test("a path the term already has is not written twice either")
    func pathIsNotRepeated() {
        let terms = ["example.com/pricing"]
        #expect(guarded("example dot com slash pricing", "example.com/pricing dot com slash pricing", terms: terms)
                == "example.com/pricing")
    }

    @Test("words after the term that are not its ending stay")
    func otherWordsStay() {
        let terms = ["jimmylord.com"]
        #expect(guarded("Jimmy Lord dot org", "jimmylord.com dot org", terms: terms) == "jimmylord.com dot org")
        #expect(guarded("Jimmy Lord company", "jimmylord.com company", terms: terms) == "jimmylord.com company")
        #expect(guarded("see Jimmy Lord today", "see jimmylord.com today", terms: terms) == "see jimmylord.com today")
    }

    @Test("a term with no punctuation never drops a word")
    func plainTermKeepsEverything() {
        #expect(guarded("send it to Dana Pike dot com", "send it to DanaPike dot com", terms: ["DanaPike"]) == "send it to DanaPike dot com")
    }

    @Test("applying the guard to its own output changes nothing")
    func idempotent() {
        let terms = ["jimmylord.com"]
        let once = guarded("Jimmy Lord dot com", "Jimmylord.com dot com", terms: terms)
        #expect(guarded(once, once, terms: terms) == once)
    }

    @Test("a vocabulary context applies the same rule")
    func throughTheContext() {
        // Invented names that are not in the system word list, so the guard that keeps ordinary words lets the term in.
        let vocabulary = VocabularyContext(terms: [VocabularyTerm(text: "zorvinquell.com", aliases: ["zorvin quell"])])
        #expect(vocabulary.guarded(original: "Zorvin Quell dot com", boosted: "Zorvinquell.com dot com") == "Zorvinquell.com")
    }
}
