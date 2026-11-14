import Foundation
import Testing
@testable import MurmurCore

/// Dictionary words that are ordinary English keep their capitals only where the sentence names the product. The
/// harm sentences are the accuracy-v1 harm rows' kind; every sentence is invented.
@Suite("Ordinary-word Dictionary terms keep the sentence's case")
struct OrdinaryTermCaseTests {
    private func personalize(_ text: String, _ terms: [String]) -> String {
        Personalizer(dictionary: terms.map { DictionaryEntry(term: $0) }).apply(text).text
    }

    @Test("a common word stays as written mid-sentence")
    func harmRows() {
        let cases: [(String, [String])] = [
            ("I have no notion of what they want.", ["Notion"]),
            ("Let's meet next week instead.", ["Next"]),
            ("She took the initiative on the hiring plan.", ["Initiative", "Linear"]),
            ("Growth was pretty linear this quarter.", ["Linear"]),
            ("There's some slack in the schedule.", ["Slack"]),
            ("We have a few things to cover.", ["Things"]),
            ("The algorithm runs in linear time.", ["Linear"]),
            ("I want to keynote the event next year.", ["Keynote"]),
        ]
        for (text, terms) in cases { #expect(personalize(text, terms) == text, "\(text)") }
    }

    @Test("the product keeps its capitals where the sentence names it")
    func productCues() {
        #expect(personalize("Put it in notion.", ["Notion"]) == "Put it in Notion.")
        #expect(personalize("I filed it on linear and pinged you.", ["Linear"]) == "I filed it on Linear and pinged you.")
        #expect(personalize("Open the notion app.", ["Notion"]) == "Open the Notion app.")
        #expect(personalize("Message me on slack.", ["Slack"]) == "Message me on Slack.")
        #expect(personalize("Ask grace about the budget.", ["Grace"]) == "Ask Grace about the budget.")
    }

    @Test("names and spellings that are not English words are untouched by the gate")
    func namesUnchanged() {
        #expect(personalize("Ask priya about kubernetes.", ["Priya", "Kubernetes"]) == "Ask Priya about Kubernetes.")
        #expect(Personalizer(dictionary: [DictionaryEntry(term: "Kubernetes", soundsLike: ["cooper netties"])])
            .apply("Deploy it to cooper netties next week.").text == "Deploy it to Kubernetes next week.")
        #expect(OrdinaryTermCase.isOrdinary("Notion") && OrdinaryTermCase.isOrdinary("Next"))
        #expect(!OrdinaryTermCase.isOrdinary("Kubernetes") && !OrdinaryTermCase.isOrdinary("rl-v9"))
        #expect(!OrdinaryTermCase.isOrdinary("iOS") && !OrdinaryTermCase.isOrdinary("GitHub") && !OrdinaryTermCase.isOrdinary("NASA"))
    }

    @Test("the recogniser boost keeps the recogniser's case on an ordinary word")
    func boostCase() {
        let vocabulary = VocabularyContext(terms: [VocabularyTerm(text: "Next"), VocabularyTerm(text: "Siobhan")])
        #expect(vocabulary.guarded(original: "let's meet next week with Sioban", boosted: "let's meet Next week with Siobhan")
                == "let's meet next week with Siobhan")
    }
}
