import Foundation
import MurmurCore

/// Why a finished dictation was copied for ⌘V instead of pasted: the pill's one-line reason
/// (docs/product/UI-ROUND-2026-09-28.md §1). Wraps core's `TargetChange` with the outcome
/// that isn't a moved target. (No text field at all is its own card: `PillState.noField`.)
enum CopyReason: Equatable, Sendable {
    /// Focus moved off the key-down field before the paste (DECISIONS 2026-09-27).
    case targetChanged(TargetChange)
    /// ⌘V couldn't be sent (or the clipboard couldn't be staged).
    case pasteFailed

    /// Why nothing was pasted, in the user's terms ("Copied · switched apps").
    var phrase: String {
        switch self {
        case .targetChanged(.app): "switched apps"
        case .targetChanged(.window): "switched windows"
        case .targetChanged(.field): "moved to another field"
        case .targetChanged(.fieldClosed): "field closed"
        case .pasteFailed: "couldn't paste here"
        }
    }

    /// The row's VoiceOver text. Never the dictated words.
    var accessibilityText: String {
        let why = switch self {
        case .targetChanged: phrase
        case .pasteFailed: "Hushy couldn't paste here"
        }
        return "Not pasted: \(why). Copied to the clipboard; press Command V to paste."
    }

    /// The row's hover help.
    var help: String {
        let why = switch self {
        case .targetChanged: "Focus moved before Hushy could paste, so nothing was typed."
        case .pasteFailed: "Hushy couldn't paste into this app, so nothing was typed."
        }
        return why + " Your text is on the clipboard and in History."
    }
}

extension PillState {
    /// Rows with a control take clicks; everything else lets clicks through to the app below
    /// (a `.copied` row has no control: ⌘V belongs to the host app).
    var isInteractive: Bool {
        switch self {
        case .idle, .handsFree, .recordingNote, .actionListening, .actionProcessing, .actionConfirm, .answer, .noField, .failed, .pastedUnchecked: true
        case .nameOffer(let phase, _, _): phase != .added
        case .held(let copied): !copied
        case .actionDone(let chip): chip.canUndo
        case .voiceEdit(let chip): chip.canUndo
        case .restyle: true
        default: false
        }
    }

    /// Rows the pill clears by itself because no controller owns their timing: the held row
    /// (6 s, and not while the pointer is on it), its "Copied" after the Copy
    /// tap (1.4 s), the done chip (the undo window while it has an Undo, else 6 s; "Undone" 1.4 s)
    /// and the answer card's "Copied" (1.4 s).
    var selfDismissDelay: Duration? {
        switch self {
        case .held(copied: false): Self.heldDelay
        case .held(copied: true): .milliseconds(1_400)
        case .actionDone(let chip):
            // "Undoing…" outlasts a slow delete, so the result is still on screen when it lands.
            chip.undone ? .milliseconds(1_400) : (chip.isUndoing ? .seconds(15) : (chip.canUndo ? ActionUndoWindow.duration : .seconds(6)))
        case .answer(let card): card.copied ? .milliseconds(1_400) : nil
        case .voiceEdit(let chip): chip.dismissDelay
        // The no-field card: the controller doesn't time it (its hold is zero), so it lasts at
        // least as long as its mode says (longer for a long dictation, `PillModel.selfDismissDelay`),
        // and not while the pointer is over it (`selfDismissDecision`).
        case .noField(let mode): mode.dismissDelay
        // The quiet "Pasted" row: as long as the other one-line notices, and not while the pointer
        // is on it (`selfDismissDecision`).
        case .pastedUnchecked: DeliveryPresentation.noticeHold
        // The offer beside Done: long enough to reach, and not while the pointer is on the pill
        // or the spelling is being typed (`selfDismissDecision`).
        case .nameOffer(.offered, _, _): Self.nameOfferDelay
        case .nameOffer(.editing, _, _): Self.nameEditingDelay
        case .nameOffer(.added, _, _): Self.nameAddedDelay
        // A card with nothing left to confirm — every row failed or was dismissed — is a
        // failure toast: readable for a while, then gone on its own (✕ and esc close it sooner).
        case .actionConfirm(let card): card.isFailureToast ? Self.failureToastDelay : nil
        default: nil
        }
    }

    static let failureToastDelay: Duration = .seconds(10)
}

extension PillModel {
    /// The microphone would not start although access is allowed (no input device, or the chosen
    /// one is gone or busy). Says where to look: the Microphone row in Settings → General. One
    /// line, because the error row never wraps. Clicking the pill does nothing in an error state
    /// (`PillState.isInteractive`), so the words carry the whole fix.
    static let microphoneFailedMessage = "Mic didn't start. Check Settings → General"

    /// "142 words": the count shows only for long results, where it tells you the whole thing
    /// landed. Shorter results are just the ✓.
    static func pastedCount(words: Int) -> String? {
        words >= 20 ? "\(words) words" : nil
    }

    /// Beside Done's ✓ when the text was pasted but the Return the person asked for was withheld
    /// (focus moved first). It used to read "not sent", which looked like the paste had failed.
    static let returnNotPressed = "Return not pressed"

    /// Beside the ✓ when the model was wanted and did not answer in time. A refused rewrite
    /// keeps "as heard" (`notARewrite`), with its own explanation.
    static let quickCleanupLine = "Pasted · quick cleanup only"

    /// The words beside Done's ✓, in order: the count (from 20 words), then "quick cleanup only"
    /// or "as heard", and "Return not pressed" when they apply. Empty for a plain short paste;
    /// the ✓ says it. A withheld Return drops the count: "Pasted" already says the text landed,
    /// and the row has to stay one short line.
    static func doneParts(words: Int, asHeard: Bool, notSent: Bool, notARewrite: Bool = false) -> [String] {
        let qualifier: String? = if asHeard { notARewrite ? "as heard" : "quick cleanup only" } else { nil }
        return [notSent ? nil : pastedCount(words: words), qualifier, notSent ? returnNotPressed : nil]
            .compactMap { $0 }
    }

    /// The line the pill draws beside the ✓, or nil when the ✓ alone says it. A withheld Return
    /// leads with "Pasted" so nobody reads the qualifier as "nothing happened":
    /// "Pasted · Return not pressed". Quick cleanup leads with that same "Pasted", because the
    /// qualifier on its own read as a failure. VoiceOver reads the same words (`accessibilityLabel`).
    static func doneLine(words: Int, asHeard: Bool, notSent: Bool, notARewrite: Bool = false) -> String? {
        if asHeard, !notARewrite {
            let parts = ["Pasted", "quick cleanup only"] + (notSent ? [returnNotPressed] : [])
            return parts.joined(separator: " · ")
        }
        let parts = (notSent ? ["Pasted"] : []) + doneParts(words: words, asHeard: asHeard, notSent: notSent, notARewrite: notARewrite)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Hover text for Done's qualifiers (empty when there are none, which shows no tooltip).
    static func doneExplanation(asHeard: Bool, notSent: Bool, notARewrite: Bool = false) -> String {
        var sentences: [String] = []
        if asHeard { sentences.append(notARewrite
            ? "A check protecting the meaning of what you said rejected the model’s rewrite."
            : "The on-device model didn't answer in time, so your words were pasted with quick cleanup only.") }
        if notSent { sentences.append("Your text was pasted. Focus moved before Hushy could press Return, so press Return yourself.") }
        return sentences.joined(separator: " ")
    }

    /// Done's VoiceOver line: the visible done line (or "Pasted" and its parts), then the screen-context note.
    private static func doneAccessibility(words: Int, usedContext: Bool, asHeard: Bool, notSent: Bool,
                                          notARewrite: Bool) -> String {
        let spoken = if asHeard, !notARewrite {
            (doneLine(words: words, asHeard: asHeard, notSent: notSent, notARewrite: notARewrite) ?? "Pasted")
                .replacingOccurrences(of: " · ", with: ", ")
        } else {
            (["Pasted"] + doneParts(words: words, asHeard: asHeard, notSent: notSent, notARewrite: notARewrite))
                .joined(separator: ", ")
        }
        return spoken + (usedContext ? ", using context from the screen" : "")
    }

    /// What VoiceOver reads for the pill. Never the dictated words — a held row in particular
    /// names the password field and the Copy button, nothing else.
    var accessibilityLabel: String {
        switch state {
        case .idle: "Hushy. Click to dictate, or hold \(triggerGlyph)."
        case .listening, .handsFree: "Listening"
        case .recordingNote: isCapturingCallAudio ? "Recording note with call audio" : "Recording note"
        // The internal stage (hearing, polishing, typing) is never named, and neither are the
        // words in the ink preview. From 5 s "Still writing…" is what is on screen.
        case .processing:
            if let started = processingStartedAt,
               WritingPhase.phase(after: Date().timeIntervalSince(started)) == .stillWriting {
                WritingPhase.stillWritingMessage
            } else {
                "Writing"
            }
        case .done(let words, let usedContext, let asHeard, let notSent, let notARewrite):
            Self.doneAccessibility(words: words, usedContext: usedContext, asHeard: asHeard, notSent: notSent,
                                   notARewrite: notARewrite)
        case .copied(let reason): reason.accessibilityText
        case .held(copied: false): "Not pasted: a password field has focus. Press Copy to copy the text, or History to read it."
        case .held(copied: true): "Copied."
        case .error(let message): "Error: \(message)"
        case .failed(let failure): failure.accessibilityText
        case .actionListening: "Listening for an action"
        case .actionProcessing: "Working on the action. Press Escape to cancel."
        case .actionConfirm(let card):
            ActionConfirmationCard.accessibilityText(count: card.rows.count, isChoice: card.isChoice)
        case .answer(let card): card.accessibilityText
        case .noField(let mode): mode.accessibilityText
        case .pastedUnchecked: PastedUncheckedRow.accessibilityText
        case .nameOffer(let phase, _, _): NameOfferWording.accessibility(phase, offer: nameOffer)
        case .actionDone(let chip): chip.accessibilityText
        case .voiceEdit(let chip): chip.accessibilityText
        case .restyle: RestyleCopy.chooserAccessibility
        }
    }
}
