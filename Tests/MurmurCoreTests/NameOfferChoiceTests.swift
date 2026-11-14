import Foundation
import Testing
@testable import MurmurCore

/// Which word, if any, a finished dictation offers to add. Every name is invented; the word list
/// is a small one given here, so the answers do not depend on this Mac's dictionary.
@Suite("Name offer — which word is offered")
struct NameOfferChoiceTests {
    private static let ordinary: Set<String> = [
        "needs", "the", "deck", "by", "friday", "ask", "about", "plan", "and", "send", "it", "to", "sarah",
        "tomorrow", "we", "met", "at", "office", "please", "tell", "that", "is", "ready", "a", "report",
        "wants", "call", "with", "on", "monday", "hello", "thanks", "said", "yes", "from", "team",
    ]
    private static let sure: Float = 0.97
    private static let unsure: Float = 0.52

    /// A recogniser's confidences for `text`: every word sure, except the ones named.
    private func heard(_ text: String, unsure: [String: Float] = [:]) -> [WordConfidence] {
        CorrectionAlignment.tokens(text).map { token in
            WordConfidence(word: token, confidence: unsure[NameOfferChoice.key(token)] ?? Self.sure)
        }
    }

    private func offer(
        _ text: String, unsure: [String: Float], index: MemoryIndex = MemoryIndex(entries: []),
        known: Set<String> = [], offered: Set<String> = [], confidences: [WordConfidence]?? = nil
    ) -> String? {
        let words: [WordConfidence]? = confidences ?? heard(text, unsure: unsure)
        return NameOfferChoice.candidate(
            pasted: text, confidences: words, index: index, knownKeys: known, skipping: offered,
            isDictionaryWord: { Self.ordinary.contains($0) })?.word
    }

    @Test("an unsure, capitalised word that is in no dictionary and not in the person's words is offered")
    func positives() {
        #expect(offer("Pria needs the deck by Friday.", unsure: ["pria": Self.unsure]) == "Pria")
        #expect(offer("Ask Zorvex about the plan.", unsure: ["zorvex": Self.unsure]) == "Zorvex")
        // Without the punctuation around it or its possessive ending.
        #expect(offer("We met at Okonkwo's office.", unsure: ["okonkwo": Self.unsure]) == "Okonkwo")
        #expect(offer("Send it to \u{201C}Tavrenna\u{201D}, please.", unsure: ["tavrenna": Self.unsure]) == "Tavrenna")
        // A hyphenated name is one word.
        #expect(offer("Call Whitfield-Okonkwo on Monday.", unsure: ["whitfieldokonkwo": Self.unsure]) == "Whitfield-Okonkwo")
        // Just under the threshold counts; at it does not.
        let threshold = ConfidenceSpans.Calibration.threshold
        #expect(offer("Ask Zorvex.", unsure: ["zorvex": threshold - 0.01]) == "Zorvex")
        #expect(offer("Ask Zorvex.", unsure: ["zorvex": threshold]) == nil)
    }

    @Test("a word the recogniser was sure of is not offered, however new it is")
    func sureWords() {
        #expect(offer("Pria needs the deck by Friday.", unsure: [:]) == nil)
    }

    @Test("ordinary words are never offered: a dictionary word in any capitals, a sentence's first word, a contraction, an acronym, a number")
    func commonWordNegatives() {
        // Dictionary words with a capital: a weekday, a common given name, a sentence opener.
        #expect(offer("Send it to Sarah on Friday.", unsure: ["sarah": Self.unsure, "friday": Self.unsure, "send": Self.unsure]) == nil)
        // Lower case, so not name-like, though it is in no dictionary.
        #expect(offer("Please send the zorvex report.", unsure: ["zorvex": Self.unsure]) == nil)
        // Spoken openers and contractions take their capital from their place.
        #expect(offer("Gonna call that team.", unsure: ["gonna": Self.unsure]) == nil)
        #expect(offer("Yeah. Wasn't ready.", unsure: ["yeah": Self.unsure, "wasn't": Self.unsure]) == nil)
        // Acronyms, digits, and words too short to be worth a line.
        #expect(offer("Ask QXR about B12 and Zo.", unsure: ["qxr": Self.unsure, "b12": Self.unsure, "zo": Self.unsure]) == nil)
        // A hyphenated pair of ordinary words.
        #expect(offer("Call the Report-Team.", unsure: ["reportteam": Self.unsure]) == nil)
    }

    @Test("a word already in the person's words is not offered: as spelled, as once heard, or close in sound")
    func alreadyKnown() {
        let index = MemoryIndex(entries: [MemoryEntry(kind: .term, value: "Priya", heardAs: ["Pria"]),
                                          MemoryEntry(kind: .term, value: "Zorvex"), MemoryEntry(kind: .term, value: "Nerula")])
        #expect(offer("Priya needs the deck.", unsure: ["priya": Self.unsure], index: index) == nil)
        #expect(offer("Pria needs the deck.", unsure: ["pria": Self.unsure], index: index) == nil)
        #expect(offer("Ask zorvex.", unsure: ["zorvex": Self.unsure], index: index) == nil)
        // Sounds like a word they have: recall would bring that word up, so nothing new to ask.
        #expect(offer("Ask Nerrula about the plan.", unsure: ["nerrula": Self.unsure], index: index) == nil)
        // A word from the Dictionary.
        #expect(offer("Ask Quillpad about the plan.", unsure: ["quillpad": Self.unsure], known: ["quillpad"]) == nil)
        // A word that is new beside them still is.
        #expect(offer("Ask Tavrenna about the plan.", unsure: ["tavrenna": Self.unsure], index: index) == "Tavrenna")
    }

    @Test("a word the person told Hushy to forget is never offered")
    func forgotten() {
        let index = MemoryIndex(entries: [MemoryEntry(kind: .forgotten, value: "Zorvex")])
        #expect(offer("Ask Zorvex about the plan.", unsure: ["zorvex": Self.unsure], index: index) == nil)
        #expect(offer("Ask Zorvex's team.", unsure: ["zorvex": Self.unsure], index: index) == nil)
    }

    @Test("no confidences (vocabulary boosting changed the text) offers nothing")
    func boosted() {
        #expect(offer("Pria needs the deck.", unsure: [:], confidences: .some(nil)) == nil)
        #expect(offer("Pria needs the deck.", unsure: [:], confidences: .some([])) == nil)
    }

    @Test("with more than one candidate the least sure is offered, the earlier one on a tie, and only one")
    func severalCandidates() {
        #expect(offer("Ask Zorvex and Tavrenna about Nerula.",
                      unsure: ["zorvex": 0.7, "tavrenna": 0.41, "nerula": 0.6]) == "Tavrenna")
        #expect(offer("Ask Zorvex and Tavrenna.", unsure: ["zorvex": 0.5, "tavrenna": 0.5]) == "Zorvex")
        // A word said twice is as unsure as its least sure hearing.
        let twice = [WordConfidence(word: "Zorvex", confidence: 0.95), WordConfidence(word: "said", confidence: 0.99),
                     WordConfidence(word: "Zorvex", confidence: 0.6)]
        #expect(offer("Zorvex said Zorvex", unsure: [:], confidences: .some(twice)) == "Zorvex")
    }

    @Test("a word offered once since the app started is not offered again")
    func offeredOnce() {
        #expect(offer("Ask Zorvex and Tavrenna.", unsure: ["zorvex": 0.4, "tavrenna": 0.6], offered: ["zorvex"]) == "Tavrenna")
        #expect(offer("Ask Zorvex.", unsure: ["zorvex": 0.4], offered: ["zorvex"]) == nil)
    }

    @Test("only a word the recogniser itself wrote is offered: one cleanup put there is not")
    func onlyWhatWasHeard() {
        // The recogniser wrote "Zorvecks"; the pasted text says "Zorvex".
        let words = heard("Ask Zorvecks about the plan.", unsure: ["zorvecks": Self.unsure])
        #expect(offer("Ask Zorvex about the plan.", unsure: [:], confidences: .some(words)) == nil)
    }

    @Test("nothing to offer: no words, no capitals, nothing unsure")
    func none() {
        #expect(offer("", unsure: [:]) == nil)
        #expect(offer("please send the report tomorrow", unsure: ["report": Self.unsure]) == nil)
        #expect(offer("Hello team.", unsure: ["hello": Self.unsure]) == nil)
    }

    @Test("without a word list on the Mac every word counts as ordinary, so nothing is offered on a capital alone")
    func dictionaryDefault() {
        // The live predicate: whatever this Mac has, an everyday word is ordinary.
        #expect(NameOfferChoice.isDictionaryWord("friday"))
        #expect(NameOfferChoice.isDictionaryWord("don't"))
    }

    // MARK: Pacing

    @Test("one offer, then none for ten minutes; the wait doubles each time an offer goes unanswered and resets when one is taken")
    func pacing() {
        var pacing = NameOfferPacing()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(pacing.allows(at: start))
        pacing.shown("zorvex", at: start)
        #expect(pacing.offeredKeys == ["zorvex"])
        #expect(!pacing.allows(at: start.addingTimeInterval(9 * 60)))
        #expect(pacing.allows(at: start.addingTimeInterval(10 * 60)))

        pacing.answered(added: false)
        #expect(pacing.gap == 20 * 60)
        #expect(!pacing.allows(at: start.addingTimeInterval(19 * 60)))
        pacing.answered(added: false)
        pacing.answered(added: false)
        pacing.answered(added: false)
        pacing.answered(added: false)
        #expect(pacing.gap == NameOfferPacing.longestGap, "the wait stops growing")

        pacing.answered(added: true)
        #expect(pacing.gap == NameOfferPacing.baseGap)
    }
}
