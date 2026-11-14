import Foundation
import Testing
@testable import Murmur

/// The recovery rows without a mouse: each has a label and an announcement that say what the
/// visible words say (never the dictated text), each of its buttons is a named action, and with
/// VoiceOver running a row that still has its action does not time out.
@Suite("Recovery: announced, and usable without a mouse")
@MainActor
struct RecoveryAccessibilityTests {
    private let secret = "hunter2 correct horse battery staple"
    private final class Recorder { var values: [String] = [] }

    // MARK: Actions

    @Test("the not-pasted card offers Copy and Dismiss by name, and only Dismiss once copied")
    func cardActions() {
        #expect(PillState.noField(.copiedAutomatically).recoveryActions == [.copy, .dismiss])
        #expect(PillState.noField(.plainNotPasted).recoveryActions == [.copy, .dismiss])
        #expect(PillState.noField(.copied).recoveryActions == [.dismiss])
        #expect(RecoveryAction.copy.title == "Copy what you said")
        #expect(RecoveryAction.dismiss.title == "Dismiss")
    }

    @Test("the password row offers Copy, Open in History and Dismiss")
    func heldActions() {
        #expect(PillState.held(copied: false).recoveryActions == [.copy, .openInHistory, .dismiss])
        #expect(PillState.held(copied: true).recoveryActions.isEmpty, "Copied closes by itself in a moment")
        #expect(RecoveryAction.openInHistory.title == "Open in History")
    }

    @Test("a failure offers Dismiss, and Try again only when its audio is kept")
    func failureActions() {
        #expect(PillState.failed(.transcription(recordingKept: true)).recoveryActions == [.tryAgain, .dismiss])
        #expect(PillState.failed(.transcription(recordingKept: false)).recoveryActions == [.dismiss])
        #expect(PillState.failed(.heardNothing).recoveryActions == [.dismiss])
        #expect(RecoveryAction.tryAgain.title == "Try again")
    }

    @Test("ordinary states have no recovery actions", arguments: [
        PillState.idle, .listening, .processing(), .done(words: 9), .error("Stopped listening"),
    ])
    func othersHaveNone(state: PillState) {
        #expect(state.recoveryActions.isEmpty)
        let pill = PillModel()
        pill.state = state
        #expect(pill.recoveryAnnouncement == nil)
    }

    @Test("an action does what its button does")
    func performing() {
        let copies = Recorder(), plain = Recorder(), history = Recorder(), retries = Recorder()
        let pill = PillModel()
        pill.onCopy = { copies.values.append($0) }
        pill.onPlainCopy = { plain.values.append($0) }
        pill.onOpenInHistory = { history.values.append($0) }

        pill.present(.noField(.offerCopy), text: "Ship it on Thursday.")
        pill.perform(.copy)
        #expect(plain.values == ["Ship it on Thursday."])
        #expect(pill.state == .noField(.copied))
        pill.perform(.dismiss)
        #expect(pill.state == .idle)

        pill.present(.held(copied: false), text: secret)
        pill.perform(.openInHistory)
        #expect(history.values == [secret])
        pill.present(.held(copied: false), text: secret)
        pill.perform(.copy)
        #expect(copies.values == [secret], "the password row's copy stays the marked one")

        pill.present(failure: .transcription(recordingKept: true)) { retries.values.append("ran") }
        pill.perform(.tryAgain)
        #expect(retries.values == ["ran"])
        pill.present(failure: .heardNothing)
        pill.perform(.dismiss)
        #expect(pill.state == .idle)
    }

    @Test("an action the showing row does not offer does nothing")
    func stale() {
        let pill = PillModel()
        pill.state = .listening
        pill.perform(.dismiss)
        #expect(pill.state == .listening, "a dictation under way is never dismissed by a stale action")
        pill.present(failure: .heardNothing)
        pill.perform(.tryAgain)
        #expect(pill.state == .failed(.heardNothing))
    }

    // MARK: Labels and announcements

    @Test("the card is announced with its reason, where the text is and how to get it back; never the words")
    func cardAnnouncement() {
        let pill = PillModel()
        pill.present(.noField(.copiedAutomatically), text: secret)
        #expect(pill.recoveryAnnouncement
                == "No text field to type into. Copied to the clipboard. Control Command V pastes your last dictation.")
        pill.present(.noField(.copiedAutomaticallyUnconfirmed), text: secret)
        #expect(pill.recoveryAnnouncement == "Couldn't confirm the paste. Check the field first. Your text may already "
                + "be there. Copied to the clipboard. Control Command V pastes your last dictation.")
        pill.present(.noField(.plainNotPasted), text: secret)
        #expect(pill.recoveryAnnouncement
                == "Not pasted. Press Copy to copy what you said. Control Command V pastes your last dictation.")
        pill.perform(.copy)
        #expect(pill.recoveryAnnouncement == "Not pasted. Copied.")
        #expect(pill.recoveryAnnouncement?.contains("hunter2") == false)
    }

    @Test("the password row is announced with both of its ways out, and no paste shortcut")
    func heldAnnouncement() {
        let pill = PillModel()
        pill.present(.held(copied: false), text: secret)
        #expect(pill.accessibilityLabel == "Not pasted: a password field has focus. Press Copy to copy the text, or History to read it.")
        #expect(pill.recoveryAnnouncement == pill.accessibilityLabel)
        #expect(pill.recoveryAnnouncement?.contains("hunter2") == false)
        #expect(pill.recoveryAnnouncement?.contains("Command V") == false)
    }

    @Test("a failure is announced in the same words it shows")
    func failureAnnouncement() {
        let pill = PillModel()
        pill.present(failure: .transcription(recordingKept: true)) {}
        #expect(pill.accessibilityLabel == "Couldn't transcribe. Your recording is still here. Press Try again to run it again.")
        #expect(pill.recoveryAnnouncement == pill.accessibilityLabel)
        pill.present(failure: .transcription(recordingKept: false))
        #expect(pill.recoveryAnnouncement == "Couldn't transcribe. Recording not kept, dictate again.")
        pill.present(failure: .heardNothing)
        #expect(pill.recoveryAnnouncement == "Didn't hear anything. Check your mic, then dictate again.")
        pill.present(failure: .didNotStart("Mic didn't start. Check Settings → General"))
        #expect(pill.recoveryAnnouncement == "Mic didn't start. Check Settings → General.")
    }

    @Test("the coordinator says a recovery row once as it appears, and nothing for ordinary states")
    func coordinatorAnnounces() {
        let said = Recorder()
        let pill = PillModel()
        let coordinator = PillCoordinator(pill: pill, fullScreenDetector: .never, announce: { said.values.append($0) })
        pill.state = .listening
        coordinator.announceRecovery()
        pill.state = .done(words: 9)
        coordinator.announceRecovery()
        #expect(said.values.isEmpty)
        pill.present(failure: .heardNothing)
        coordinator.announceRecovery()
        #expect(said.values == ["Didn't hear anything. Check your mic, then dictate again."])
    }

    // MARK: Time, with VoiceOver running

    @Test("with VoiceOver running a row that still has its action waits to be acted on or dismissed")
    func voiceOverHolds() {
        for state: PillState in [.noField(.copiedAutomatically), .noField(.plainNotPasted), .held(copied: false)] {
            #expect(state.selfDismissDecision(pointerOverCard: false, voiceOverRunning: true) == .wait(PillState.pointerGrace), "\(state)")
            #expect(state.selfDismissDecision(pointerOverCard: false, voiceOverRunning: false) == .dismiss, "\(state)")
        }
    }

    @Test("once copied it closes as usual, and other rows never wait for VoiceOver")
    func voiceOverDoesNotHoldTheRest() {
        for state: PillState in [.noField(.copied), .held(copied: true)] {
            #expect(state.selfDismissDecision(pointerOverCard: false, voiceOverRunning: true) == .dismiss, "\(state)")
        }
    }
}
