import Testing
@testable import MurmurCore

/// A heard number blocks a boost to a screen term ("try 95" is not "TRY-95"), but the person's own Dictionary or learned
/// term may write the number they said (accuracy-v1 code-039, 2026-11-11).
@Suite("Personal terms and heard numbers")
struct PersonalTermNumberTests {
    private func dictionary(_ terms: [String]) -> VocabularyContext {
        PipelineSettings(personalizer: Personalizer(dictionary: terms.map { DictionaryEntry(term: $0) })).vocabulary
    }

    @Test("the Dictionary term node:22-alpine is written from node 22 Alpine")
    func dictionaryTermWritesItsNumber() {
        let boosted = "The base image is node:22-alpine."
        #expect(dictionary(["node:22-alpine"]).guarded(original: "The base image is node 22 Alpine.", boosted: boosted) == boosted)
    }

    @Test("I will try 95 times stays as said when TRY-95 is only on screen")
    func screenTermKeepsHeardNumber() {
        let screen = PipelineSettings(contextTerms: ["TRY-95"]).vocabulary
        #expect(screen.guarded(original: "I will try 95 times", boosted: "I will TRY-95 times") == "I will try 95 times")
        let pack = VocabularyContext(terms: [VocabularyTerm(text: "TRY-95", source: .pack)])
        #expect(pack.guarded(original: "I will try 95 times", boosted: "I will TRY-95 times") == "I will try 95 times")
    }

    @Test("a Dictionary term never overwrites a heard quantity with other digits", arguments: [
        ("I will try 96 times", "I will TRY-95 times"),
        ("The base image is node 20 Alpine.", "The base image is node:22-alpine."),
    ])
    func dictionaryTermKeepsOtherNumbers(_ heard: String, _ boosted: String) {
        #expect(dictionary(["TRY-95", "node:22-alpine"]).guarded(original: heard, boosted: boosted) == heard)
    }

    @Test("a learned lexicon term writes its number, also when the screen shows it")
    func learnedTermWritesItsNumber() {
        let learned = VocabularyTerm(text: "node:22-alpine", source: .personal)
        var settings = PipelineSettings(contextTerms: ["node:22-alpine"])
        settings.lexiconTerms = [learned]
        #expect(settings.vocabulary.terms.first { $0.text == "node:22-alpine" }?.source == .personal)
        let boosted = "use node:22-alpine here"
        #expect(settings.vocabulary.guarded(original: "use node 22 Alpine here", boosted: boosted) == boosted)
    }
}
