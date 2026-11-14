import Carbon.HIToolbox
import Foundation
import Testing
@testable import Murmur

/// A dictation that produced no text stays on the pill until it has been seen: no timer clears
/// it, ✕ or the next dictation does, and it takes neither focus nor a key from the app in front.
@Suite("Recovery: a failure stays until it has been seen")
@MainActor
struct RecoveryFailureTests {
    nonisolated static let all: [DictationFailure] = [
        .transcription(recordingKept: true), .transcription(recordingKept: false), .noWords, .nothingToWrite,
        .heardNothing, .micSilent, .headsetConnecting, .didNotStart("Mic didn't start. Check Settings → General"),
        .noteIncomplete,
        .usingAutomatic, .pickUndone(mic: "MacBook Pro Microphone", backTo: nil),
        .quietMic(QuietMic(micName: "Dana's AirPods Pro", isSilent: true, betterInput: "MacBook Pro Microphone", headsetSilence: true)),
        .micUnreadable(mic: "Alexandria's Example Buds Pro Max (2nd generation)", next: .putBack),
        .micUnreadable(mic: "MacBook Pro Microphone", next: .offerAutomatic), .micUnreadable(mic: nil, next: .dictateAgain),
        .pickUndone(mic: "Alexandria's Example Buds Pro Max (2nd generation)", backTo: "MacBook Pro Microphone"),
        .quietMic(QuietMic(micName: "MacBook Pro Microphone", isSilent: true, betterInput: nil, offersAutomatic: true)),
        // The quiet-microphone row at its widest: the longest names a row draws, with and without the offer.
        .quietMic(QuietMic(micName: "Alexandria's Example Buds Pro Max (2nd generation)", isSilent: false,
                           betterInput: "MacBook Pro Microphone")),
        .quietMic(QuietMic(micName: "Alexandria's Example Buds Pro Max (2nd generation)", isSilent: false, betterInput: nil)),
        .quietMic(QuietMic(micName: "MacBook Pro Microphone", isSilent: true, betterInput: nil)),
        .micSwitched(to: "Alexandria's Example Studio Display Microphone"),
    ]

    // MARK: Staying

    @Test("no timer clears a failure, on the state or on the pill", arguments: all)
    func stays(failure: DictationFailure) {
        #expect(PillState.failed(failure).selfDismissDelay == nil)
        let pill = PillModel()
        pill.present(failure: failure)
        #expect(pill.state == .failed(failure))
        #expect(pill.selfDismissDelay == nil)
        #expect(pill.isVisible)
    }

    @Test("✕ closes it, and only it")
    func dismiss() {
        let pill = PillModel()
        pill.present(failure: .heardNothing)
        pill.dismissFailure()
        #expect(pill.state == .idle)
        pill.state = .listening
        pill.dismissFailure()
        #expect(pill.state == .listening, "a dictation under way is never dismissed by a stale ✕")
    }

    @Test("the next dictation replaces it at once")
    func nextDictationReplacesIt() {
        let pill = PillModel()
        pill.present(failure: .transcription(recordingKept: false))
        pill.state = .listening
        #expect(pill.state == .listening)
        #expect(!pill.state.isFailure)
    }

    // MARK: Quiet: pill-sized, no keys, no focus

    @Test("it is one pill-sized row that takes clicks on what it draws and no key", arguments: all)
    func quiet(failure: DictationFailure) {
        let state = PillState.failed(failure)
        #expect(state.isInteractive, "✕ is a button")
        #expect(state.keyScope == .none, "esc and ⏎ still reach the app being typed in")
        #expect(PillPanel.size(for: state).height == PillPanel.size.height, "no taller than the idle pill's panel")
        #expect(!PillLayout(anchor: .right).isVertical(state), "a row of words stays horizontal")
        #expect(!failure.line.contains("\n"))
        #expect(failure.line.count <= 60, "one line inside the panel: \(failure.line)")
    }

    @Test("esc and ⏎ are never taken for a failure row: a key the pill takes would not reach the app", arguments: all)
    func keysReachTheApp(failure: DictationFailure) {
        let pill = PillModel()
        pill.present(failure: failure)
        let scope = pill.keyScope(now: Date(), ownTextFieldFocused: false)
        #expect(scope == .none)
        #expect(PillKeyRouter.key(keyCode: kVK_Escape, flags: [], scope: scope) == nil)
        #expect(PillKeyRouter.key(keyCode: kVK_Return, flags: [], scope: scope) == nil)
    }

    // MARK: The words

    @Test("each failure says what happened and what to do")
    func lines() {
        #expect(DictationFailure.noWords.line == "Didn't catch any words · dictate again, a little louder")
        #expect(DictationFailure.nothingToWrite.line == "Couldn't make text from that · dictate again")
        #expect(DictationFailure.heardNothing.line == "Didn't hear anything · check your mic, then dictate again")
        #expect(DictationFailure.micSilent.line == "Mic sent no audio · pick another input in Settings")
        #expect(DictationFailure.headsetConnecting.line == "Headset was still connecting · give it a second, then speak")
        #expect(DictationFailure.didNotStart("Microphone access needed").line == "Microphone access needed")
    }

    @Test("the words keep the app's voice: no exclamation marks, em dashes, simply or just", arguments: all)
    func voice(failure: DictationFailure) {
        for sentence in [failure.line, PillModel().labelled(failure)] {
            #expect(!sentence.contains("!"), "\(sentence)")
            #expect(!sentence.contains("—"), "\(sentence)")
            let words = sentence.lowercased().split { !$0.isLetter }.map(String.init)
            #expect(!words.contains("simply"), "\(sentence)")
            #expect(!words.contains("just"), "\(sentence)")
        }
    }

    @Test("something broken sounds the error tone; nothing heard stays silent")
    func sound() {
        #expect(DictationFailure.transcription(recordingKept: true).playsErrorSound)
        #expect(DictationFailure.micSilent.playsErrorSound)
        #expect(DictationFailure.didNotStart("Microphone access needed").playsErrorSound)
        #expect(!DictationFailure.noWords.playsErrorSound)
        #expect(!DictationFailure.nothingToWrite.playsErrorSound)
        #expect(!DictationFailure.heardNothing.playsErrorSound)
        #expect(!DictationFailure.headsetConnecting.playsErrorSound, "a link coming up is nobody's fault")
    }
}

private extension PillModel {
    /// What the pill reads out for a failure.
    func labelled(_ failure: DictationFailure) -> String {
        present(failure: failure)
        return accessibilityLabel
    }
}
