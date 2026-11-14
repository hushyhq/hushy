import Testing
@testable import MurmurCore

@Suite("Screen evidence stays separate from boosting")
struct ScreenTermEvidenceTests {
    @Test func ordinaryCapitalizedNamesSupportLearningWithoutBoosting() {
        // Slack and Notion are names that are also everyday words (graded 3.5 and 4.25); Codex is not one (1.5).
        let text = "please ask Slack about Notion and Kubernetes"
        let boostedBefore = ContextExtractor.extract(from: text)
        let evidence = ScreenTermEvidence.extract(from: text)
        #expect(evidence.contains("Slack"))
        #expect(evidence.contains("Notion"))
        #expect(TermEvidence(dictionary: [], screenTerms: evidence, appNames: []).supports("Slack"))
        #expect(!boostedBefore.contains("Slack"))
        #expect(!boostedBefore.contains("Notion"))
        #expect(boostedBefore.contains("Kubernetes"))
        // The system dictionary called "Codex" an ordinary word; the word-frequency table does not, so it is boosted like any name.
        #expect(ContextExtractor.extract(from: "please ask Codex about it").contains("Codex"))
        #expect(ContextExtractor.extract(from: text) == boostedBefore)
    }

    @Test func lowercaseWordsAndOrdinaryControlsAreNotEvidence() {
        let evidence = ScreenTermEvidence.extract(from: "please click Next then Done or Cancel; type text and paste; ask codex about notion")
        #expect(evidence.isEmpty)
    }

    @Test func sentenceInitialCapitalizationDoesNotSupplyEvidence() {
        #expect(ScreenTermEvidence.extract(from: "Please ask the team. Tomorrow is fine.").isEmpty)
    }

    @Test func evidenceUsesExistingWindowAndTermLimits() {
        let old = "please ask Codex " + String(repeating: "word ", count: 240)
        #expect(!ScreenTermEvidence.extract(from: old).contains("Codex"))
        let many = "names " + (0..<80).map { "Veloria" + String(repeating: "a", count: $0) }.joined(separator: " ")
        #expect(ScreenTermEvidence.extract(from: many).count <= ContextExtractor.maxTerms)
    }
}
