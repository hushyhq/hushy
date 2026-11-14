import Testing
@testable import MurmurCore

@Suite struct BlockedVocabularyRewriteTests {
    private let keep = KeepHeardSet(swaps: [VocabularySwap(heard: "codec", written: "Codex", source: .dictionaryAlias)])

    @Test func smallRewriteRestoresOnlyExplicitlyBlockedSubpair() {
        let result = VocabularySwaps.restore(from: "please tell codec today", to: "Please ask Codex tomorrow",
            source: .dictionaryAlias, keeping: keep)
        #expect(result.text == "Please ask codec tomorrow")
    }

    @Test func longChangedRunStillHonorsExplicitPairWithoutLearningRewrite() {
        let result = VocabularySwaps.restore(from: "please tell codec about the green build today",
            to: "Please ask Codex why our blue deployment failed tomorrow", source: .dictionaryAlias, keeping: keep)
        #expect(result.text == "Please ask codec why our blue deployment failed tomorrow")
        #expect(!result.swaps.contains { $0.heard.contains("codec") })
    }

    @Test func absentHeardWordDoesNotSuppressLegitimateWrittenForm() {
        let text = "Please ask Codex tomorrow"
        #expect(VocabularySwaps.restore(from: "please tell someone today", to: text,
            source: .dictionaryAlias, keeping: keep).text == text)
    }

    @Test func multiwordPairsRestoreTheirOwnRawSurface() {
        let pair = VocabularySwap(heard: "code deck", written: "Codex", source: .dictionaryAlias)
        #expect(VocabularySwaps.restore(from: "please tell code deck today", to: "Please ask Codex tomorrow",
            source: .dictionaryAlias, keeping: KeepHeardSet(swaps: [pair])).text == "Please ask code deck tomorrow")
    }

    @Test func repeatedWrittenFormsRestoreOnlyAsManyAsHeard() {
        #expect(VocabularySwaps.restore(from: "tell codec today", to: "ask Codex and Codex tomorrow",
            source: .dictionaryAlias, keeping: keep).text == "ask codec and Codex tomorrow")
    }
}
