import MurmurCore
import Testing

/// Invented release-path cases, not a claim about recorded public boost scores.
@Suite("Job 125 vocabulary release regression")
struct Job125VocabularyReplayTests {
    @Test func nonemptyKeepRestoresBlockedSwapAndLeavesUnblockedSwap() {
        let keep = KeepHeardSet(swaps: [.init(heard: "codec", written: "Codex", source: .boost)])
        let result = ReleaseSwaps.apply(TranscriptionResult(
            text: "please ask Codex, today and Siobhan tomorrow",
            unboosted: "please ask codec today and Shivan tomorrow"), keep: keep)
        #expect(result.text == "please ask codec, today and Siobhan tomorrow")
        #expect(result.swaps.map(\.written) == ["Siobhan"])
    }
}
