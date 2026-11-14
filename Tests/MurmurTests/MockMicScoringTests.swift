#if DEBUG
import Testing
@testable import Murmur

@Suite("Mock microphone: word error scoring")
struct MockMicScoringTests {
    @Test("identical text scores zero in both modes")
    func identical() {
        for mode in [MockMicScoreMode.full, .bestStretch] {
            let score = MockMicScoring.score(reference: "The quick brown fox.", hypothesis: "the quick brown fox", mode: mode)
            #expect(score.wer == 0)
            #expect(score.errors == 0)
        }
    }

    @Test("full scoring counts every word of the reference")
    func fullCounts() {
        let score = MockMicScoring.score(reference: "one two three four", hypothesis: "one two four", mode: .full)
        #expect(score.errors == 1)
        #expect(score.referenceWords == 4)
        #expect(score.wer == 0.25)
        #expect(score.mode == .full)
    }

    @Test("full scoring penalises a clip that is only part of the reference")
    func fullPenalisesPartial() {
        let score = MockMicScoring.score(reference: "a b c d e f g h", hypothesis: "c d e f", mode: .full)
        #expect(score.wer == 0.5)
    }

    @Test("best stretch ignores reference words before and after the part that was heard")
    func stretchFreeEnds() {
        let reference = "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
        let score = MockMicScoring.score(reference: reference, hypothesis: "delta echo foxtrot golf", mode: .bestStretch)
        #expect(score.wer == 0)
        #expect(score.referenceWords == 4)
        #expect(score.mode == .bestStretch)
    }

    @Test("best stretch still counts real mistakes inside the stretch")
    func stretchMistakes() {
        let reference = "alpha bravo charlie delta echo foxtrot golf hotel"
        let score = MockMicScoring.score(reference: reference, hypothesis: "charlie delta xray foxtrot golf", mode: .bestStretch)
        #expect(score.errors == 1)
        #expect(score.referenceWords == 5)
        #expect(score.wer == 0.2)
    }

    @Test("best stretch counts words that were invented around the stretch")
    func stretchInsertions() {
        let reference = "one two three four five six seven eight nine ten"
        let score = MockMicScoring.score(reference: reference, hypothesis: "zzz four five six yyy", mode: .bestStretch)
        #expect(score.errors == 2)
    }

    @Test("best stretch cannot score a hypothesis better than full scoring on the same stretch")
    func stretchNotBetterThanFull() {
        let reference = "red green blue yellow purple orange"
        let hypothesis = "red green blue yellow purple orange"
        let full = MockMicScoring.score(reference: reference, hypothesis: hypothesis, mode: .full)
        let stretch = MockMicScoring.score(reference: reference, hypothesis: hypothesis, mode: .bestStretch)
        #expect(stretch.wer == full.wer)
    }

    @Test("empty hypothesis against a reference is a full miss")
    func emptyHypothesis() {
        #expect(MockMicScoring.score(reference: "a b c", hypothesis: "", mode: .full).wer == 1)
        #expect(MockMicScoring.score(reference: "a b c", hypothesis: "", mode: .bestStretch).wer == 1)
    }

    @Test("empty reference and empty hypothesis is zero, and an empty reference with words is one")
    func emptyReference() {
        #expect(MockMicScoring.score(reference: "", hypothesis: "", mode: .full).wer == 0)
        #expect(MockMicScoring.score(reference: "", hypothesis: "x", mode: .full).wer == 1)
        #expect(MockMicScoring.score(reference: "", hypothesis: "x", mode: .bestStretch).wer == 1)
    }

    @Test("repeated words in the reference do not confuse the stretch search")
    func repeats() {
        let reference = "go go go stop go go go go"
        let score = MockMicScoring.score(reference: reference, hypothesis: "stop go go", mode: .bestStretch)
        #expect(score.wer == 0)
    }

    @Test("a long reference with a small cut is scored in reasonable time")
    func longReference() {
        let reference = (0..<6000).map { "w\($0 % 97)x\($0)" }.joined(separator: " ")
        let words = reference.split(separator: " ")
        let cut = words[3000..<3150].joined(separator: " ")
        let score = MockMicScoring.score(reference: reference, hypothesis: cut, mode: .bestStretch)
        #expect(score.wer == 0)
        #expect(score.referenceWords == 150)
    }
}
#endif
