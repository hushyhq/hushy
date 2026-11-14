import Testing
import MurmurCore
@testable import Murmur

/// "What polishes your text" is status, not a choice: the note repeats the cleanup controller's
/// sentence and only adds that tones still apply when nothing can polish.
@Suite("Polish status note")
struct PolishStatusTests {
    @Test("the status note repeats the sentence it is given, word for word")
    func statusKeepsTheSentence() {
        let sentence = "Apple Intelligence polishes your dictation on this Mac."
        let status = PolishStatus(sentence: sentence, isModelAvailable: true, isAsSpoken: false)
        #expect(status.sentence == sentence)
        #expect(status.mark == .model)
        #expect(!status.isReduced)
        #expect(status.spokenLabel == "\(ToneCopy.polishStatusTitle). \(sentence)")
    }

    @Test("when nothing can polish and a tone is chosen, the note adds that tones still apply")
    func reducedOnlyWhenAToneIsChosen() {
        let sentence = "Apple Intelligence is not available on this Mac right now, so Hushy uses its simpler fixes (fillers, punctuation, capitals)."
        let reduced = PolishStatus(sentence: sentence, isModelAvailable: false, isAsSpoken: false)
        #expect(reduced.mark == .reduced)
        #expect(reduced.isReduced)
        #expect(reduced.spokenLabel == "\(ToneCopy.polishStatusTitle). \(sentence) \(ToneCopy.tonesStillApply)")
        // As spoken has no tone to apply, so there is nothing to reassure about.
        #expect(PolishStatus(sentence: sentence, isModelAvailable: false, isAsSpoken: true).mark == .quiet)
        #expect(PolishStatus(sentence: sentence, isModelAvailable: true, isAsSpoken: true).mark == .model)
    }
}
