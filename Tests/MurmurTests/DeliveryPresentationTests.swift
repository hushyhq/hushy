import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Every `DeliveryResult` → History status, pill and hold time: the controller's side of the
/// "focus moved before the paste" policy (DECISIONS 2026-09-27).
@Suite("Delivery presentation — status, pill and timing per delivery outcome")
struct DeliveryPresentationTests {
    private let text = "Ship it on Thursday."

    @Test("copy-only decisions retain the AX diagnosis")
    @MainActor func copyOnlyDiagnosis() {
        #expect(TextInserter.shouldLogPasteDiagnosis(answer: .noField, result: .noField(copied: true)))
        #expect(TextInserter.shouldLogPasteDiagnosis(answer: .field, result: .copied(.app)))
        #expect(TextInserter.shouldLogPasteDiagnosis(answer: .unknown, result: .unknownUnreadable))
        #expect(!TextInserter.shouldLogPasteDiagnosis(answer: .field, result: .pasted))
    }

    private func make(_ result: DeliveryResult, text: String? = nil, asHeard: Bool = false) -> DeliveryPresentation {
        DeliveryPresentation.make(result, text: text ?? self.text, usedContext: false, asHeard: asHeard)
    }

    @Test("a paste is inserted and shows Pasted")
    func pasted() {
        let shown = make(.pasted)
        #expect(shown.status == .inserted)
        #expect(shown.feedback == .pill(.done(words: 4)))
        #expect(shown.hold == .milliseconds(700), "Done is about 0.7 s, then idle")
    }

    @Test("uncertain paste shows the appropriate recovery")
    func uncertainPaste() {
        #expect(make(.unknownConfirmed).feedback == .pill(.done(words: 4)))
        let notLanded = make(.unknownNotLanded)
        #expect(notLanded.status == .notInserted)
        #expect(notLanded.feedback == .pill(.noField(.copiedAutomaticallyUnconfirmed)))
        #expect(notLanded.hold == .zero)
        let unreadable = make(.unknownUnreadable)
        #expect(unreadable.feedback == .pill(.pastedUnchecked), "sent, nothing wrong seen: one quiet line")
        #expect(unreadable.status == .inserted)
        #expect(unreadable.hold == .zero)
        #expect(make(.unknownUnreadableReturnSkipped(.app)).feedback == .pill(.noField(.copiedAutomaticallyUnconfirmed)))
    }

    @Test("cancelled after ⌘V went to an uncertain target: History keeps it as inserted, no card, no words")
    func cancelledAfterUncertainPaste() {
        let shown = make(.unknownCancelled)
        #expect(shown.status == .inserted, "the paste may have landed")
        #expect(shown.feedback == .notice("Cancelled · it's in History"))
    }

    @Test("a paste the model skipped says as heard for longer")
    @MainActor
    func pastedAsHeard() {
        let shown = make(.pasted, asHeard: true)
        #expect(shown.feedback == .pill(.done(words: 4, asHeard: true)))
        #expect(shown.hold == DeliveryPresentation.quickCleanupHold)
        #expect(PillModel.doneLine(words: 4, asHeard: true, notSent: false) == "Pasted · quick cleanup only")
    }

    @Test("a refused model reply keeps the same pill row with its own explanation")
    @MainActor
    func pastedAfterRewriteRefusal() {
        let shown = DeliveryPresentation.make(
            .pasted, text: text, usedContext: false, asHeard: true, notARewrite: true)
        #expect(shown.feedback == .pill(.done(words: 4, asHeard: true, notARewrite: true)))
        #expect(shown.hold == .milliseconds(1_400), "a refused rewrite keeps the shorter as-heard hold")
        #expect(PillModel.doneLine(words: 4, asHeard: true, notSent: false, notARewrite: true) == "as heard")
        #expect(PillModel.doneExplanation(asHeard: true, notSent: false, notARewrite: true)
            .contains("A check protecting the meaning of what you said rejected the model’s rewrite"))
    }

    @Test("a paste whose Return was withheld is inserted and flagged so the pill says Return was not pressed")
    func pastedNotSent() {
        let shown = make(.pastedReturnSkipped(.app))
        #expect(shown.status == .inserted)
        #expect(shown.feedback == .pill(.done(words: 4, notSent: true)))
        #expect(shown.hold == DeliveryPresentation.noticeHold, "a line of words gets the notices' hold, not the bare ✓'s")
        #expect(make(.returnWithheld(.app), text: "").hold == shown.hold, "the same hold as the other Return notice")
    }

    @Test("a command-only Return that landed shows Pasted")
    func returnSent() {
        let shown = make(.returnSent, text: "")
        #expect(shown.status == .inserted)
        #expect(shown.feedback == .pill(.done(words: 0)))
    }

    @Test("a moved target is not inserted and opens the not-pasted card with the reason", arguments: TargetChange.allCases)
    func copied(change: TargetChange) {
        let shown = make(.copied(change))
        #expect(shown.status == .notInserted)
        #expect(shown.feedback == .pill(.noField(.notPasted(.targetChanged(change)))))
        #expect(shown.hold == .zero, "the card's own timer and hover rule own its lifetime")
    }

    @Test("paste failed: copied for ⌘V, and the card shows the words")
    func pasteFailed() {
        let shown = make(.dispatchFailed(copied: true))
        #expect(shown.status == .notInserted)
        #expect(shown.feedback == .pill(.noField(.notPasted(.pasteFailed))))
        #expect(shown.hold == .zero)
    }

    @Test("pill copy names why nothing was pasted")
    func copiedPhrases() {
        #expect(CopyReason.targetChanged(.app).phrase == "switched apps")
        #expect(CopyReason.targetChanged(.window).phrase == "switched windows")
        #expect(CopyReason.targetChanged(.field).phrase == "moved to another field")
        #expect(CopyReason.targetChanged(.fieldClosed).phrase == "field closed")
        #expect(CopyReason.pasteFailed.phrase == "couldn't paste here")
    }

    @Test("VoiceOver says what happened and how to paste")
    func copiedAccessibility() {
        #expect(CopyReason.targetChanged(.app).accessibilityText
                == "Not pasted: switched apps. Copied to the clipboard; press Command V to paste.")
        #expect(CopyReason.pasteFailed.accessibilityText.hasSuffix("press Command V to paste."))
    }

    @Test("a password field is held: a one-line row with Copy, no text, 6 s", arguments: [TargetChange?.none, .app, .field])
    func heldForSecureField(change: TargetChange?) {
        let shown = make(.heldForSecureField(change))
        #expect(shown.status == .notInserted)
        #expect(shown.feedback == .pill(.held(copied: false)))
        #expect(shown.hold == .zero, "the pill times the row (6 s) and waits for the pointer")
        #expect(PillState.held(copied: false).selfDismissDelay == .seconds(6))
    }

    @Test("a withheld Return is a quiet notice naming the reason")
    func returnWithheld() {
        #expect(make(.returnWithheld(.app), text: "").feedback == .notice("Didn't press Return · switched apps"))
        #expect(make(.returnWithheld(nil), text: "").feedback
                == .notice("Didn't press Return · a password field has focus"))
        #expect(make(.returnWithheld(.field), text: "").status == .notInserted)
    }

    @Test("a failed command-only Return is a notice, not an empty row",
          arguments: [DeliveryResult.dispatchFailed(copied: false), .noField(copied: false)])
    func failedReturnOnly(result: DeliveryResult) {
        #expect(make(result, text: "").feedback == .notice("Couldn't press Return here"))
    }

    @Test("a delivery that gave way with words in it opens the card, so they can be read and copied",
          arguments: [DeliveryResult.cancelled, .dispatchFailed(copied: false)])
    func cancelled(result: DeliveryResult) {
        let shown = make(result)
        #expect(shown.status == .notInserted)
        #expect(shown.feedback == .pill(.noField(.plainNotPasted)))
        #expect(shown.hold == .zero, "the pill times the card and waits for the pointer")
        #expect(!String(describing: shown).contains("Thursday"), "the state still carries no words")
    }

    @Test("a cancelled delivery with no words in it stays a quiet notice")
    func cancelledWithNothing() {
        #expect(make(.cancelled, text: "").feedback == .notice("Couldn't press Return here"))
    }

    @Test("a long result that didn't land opens the card, and its words are still not in the state",
          arguments: [DeliveryResult.dispatchFailed(copied: true), .copied(.app)])
    func longNotPasted(result: DeliveryResult) {
        let long = Array(repeating: "word", count: 142).joined(separator: " ")
        let shown = make(result, text: long)
        #expect(shown.hold == .zero, "the pill times the card and waits for the pointer")
        #expect(!String(describing: shown).contains("word word"))
    }

    @Test("a long pasted result says how many words landed")
    func longPasted() {
        let long = Array(repeating: "word", count: 142).joined(separator: " ")
        #expect(make(.pasted, text: long).feedback == .pill(.done(words: 142)))
    }

    @Test("no outcome's pill state or notice carries the dictated text", arguments: DeliveryPresentationTests.allResults)
    func neverCarriesText(result: DeliveryResult) {
        let secret = "hunter2 correct horse battery staple"
        for text in [secret, ""] {
            let shown = make(result, text: text)
            #expect(!String(describing: shown).contains("hunter2"), "\(result)")
            #expect(!String(reflecting: shown.feedback).contains("hunter2"), "\(result)")
        }
    }

    static let allResults: [DeliveryResult] = [
        .pasted, .pastedReturnSkipped(.app), .pastedReturnSkipped(nil), .returnSent,
        .returnWithheld(.app), .returnWithheld(nil), .copied(.app), .copied(.window), .copied(.field),
        .copied(.fieldClosed), .heldForSecureField(nil), .heldForSecureField(.app),
        .noField(copied: true), .noField(copied: false), .dispatchFailed(copied: true),
        .dispatchFailed(copied: false), .cancelled, .unknownConfirmed,
        .unknownConfirmedReturnSkipped(.field), .unknownUnreadable,
        .unknownUnreadableReturnSkipped(.app), .unknownNotLanded, .unknownCancelled,
    ]
}
