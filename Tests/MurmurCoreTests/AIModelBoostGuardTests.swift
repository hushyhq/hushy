import Testing
@testable import MurmurCore

/// The AI-model boost in an AI-prompt app keeps a swap only in a sentence about AI (accuracy eval, Claude app, 2026-11-11).
struct AIModelBoostGuardTests {
    private let aiTerms = VocabularyContext.aiModelTerms.map(\.text)

    @Test("a person's name is not traded for an AI name")
    func namesStay() {
        #expect(AIModelBoostGuard.keepSupported(
            original: "Anthony Edwards dropped forty last night.", boosted: "Anthropic Edwards dropped forty last night.",
            aiTerms: aiTerms) == "Anthony Edwards dropped forty last night.")
        #expect(AIModelBoostGuard.keepSupported(
            original: "Cade Cunningham is back on Friday.", boosted: "Codex Cunningham is back on Friday.",
            aiTerms: aiTerms) == "Cade Cunningham is back on Friday.")
        // A full name stays even when the sentence is about AI.
        #expect(AIModelBoostGuard.keepSupported(
            original: "Ask the agent to email Anthony Edwards.", boosted: "Ask the agent to email Anthropic Edwards.",
            aiTerms: aiTerms) == "Ask the agent to email Anthony Edwards.")
    }

    @Test("an AI name the recogniser heard is not swapped for another")
    func heardNamesStay() {
        #expect(AIModelBoostGuard.keepSupported(
            original: "Compare it with Claude Sonnet 4.5.", boosted: "Compare it with Claude Code 4.5.",
            aiTerms: aiTerms) == "Compare it with Claude Sonnet 4.5.")
    }

    @Test("a misheard AI name in a sentence about AI is still fixed")
    func supportedSwapsStand() {
        #expect(AIModelBoostGuard.keepSupported(
            original: "Use Sonet for this prompt.", boosted: "Use Sonnet for this prompt.", aiTerms: aiTerms)
            == "Use Sonnet for this prompt.")
        #expect(AIModelBoostGuard.keepSupported(
            original: "Which model is better, Jemini or GPT?", boosted: "Which model is better, Gemini or GPT?", aiTerms: aiTerms)
            == "Which model is better, Gemini or GPT?")
    }

    @Test("with no AI word in the sentence the heard text stays")
    func noCueNoSwap() {
        #expect(AIModelBoostGuard.keepSupported(
            original: "We met Jemini at the cafe.", boosted: "We met Gemini at the cafe.", aiTerms: aiTerms)
            == "We met Jemini at the cafe.")
        // The cue must be in the same sentence.
        #expect(AIModelBoostGuard.keepSupported(
            original: "Ask the model. We met Jemini at the cafe.", boosted: "Ask the model. We met Gemini at the cafe.",
            aiTerms: aiTerms) == "Ask the model. We met Jemini at the cafe.")
    }

    @Test("through the vocabulary: built-in AI terms are judged, the person's own terms are not")
    func throughTheVocabulary() {
        let builtIn = VocabularyContext(terms: VocabularyContext.aiModelTerms)
        #expect(builtIn.guarded(original: "Cade Cunningham is back on Friday.", boosted: "Codex Cunningham is back on Friday.")
            == "Cade Cunningham is back on Friday.")
        let own = VocabularyContext(terms: [VocabularyTerm(text: "Codex")])
        #expect(own.guarded(original: "Cade Cunningham is back on Friday.", boosted: "Codex Cunningham is back on Friday.")
            == "Codex Cunningham is back on Friday.")
    }
}
