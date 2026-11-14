import Foundation
import Testing
@testable import Murmur

/// A failed transcription says what happened to the audio and offers the way back when there is
/// one. The audio is kept in memory only, behind the row's Try again, and is let go the moment the
/// row goes: retried, dismissed, replaced by the next dictation or by any other pill state.
@Suite("Recovery: a failed transcription keeps its audio for one more try")
@MainActor
struct RecoveryRetryTests {
    /// Stands in for the kept audio: alive only while the retry closure is.
    private final class KeptAudio {}
    private final class Counter { var runs = 0 }

    private func failedPill(
        _ counter: Counter = Counter(), keptFor lifetime: Duration = DictationFailure.keptAudioLifetime
    ) -> (PillModel, () -> Bool) {
        let pill = PillModel()
        var audio: KeptAudio? = KeptAudio()
        weak var kept = audio
        pill.present(failure: .transcription(recordingKept: true), retry: { [audio] in
            _ = audio
            counter.runs += 1
        }, keptFor: lifetime)
        audio = nil
        return (pill, { kept != nil })
    }

    // MARK: The words

    @Test("with the audio kept it says so and offers Try again")
    func kept() {
        let failure = DictationFailure.transcription(recordingKept: true)
        #expect(failure.line == "Couldn't transcribe · your recording is still here")
        #expect(failure.canRetry)
        #expect(DictationFailure.retryTitle == "Try again")
    }

    @Test("without the audio it says so plainly and says what to do")
    func notKept() {
        let failure = DictationFailure.transcription(recordingKept: false)
        #expect(failure.line == "Couldn't transcribe · recording not kept, dictate again")
        #expect(!failure.canRetry)
    }

    @Test("only a failed transcription with its audio offers Try again",
          arguments: [DictationFailure.noWords, .nothingToWrite, .heardNothing, .micSilent, .didNotStart("Microphone access needed")])
    func othersDoNotRetry(failure: DictationFailure) {
        #expect(!failure.canRetry, "running the same audio again would give the same nothing")
    }

    // MARK: Try again

    @Test("Try again runs the kept audio once")
    func retryRunsOnce() {
        let counter = Counter()
        let (pill, _) = failedPill(counter)
        pill.retryFailure()
        #expect(counter.runs == 1)
        pill.retryFailure()
        #expect(counter.runs == 1, "a second press has nothing left to run")
    }

    @Test("a failure shown without audio has nothing to run")
    func nothingToRun() {
        let pill = PillModel()
        pill.present(failure: .transcription(recordingKept: false))
        pill.retryFailure()
        #expect(pill.state == .failed(.transcription(recordingKept: false)))
    }

    // MARK: Letting the audio go

    @Test("the audio is held while the row shows")
    func heldWhileShowing() {
        let (pill, isKept) = failedPill()
        #expect(pill.state.isFailure)
        #expect(isKept())
    }

    @Test("dismissing the row lets the audio go")
    func dismissed() {
        let (pill, isKept) = failedPill()
        pill.dismissFailure()
        #expect(!isKept())
    }

    @Test("the next dictation, or any other pill state, lets the audio go",
          arguments: [PillState.listening, .handsFree(startedAt: .distantPast), .actionListening, .recordingNote(startedAt: .distantPast), .idle])
    func replaced(next: PillState) {
        let (pill, isKept) = failedPill()
        pill.state = next
        #expect(!isKept())
    }

    @Test("trying again lets go of the row's hold on the audio")
    func retried() {
        let (pill, isKept) = failedPill()
        pill.retryFailure()
        #expect(!isKept(), "the run that was started owns it now")
    }

    @Test("a newer failure replaces the older one's audio")
    func newerFailure() {
        let (pill, isKept) = failedPill()
        pill.present(failure: .heardNothing)
        #expect(!isKept())
        pill.retryFailure()
        #expect(pill.state == .failed(.heardNothing))
    }

    // MARK: Ten minutes at most

    @Test("the audio is held for ten minutes at most")
    func lifetime() {
        #expect(DictationFailure.keptAudioLifetime == .seconds(600))
    }

    @Test("when its time is up the audio goes; the row stays, says so, and no longer offers Try again")
    func expired() {
        let counter = Counter()
        let (pill, isKept) = failedPill(counter)
        pill.dropKeptAudio(shownAt: pill.stateRevision)
        #expect(!isKept())
        #expect(pill.state == .failed(.transcription(recordingKept: false)))
        #expect(pill.accessibilityLabel == "Couldn't transcribe. Recording not kept, dictate again.")
        #expect(pill.state.recoveryActions == [.dismiss])
        #expect(pill.selfDismissDelay == nil, "the row itself still has no timer")
        pill.retryFailure()
        #expect(counter.runs == 0)
    }

    @Test("a timer from an earlier row cannot touch a later state",
          arguments: [PillState.idle, .listening, .processing(), .done(words: 9), .noField(.copiedAutomatically),
                      .failed(.heardNothing), .failed(.transcription(recordingKept: false))])
    func staleTimer(later: PillState) {
        let (pill, _) = failedPill()
        let shown = pill.stateRevision
        pill.state = later
        pill.dropKeptAudio(shownAt: shown)
        #expect(pill.state == later)
    }

    @Test("a timer from an earlier failure cannot drop a newer failure's audio")
    func staleTimerAndNewerAudio() {
        let (pill, _) = failedPill()
        let shown = pill.stateRevision
        var audio: KeptAudio? = KeptAudio()
        weak var newer = audio
        pill.present(failure: .transcription(recordingKept: true)) { [audio] in _ = audio }
        audio = nil
        pill.dropKeptAudio(shownAt: shown)
        #expect(newer != nil)
        #expect(pill.state == .failed(.transcription(recordingKept: true)))
    }

    @Test("the timer runs by itself", .timeLimit(.minutes(1)))
    func timerFires() async {
        let (pill, isKept) = failedPill(keptFor: .milliseconds(20))
        while pill.state != .failed(.transcription(recordingKept: false)) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!isKept())
    }

    @Test("a row dismissed before its time is left alone when the time comes", .timeLimit(.minutes(1)))
    func timerAfterDismiss() async {
        let (pill, _) = failedPill(keptFor: .milliseconds(20))
        pill.dismissFailure()
        pill.state = .listening
        try? await Task.sleep(for: .milliseconds(120))
        #expect(pill.state == .listening)
    }

    @Test("a stray state write cannot bring the audio back")
    func strayWrite() {
        let counter = Counter()
        let (pill, _) = failedPill(counter)
        pill.state = .idle
        pill.state = .failed(.transcription(recordingKept: true))
        pill.retryFailure()
        #expect(counter.runs == 0)
    }
}
