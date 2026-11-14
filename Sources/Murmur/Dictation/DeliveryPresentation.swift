import Foundation
import MurmurCore

/// What the user sees and what History records for one `DeliveryResult`. Pure, so every
/// delivery branch's status, pill and timing is unit-tested (`DeliveryPresentationTests`).
struct DeliveryPresentation: Equatable {
    enum Feedback: Equatable {
        case pill(PillState)
        /// A short, soundless notice (the `.error` pill without the error sound).
        case notice(String)
    }

    let status: Dictation.Status
    let feedback: Feedback
    /// How long the feedback stays before the pill returns to idle. Zero means the controller
    /// leaves it alone: the pill clears the row itself (the not-pasted card, the password row).
    let hold: Duration

    /// One-line rows with words to read: the notices, and Done when Return was withheld.
    static let noticeHold: Duration = .seconds(2.2)
    /// "Pasted · quick cleanup only" is a full sentence. About four seconds, long enough to read.
    static let quickCleanupHold: Duration = .seconds(4)

    /// How long Done stays. Quick cleanup (the model did not answer in time) holds
    /// `quickCleanupHold`. A refused rewrite holds 1.4 s. A withheld Return holds `noticeHold`
    /// unless it is also quick cleanup. A bare ✓ holds 0.7 s.
    static func doneHold(asHeard: Bool, notARewrite: Bool, notSent: Bool) -> Duration {
        if asHeard, !notARewrite { return quickCleanupHold }
        if notSent { return noticeHold }
        return .milliseconds(asHeard ? 1_400 : 700)
    }

    /// Maps one delivery to History status, pill and hold. A dictation that was pasted is a
    /// one-line state with no words in it; one that could not be pasted opens the not-pasted card,
    /// which shows the words (founder, 2026-10-10). The card is for evidence that the paste failed:
    /// no text field, focus moved, ⌘V not sent, or the field was read and the text is not there.
    /// A paste that was sent and merely could not be read back is the quiet "Pasted" row
    /// (`PillState.pastedUnchecked`). No state carries the dictated text — `text` is
    /// only counted here. The held row's Copy and the card get it through
    /// `PillModel.present(_:text:)`, outside the state.
    static func make(
        _ result: DeliveryResult, text: String, usedContext: Bool, asHeard: Bool, notARewrite: Bool = false, words counted: Int? = nil
    ) -> DeliveryPresentation {
        // Counting words is not free on a long dictation; callers that already have the count pass it.
        let words = counted ?? TextStats.wordCount(text)
        switch result {
        case .pasted, .returnSent, .unknownConfirmed:
            // A bare ✓ (design v3) holds 0.7 s. "Pasted · quick cleanup only" holds about 4 s.
            // A refused rewrite keeps the shorter "as heard" hold.
            return DeliveryPresentation(
                status: .inserted, feedback: .pill(.done(words: words, usedContext: usedContext, asHeard: asHeard, notARewrite: notARewrite)),
                hold: doneHold(asHeard: asHeard, notARewrite: notARewrite, notSent: false))
        case .pastedReturnSkipped, .unknownConfirmedReturnSkipped:
            // "Pasted · Return not pressed" is a sentence, not a ✓: it gets the hold of the other
            // one-line notices. Quick cleanup is the longer of the two.
            return DeliveryPresentation(
                status: .inserted,
                feedback: .pill(.done(words: words, usedContext: usedContext, asHeard: asHeard, notSent: true, notARewrite: notARewrite)),
                hold: doneHold(asHeard: asHeard, notARewrite: notARewrite, notSent: true))
        case .copied(let change):
            return copied(.targetChanged(change))
        case .noField(copied: let wasCopied) where !text.isEmpty:
            // The no-field card: the controller doesn't time it (a zero hold); the pill does.
            // Whether the clipboard was written is the policy's call (`NoFieldClipboardPolicy`).
            return DeliveryPresentation(
                status: .notInserted, feedback: .pill(.noField(wasCopied ? .copiedAutomatically : .offerCopy)),
                hold: .zero)
        case .unknownNotLanded:
            // The staged dictation is still on the clipboard; the card shows it and can copy it again.
            return DeliveryPresentation(
                status: .notInserted, feedback: .pill(.noField(.copiedAutomaticallyUnconfirmed)), hold: .zero)
        case .dispatchFailed(copied: true):
            return copied(.pasteFailed)
        case .heldForSecureField:
            // The pill times the row too (`PillState.heldDelay`), so the pointer can hold it.
            return DeliveryPresentation(status: .notInserted, feedback: .pill(.held(copied: false)), hold: .zero)
        case .unknownUnreadable:
            // ⌘V was sent, the field could not be read and nothing was seen going wrong. The
            // person most likely watched the text appear, so this is one quiet line, not a card.
            // The dictation stays on the clipboard and a click opens the card with the words.
            // The pill times the row (a zero hold), so the pointer can hold it.
            return DeliveryPresentation(status: .inserted, feedback: .pill(.pastedUnchecked), hold: .zero)
        case .unknownUnreadableReturnSkipped:
            // Focus moved before the Return that was asked for: something did change, so the card opens.
            return DeliveryPresentation(status: .inserted, feedback: .pill(.noField(.copiedAutomaticallyUnconfirmed)),
                                        hold: .zero)
        case .unknownCancelled:
            // ⌘V went out before the person cancelled, so History keeps it as inserted. The
            // controller shows nothing for a cancelled dictation; this is what any other caller gets.
            return DeliveryPresentation(status: .inserted, feedback: .notice("Cancelled · it's in History"),
                                        hold: noticeHold)
        case .returnWithheld(let change):
            let why = change.map { CopyReason.targetChanged($0).phrase } ?? "a password field has focus"
            return notice("Didn't press Return · \(why)")
        case .dispatchFailed(copied: false) where !text.isEmpty, .cancelled where !text.isEmpty:
            // The paste gave way before anything was dispatched and nothing was copied. The words
            // are not hidden behind a notice: the card shows them with a Copy. History keeps them.
            return DeliveryPresentation(status: .notInserted, feedback: .pill(.noField(.plainNotPasted)), hold: .zero)
        case .noField, .dispatchFailed(copied: false), .cancelled:
            // No words at all: a lone "press enter" that couldn't be sent.
            return notice("Couldn't press Return here")
        }
    }

    /// Focus moved or ⌘V could not be sent: the text is on the clipboard, and the pill opens to
    /// show it. Like the no-field card, the pill times it (a zero hold) and waits for the pointer.
    private static func copied(_ reason: CopyReason) -> DeliveryPresentation {
        DeliveryPresentation(status: .notInserted, feedback: .pill(.noField(.notPasted(reason))), hold: .zero)
    }

    private static func notice(_ message: String) -> DeliveryPresentation {
        DeliveryPresentation(status: .notInserted, feedback: .notice(message), hold: noticeHold)
    }
}
