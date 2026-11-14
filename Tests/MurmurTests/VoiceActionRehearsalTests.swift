import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The voice-action practice (Settings → Voice actions): it is no longer an onboarding step, and
/// its rehearsal turns what was heard into a demo chip without any model.
@Suite("Voice-action practice")
struct VoiceActionRehearsalTests {
    @Test("the close offers practice only after a successful first dictation; skipping leaves completion free")
    func onboardingOffer() {
        #expect(!OnboardingVoiceActionOffer.isShown(firstDictationWorked: false, hasPermissionGap: false, isModelPending: false, skipped: false))
        #expect(OnboardingVoiceActionOffer.isShown(firstDictationWorked: true, hasPermissionGap: false, isModelPending: false, skipped: false))
        #expect(!OnboardingVoiceActionOffer.isShown(firstDictationWorked: true, hasPermissionGap: false, isModelPending: false, skipped: true))
        #expect(!OnboardingVoiceActionOffer.isShown(firstDictationWorked: true, hasPermissionGap: true, isModelPending: false, skipped: false))
        #expect(!OnboardingVoiceActionOffer.isShown(firstDictationWorked: true, hasPermissionGap: false, isModelPending: true, skipped: false))
        #expect(OnboardingStep.required.last == .done)
    }

    @Test("the invitation names configured dictation and effective action keys")
    func onboardingKeys() {
        let option = OnboardingVoiceActionOffer.instruction(dictation: .rightCommand, action: .option)
        #expect(option.contains("fn + control"))
        #expect(option.contains("option twice"))
        let clash = OnboardingVoiceActionOffer.instruction(dictation: .rightOption, action: .option)
        #expect(clash.contains("control twice"))
        #expect(clash.contains("Tap control again to cancel"))
    }
    @Test("onboarding ends at the first dictation: Try it is followed by You're set")
    func onboardingHasNoVoiceActionStep() {
        #expect(OnboardingStep.required == [.welcome, .microphone, .accessibility, .hotkeyPractice, .tryIt, .done])
        #expect(!OnboardingStep.allCases.map(\.rawValue).contains("voiceActions"))
        var flow = OnboardingFlow()
        for _ in 0..<4 { flow = flow.advancing(eta: .ready, eligible: []) }
        #expect(flow.current == .tryIt)
        #expect(flow.advancing(eta: .ready, eligible: []).isLast)
    }

    @Test("Settings offers the practice and says it creates nothing")
    func settingsRow() {
        #expect(VoiceActionRehearsal.settingsRowTitle == "Practice a voice action")
        #expect(VoiceActionRehearsal.settingsRowDetail.contains("Nothing is created"))
        #expect(!VoiceActionRehearsal.notReadyLine.contains("Home"), "the practice lives in Settings, not Home")
    }

    @Test("the prompt becomes “Would add: Stretch · in 10 minutes”, practice, no Undo")
    func promptChip() {
        let chip = VoiceActionRehearsal.chip(for: "Remind me to stretch in 10 minutes.")
        #expect(chip.title == "Would add: Stretch")
        #expect(chip.detail == "in 10 minutes")
        #expect(chip.kind == .createReminder)
        #expect(chip.isPractice)
        #expect(!chip.canUndo, "nothing was created, so there is nothing to undo")
        #expect(!chip.title.hasPrefix("Added"))
    }

    @Test("other reminders keep their task; anything else is shown as heard")
    func otherPhrasings() {
        #expect(VoiceActionRehearsal.chip(for: "remind me to call dana in an hour").title == "Would add: Call dana")
        #expect(VoiceActionRehearsal.chip(for: "remind me to call dana in an hour").detail == "in an hour")
        let plain = VoiceActionRehearsal.chip(for: "what's on my calendar tomorrow")
        #expect(plain.title == "Would add: What's on my calendar tomorrow")
        #expect(plain.detail == nil)
    }

    @Test("a real chip is not practice and keeps its Undo")
    func realChipUnchanged() {
        let real = DoneChipState(title: "Added: Call Dana", kind: .createReminder, undoRecordID: 7)
        #expect(!real.isPractice)
        #expect(real.canUndo)
    }

    @Test("the line under the practice chip says nothing was added")
    func practiceLine() {
        #expect(VoiceActionRehearsal.practiceLine == "Practice only. Nothing was added to Reminders.")
    }

    @Test("the real-chip sentence reads its seconds from the one undo constant")
    func undoSentenceUsesConstant() {
        #expect(VoiceActionRehearsal.realChipLine.contains("\(ActionUndoWindow.seconds) seconds"))
    }
}

/// Undo has one duration: the chip, the record's Undo and the copy all read it from here.
@Suite("Undo window")
struct ActionUndoWindowTests {
    @Test("the done chip stays exactly as long as Undo works")
    @MainActor
    func chipMatchesUndo() {
        let chip = DoneChipState(title: "Added: Call Dana", kind: .createReminder, undoRecordID: 1)
        #expect(PillState.actionDone(chip).selfDismissDelay == ActionUndoWindow.duration)
        #expect(VoiceActionsController.defaultUndoWindow == ActionUndoWindow.interval)
    }

    @Test("a chip with nothing to undo does not linger for the undo window")
    func noUndoNoLinger() {
        let link = DoneChipState(title: "Opened: Gmail", kind: .openLink)
        #expect(PillState.actionDone(link).selfDismissDelay == .seconds(6))
    }

    @Test("the window is the longer of the two old numbers")
    func longerWins() {
        #expect(ActionUndoWindow.seconds == 8)
    }
}
