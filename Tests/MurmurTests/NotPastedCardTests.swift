import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The founder's rule for dictated words on the pill (2026-10-10): a dictation that was pasted
/// leaves no words on the pill; one that could not be pasted opens the pill to show them, with a
/// clear way to copy, and closes when the person copies, dismisses or dictates again.
@Suite("Not-pasted card: words only when the pill is open")
@MainActor
struct NotPastedCardTests {
    private let text = "Ship it on Thursday, and tell Dana."
    private let secret = "hunter2 correct horse battery staple"

    private func make(_ result: DeliveryResult, text: String? = nil) -> DeliveryPresentation {
        DeliveryPresentation.make(result, text: text ?? self.text, usedContext: false, asHeard: false)
    }

    private final class Recorder { var values: [String] = [] }

    // MARK: Pasted: no words

    @Test("every pasted outcome is a state with no words in it, and the pill keeps none",
          arguments: [DeliveryResult.pasted, .returnSent, .unknownConfirmed, .pastedReturnSkipped(nil)])
    func pastedShowsNoWords(result: DeliveryResult) {
        let shown = make(result, text: secret)
        #expect(shown.status == .inserted)
        guard case .pill(let state) = shown.feedback else {
            Issue.record("a pasted dictation is a pill state")
            return
        }
        if case .noField = state { Issue.record("a pasted dictation never opens the card") }
        #expect(!String(reflecting: state).contains("hunter2"))
        let pill = PillModel()
        pill.present(state, text: secret)
        #expect(pill.noFieldText == nil, "the small pill has no words to draw")
        #expect(!pill.accessibilityLabel.contains("hunter2"))
        #expect(PillPanel.size(for: state).height == PillPanel.size.height, "and it stays pill-sized")
    }

    // MARK: Not pasted: the pill opens

    @Test("every dictation that could not be pasted opens the card and gives it the words", arguments: [
        (DeliveryResult.noField(copied: false), NoFieldMode.offerCopy),
        (.noField(copied: true), .copiedAutomatically),
        (.unknownNotLanded, .copiedAutomaticallyUnconfirmed),
        (.copied(.app), .notPasted(.targetChanged(.app))),
        (.copied(.field), .notPasted(.targetChanged(.field))),
        (.dispatchFailed(copied: true), .notPasted(.pasteFailed)),
    ])
    func notPastedOpensTheCard(result: DeliveryResult, mode: NoFieldMode) {
        let shown = make(result)
        #expect(shown.status == .notInserted)
        #expect(shown.feedback == .pill(.noField(mode)))
        #expect(shown.hold == .zero, "the pill times the card and waits for the pointer")
        let pill = PillModel()
        pill.present(.noField(mode), text: text)
        #expect(pill.noFieldText == text)
        #expect(PillState.noField(mode).isInteractive)
        #expect(PillPanel.size(for: .noField(mode)).height == PillPanel.size.height + NoFieldCard.panelHeight(for: mode))
        #expect(!String(reflecting: pill.state).contains("Thursday"), "the state itself still carries no words")
    }

    @Test("a password field is the exception: its row never shows or copies the words by itself")
    func passwordFieldStaysClosed() {
        let shown = make(.heldForSecureField(nil), text: secret)
        #expect(shown.feedback == .pill(.held(copied: false)))
        let pill = PillModel()
        pill.present(.held(copied: false), text: secret)
        #expect(pill.noFieldText == nil)
    }

    // MARK: What the card says

    @Test("when the text is already on the clipboard every card still offers Copy again, the uncertain one included",
          arguments: [NoFieldMode.copiedAutomatically, .copiedAutomaticallyUnconfirmed, .notPasted(.targetChanged(.app)), .notPasted(.pasteFailed)])
    func alreadyOnTheClipboard(mode: NoFieldMode) {
        #expect(mode.wasCopiedAutomatically)
        #expect(mode.statusLine == (mode == .copiedAutomaticallyUnconfirmed ? "On clipboard · ⌘V" : "Copied to clipboard"))
        #expect(mode.copyButtonTitle == "Copy again")
        #expect(mode.afterCopy != nil, "the button is live")
        #expect(NoFieldCard.copyAccessibilityLabel(mode) == "Copy what you said again")
        #expect(mode.dismissDelay == (mode == .copiedAutomaticallyUnconfirmed ? .seconds(8) : .seconds(10)))
    }

    @Test("when the clipboard was left alone the card offers Copy and claims nothing",
          arguments: [NoFieldMode.offerCopy])
    func clipboardUntouched(mode: NoFieldMode) {
        #expect(!mode.wasCopiedAutomatically)
        #expect(mode.statusLine == nil)
        #expect(mode.copyButtonTitle == "Copy")
        #expect(NoFieldCard.copyAccessibilityLabel(mode) == "Copy what you said")
    }

    @Test("unreadable paste with Return withheld previews the staged text, stays while hovered and copies again only when pressed")
    func unreadablePasteRecovery() {
        // Sent and unreadable with nothing else wrong is the quiet "Pasted" row (`PastedUncheckedTests`),
        // which opens this same card on a click. Focus moving before Return opens it at once.
        let shown = make(.unknownUnreadableReturnSkipped(.app), text: "Vela toggles the amber beacon.")
        #expect(shown.status == .inserted, "the paste may have landed; History keeps its existing status")
        #expect(shown.feedback == .pill(.noField(.copiedAutomaticallyUnconfirmed)))
        #expect(shown.hold == .zero)
        let mode = NoFieldMode.copiedAutomaticallyUnconfirmed
        #expect(mode.reasonLine == "Couldn't confirm the paste")
        #expect(mode.hintLine == "Check the field first. Your text may already be there.")
        #expect(mode.statusLine == "On clipboard · ⌘V")
        #expect(mode.dismissDelay == .seconds(8))
        #expect(PillState.noField(mode).selfDismissDecision(pointerOverCard: true) == .wait(PillState.pointerGrace))
        let copies = Recorder()
        let pill = PillModel()
        pill.onPlainCopy = { copies.values.append($0) }
        pill.present(.noField(mode), text: "Vela toggles the amber beacon.")
        #expect(pill.noFieldText == "Vela toggles the amber beacon.")
        #expect(copies.values.isEmpty, "opening the card writes nothing: the paste already staged the text")
        pill.copyNoFieldText()
        #expect(copies.values == ["Vela toggles the amber beacon."], "Copy again is the person's own copy")
        #expect(pill.state == .noField(.copiedUnconfirmed))
        #expect(NoFieldMode.copiedUnconfirmed.reasonLine == "Couldn't confirm the paste")
        #expect(pill.accessibilityLabel == "Couldn't confirm the paste. Copied.")
    }

    @Test("the reason line says why it was not pasted")
    func reasonLines() {
        #expect(NoFieldMode.notPasted(.targetChanged(.app)).reasonLine == "Not pasted · switched apps")
        #expect(NoFieldMode.notPasted(.targetChanged(.window)).reasonLine == "Not pasted · switched windows")
        #expect(NoFieldMode.notPasted(.targetChanged(.field)).reasonLine == "Not pasted · moved to another field")
        #expect(NoFieldMode.notPasted(.targetChanged(.fieldClosed)).reasonLine == "Not pasted · field closed")
        #expect(NoFieldMode.notPasted(.pasteFailed).reasonLine == "Not pasted · couldn't paste here")
        #expect(NoFieldMode.notPastedCopiedAgain(.pasteFailed).reasonLine == "Not pasted · couldn't paste here")
        #expect(NoFieldMode.copiedAutomatically.reasonLine == "No text field to type into")
    }

    @Test("VoiceOver reads the reason and the clipboard, never the words")
    func accessibility() {
        let pill = PillModel()
        pill.present(.noField(.notPasted(.targetChanged(.app))), text: secret)
        #expect(pill.accessibilityLabel == "Not pasted: switched apps. Copied to the clipboard; press Command V to paste.")
        pill.copyNoFieldText()
        #expect(pill.accessibilityLabel == "Not pasted · switched apps. Copied.")
        #expect(!pill.accessibilityLabel.contains("hunter2"))
    }

    // MARK: Closing

    @Test("Copy again copies once more, reads Copied for a moment and the card closes",
          arguments: [
              (NoFieldMode.copiedAutomatically, NoFieldMode.copied),
              (.notPasted(.targetChanged(.app)), .notPastedCopiedAgain(.targetChanged(.app))),
              (.copiedAutomaticallyUnconfirmed, .copiedUnconfirmed),
              (.offerCopy, .copied),
          ])
    func copyCloses(mode: NoFieldMode, after: NoFieldMode) {
        let copies = Recorder()
        let pill = PillModel()
        pill.onPlainCopy = { copies.values.append($0) }
        pill.present(.noField(mode), text: text)
        pill.copyNoFieldText()
        #expect(copies.values == [text])
        #expect(pill.state == .noField(after))
        #expect(after.copyButtonTitle == "Copied")
        #expect(after.afterCopy == nil)
        #expect(PillState.noField(after).selfDismissDelay == .milliseconds(1_400))
        pill.copyNoFieldText()
        #expect(copies.values == [text], "a second tap copies nothing more")
    }

    @Test("dismissing, or the next dictation, closes the card and drops the words")
    func dismissAndNextDictation() {
        let pill = PillModel()
        pill.present(.noField(.notPasted(.pasteFailed)), text: secret)
        pill.state = .idle // ✕
        #expect(pill.noFieldText == nil)
        pill.present(.noField(.notPasted(.pasteFailed)), text: secret)
        pill.state = .listening // the next dictation starts
        #expect(pill.noFieldText == nil)
        pill.state = .noField(.notPasted(.pasteFailed)) // a stray state write must not resurrect the words
        #expect(pill.noFieldText == nil)
    }

    @Test("left alone it goes after 10 s, and not while the pointer rests on it")
    func timer() {
        let card = PillState.noField(.notPasted(.targetChanged(.app)))
        #expect(card.selfDismissDelay == .seconds(10))
        #expect(card.selfDismissDecision(pointerOverCard: true) == .wait(PillState.pointerGrace))
        #expect(card.selfDismissDecision(pointerOverCard: false) == .dismiss)
        #expect(card.keyScope == .none, "it takes no key from the app in front")
    }

    @Test("a long dictation is shown whole, scrolling inside the card; Copy still copies all of it")
    func longText() {
        let long = Array(repeating: "the quick brown fox jumps over the lazy dog", count: 20).joined(separator: " ")
        #expect(NoFieldText.display(long) == long, "no word is dropped and nothing ends in an ellipsis")
        let copies = Recorder()
        let pill = PillModel()
        pill.onPlainCopy = { copies.values.append($0) }
        pill.present(.noField(.notPasted(.pasteFailed)), text: long)
        pill.copyNoFieldText()
        #expect(copies.values == [long])
    }
}
