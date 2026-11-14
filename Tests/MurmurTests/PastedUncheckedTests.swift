import Foundation
import MurmurCore
import SwiftUI
import Testing
@testable import Murmur

/// A paste Hushy sent but could not read back, with nothing seen going wrong. The person usually
/// just watched their text appear, so the pill says "Pasted" in one quiet line, not a card. The
/// words stay on the clipboard and one click opens the card that shows them. The opened card is
/// kept for evidence that the paste failed.
@Suite("Pasted, unchecked — the quiet row, what opens a card, and how to reach the words")
@MainActor
struct PastedUncheckedTests {
    private let text = "Vela toggles the amber beacon before the ferry leaves."

    private func make(_ result: DeliveryResult) -> DeliveryPresentation {
        DeliveryPresentation.make(result, text: text, usedContext: false, asHeard: false)
    }

    private func pill(showing state: PillState = .pastedUnchecked) -> PillModel {
        let pill = PillModel()
        pill.present(state, text: text)
        return pill
    }

    // MARK: Which surface follows from which evidence

    @Test("sent, unreadable, nothing wrong seen: the quiet row, History says inserted")
    func unreadableIsQuiet() {
        let shown = make(.unknownUnreadable)
        #expect(shown.feedback == .pill(.pastedUnchecked))
        #expect(shown.status == .inserted)
        #expect(shown.hold == .zero, "the pill times this row, so the pointer can hold it")
    }

    @Test("evidence of failure opens the card with the words",
          arguments: [
              DeliveryResult.unknownNotLanded, .unknownUnreadableReturnSkipped(.app),
              .unknownUnreadableReturnSkipped(nil), .copied(.app), .copied(.field), .copied(.window),
              .copied(.fieldClosed), .noField(copied: true), .noField(copied: false),
              .dispatchFailed(copied: true), .dispatchFailed(copied: false), .cancelled,
          ])
    func failureOpensTheCard(result: DeliveryResult) {
        guard case .pill(.noField(let mode)) = make(result).feedback else {
            Issue.record("\(result) should open the not-pasted card")
            return
        }
        #expect(mode.copyButtonTitle == "Copy" || mode.copyButtonTitle == "Copy again", "every opened card can copy")
    }

    @Test("focus moved before Return still opens the unconfirmed card, as before")
    func returnSkippedKeepsTheCard() {
        #expect(make(.unknownUnreadableReturnSkipped(.app)).feedback == .pill(.noField(.copiedAutomaticallyUnconfirmed)))
        #expect(make(.unknownNotLanded).feedback == .pill(.noField(.copiedAutomaticallyUnconfirmed)))
    }

    @Test("a confirmed paste is the ordinary tick, never the quiet row",
          arguments: [DeliveryResult.pasted, .unknownConfirmed, .returnSent])
    func confirmedIsTheTick(result: DeliveryResult) {
        guard case .pill(.done) = make(result).feedback else {
            Issue.record("\(result) should show the confirmed tick")
            return
        }
    }

    @Test("no delivery but the unreadable one shows the quiet row",
          arguments: DeliveryPresentationTests.allResults.filter { $0 != .unknownUnreadable })
    func onlyUnreadableIsQuiet(result: DeliveryResult) {
        #expect(make(result).feedback != .pill(.pastedUnchecked))
    }

    // MARK: What it says

    @Test("the line is the one word, and VoiceOver hears the whole truth")
    func wording() {
        #expect(PastedUncheckedRow.line == "Pasted")
        let pill = pill()
        #expect(pill.accessibilityLabel == "Pasted. Hushy could not check the field, so the text is also on your clipboard.",
                "a listener cannot see the muted tick")
        #expect(pill.recoveryAnnouncement == "Pasted, not checked. Also on your clipboard.",
                "said after every dictation in an unreadable app, so it is short and still says all three things")
        #expect(pill.recoveryAnnouncement?.contains("Vela") == false)
        #expect(!pill.accessibilityLabel.contains("Vela"))
        #expect(!String(reflecting: pill.state).contains("Vela"))
    }

    @Test("the tick is not the confirmed lime one")
    func mutedTick() {
        #expect(PastedUncheckedRow.tickTint != Theme.phosphorFill)
        #expect(PastedUncheckedRow.tickTint != Theme.success)
    }

    // MARK: How long it stays

    @Test("it stays as long as the other one-line notices, and no new number was added")
    func lifetime() {
        #expect(PillState.pastedUnchecked.selfDismissDelay == DeliveryPresentation.noticeHold)
        #expect(pill().selfDismissDelay == DeliveryPresentation.noticeHold)
    }

    @Test("the pointer resting on it holds it; for a sighted person nothing else does")
    func pointerHolds() {
        let state = PillState.pastedUnchecked
        #expect(state.selfDismissDecision(pointerOverCard: true) == .wait(PillState.pointerGrace))
        #expect(state.selfDismissDecision(pointerOverCard: false) == .dismiss)
    }

    @Test("while VoiceOver is running the row waits, so its actions can be reached")
    func voiceOverHolds() {
        let state = PillState.pastedUnchecked
        #expect(state.selfDismissDecision(pointerOverCard: false, voiceOverRunning: true) == .wait(PillState.pointerGrace))
        let pill = pill()
        #expect(pill.state.recoveryActions.contains(.dismiss), "a row that waits can be sent away")
        pill.perform(.dismiss)
        #expect(pill.state == .idle)
        #expect(pill.noFieldText == nil)
    }

    @Test("it is a pill-sized row that takes a click and no key")
    func pillSized() {
        let state = PillState.pastedUnchecked
        #expect(PillPanel.size(for: state) == PillPanel.size(for: .done(words: 4)), "no wider or taller than Done")
        #expect(state.isInteractive)
        #expect(state.keyScope == .none, "esc and return keep going to the app being typed in")
        #expect(!PillLayout.canStandVertical(state))
    }

    // MARK: One click to the words

    @Test("one click opens the unconfirmed card with every word and Copy again")
    func expandShowsTheWords() {
        let pill = pill()
        var copied: [String] = []
        pill.onPlainCopy = { copied.append($0) }
        pill.showUncheckedWords()
        #expect(pill.state == .noField(.copiedAutomaticallyUnconfirmed))
        #expect(pill.noFieldText == text)
        #expect(copied.isEmpty, "opening the card writes nothing: the dictation is already on the clipboard")
        guard case .noField(let mode) = pill.state else { return }
        #expect(mode.copyButtonTitle == "Copy again")
        #expect(mode.statusLine == "On clipboard · ⌘V")
        pill.copyNoFieldText()
        #expect(copied == [text])
        #expect(pill.state == .noField(.copiedUnconfirmed))
    }

    @Test("the opened card stays its own, longer time")
    func openedCardHasTheCardsTime() {
        let pill = pill()
        pill.showUncheckedWords()
        #expect((pill.selfDismissDelay ?? .zero) >= .seconds(8))
    }

    @Test("VoiceOver can open the words by name")
    func showIsANamedAction() {
        let pill = pill()
        #expect(pill.state.recoveryActions == [.showWords, .dismiss])
        #expect(RecoveryAction.showWords.title == "Show what you said")
        pill.perform(.showWords)
        #expect(pill.state == .noField(.copiedAutomaticallyUnconfirmed))
    }

    @Test("show does nothing on any other row")
    func showOnlyFromTheQuietRow() {
        let pill = pill(showing: .done(words: 9))
        pill.showUncheckedWords()
        #expect(pill.state == .done(words: 9))
        #expect(pill.noFieldText == nil)
    }

    @Test("the words are dropped the moment the row goes, unless the card took them")
    func wordsDroppedWithTheRow() {
        let pill = pill()
        #expect(pill.noFieldText == text)
        pill.state = .idle
        #expect(pill.noFieldText == nil)
        pill.state = .pastedUnchecked // a stray state write has no words behind it
        pill.showUncheckedWords()
        #expect(pill.state == .pastedUnchecked)
    }

    // MARK: Every expanded state can copy

    @Test("every card this change can lead to shows a Copy control and says where the text is",
          arguments: [NoFieldMode.copiedAutomaticallyUnconfirmed, .copiedUnconfirmed])
    func expandedStatesCanCopy(mode: NoFieldMode) {
        #expect(["Copy again", "Copied"].contains(mode.copyButtonTitle))
        #expect(mode.capsuleLabel == nil, "the capsule under the card says the text is on the clipboard")
        #expect(mode.recoveryLine == ShortcutHelp.pasteLastLine)
    }
}
