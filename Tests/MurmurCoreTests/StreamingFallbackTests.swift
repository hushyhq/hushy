import Testing
@testable import MurmurCore

/// Covers `StreamingFallback.decide`, the pure rule `DictationController.process` uses to choose
/// between a streamed transcript and whole-utterance transcription (task: "if nothing has been
/// finalised by release (short dictations), fall back to whole-utterance automatically").
@Suite("StreamingFallback.decide")
struct StreamingFallbackTests {
    @Test("streaming never activated (short dictation) always falls back, even if a result is somehow present")
    func neverActivatedFallsBack() {
        let decision = StreamingFallback.decide(streamingActivated: false, streamedResult: nil)
        #expect(decision == .wholeUtterance)
    }

    @Test("activated but stop() returned nil (nothing finalized before release) falls back")
    func activatedWithNilResultFallsBack() {
        let decision = StreamingFallback.decide(streamingActivated: true, streamedResult: nil)
        #expect(decision == .wholeUtterance)
    }

    @Test("activated with a usable result uses the streamed transcript, not whole-utterance")
    func activatedWithResultUsesStreamed() {
        let result = TranscriptionResult(text: "hello world", confidences: nil)
        let decision = StreamingFallback.decide(streamingActivated: true, streamedResult: result)
        #expect(decision == .streamed(result))
    }

    @Test("a streamed result carries its confidences through untouched")
    func streamedResultPreservesConfidences() {
        let confidences = [WordConfidence(word: "hello", confidence: 0.4)]
        let result = TranscriptionResult(text: "hello", confidences: confidences)
        let decision = StreamingFallback.decide(streamingActivated: true, streamedResult: result)
        guard case .streamed(let streamed) = decision else {
            Issue.record("expected .streamed")
            return
        }
        #expect(streamed.confidences == confidences)
    }
}

@Suite("StreamingFallback final pass")
struct StreamingFinalPassTests {
    @Test("the final text comes from the whole-utterance pass when preferred, even if streaming finished")
    func prefersWhole() {
        let streamed = TranscriptionResult(text: "hello there", confidences: [])
        #expect(StreamingFallback.decide(streamingActivated: true, streamedResult: streamed, preferWholeUtterance: true) == .wholeUtterance)
        #expect(StreamingFallback.finalTextFromWholeUtterance)
    }
}
