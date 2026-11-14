import AppKit
import Carbon.HIToolbox
import CoreGraphics
import MurmurCore

/// Which keys the pill answers right now. The pill's panel never becomes key (it must not take
/// focus from the app being dictated into), so ⏎/esc reach it through `HotkeyMonitor`'s existing
/// event tap — and only while a row that waits on the user is showing (DECISIONS 2026-09-28).
enum PillKeyScope: Equatable {
    /// Nothing is asked: the tap takes no key for the pill.
    case none
    /// Confirm rows with something pending, the question about a list that isn't there (in its
    /// key window), or the upgrade row: ⏎ confirms (all) / takes the offer / opens the plans,
    /// esc dismisses.
    case confirm
    /// A row with nothing to confirm (the password-field row, a done chip, a finished answer, a
    /// confirm card whose ⏎ window closed): esc dismisses it; ⏎ still reaches the app.
    case dismiss
    /// An action utterance is being heard (the chord, the pill's Action button, or a follow-up
    /// on the answer card): ⏎ finishes it, like hands-free dictation; esc discards it.
    case finish
    /// Work is under way ("Working…"): esc cancels it, with any modifier (the chord may still be
    /// down); ⏎ is never taken, so a second Return after sending reaches the app.
    case cancelOnly
    /// The restyle chips are showing over a selection: 1 to 4 pick a way of writing, C toggles Copy, esc closes. These
    /// keys are taken because they would otherwise replace the selected text in the app.
    case restyle
}

/// An answer the pill takes from the keyboard.
enum PillKey: Equatable {
    case confirm
    case dismiss
    case restylePick(RestyleStyle)
    case restyleToggleCopy
}

/// Pure: which pill answer (if any) a key-down is, given the scope. Only plain ⏎ / keypad Enter /
/// esc; any modifier passes through, and ⌘C is never taken — held text reaches the clipboard only
/// through the row's Copy button. The one exception is `.finish`: the chord (fn+⌃) is usually
/// still held when the user presses ⏎ to end an action, so modifiers are ignored there, exactly
/// as `HotkeyMonitor.finishesLatched` ignores them for hands-free dictation.
enum PillKeyRouter {
    static func key(keyCode: Int, flags: CGEventFlags, scope: PillKeyScope) -> PillKey? {
        guard scope != .none else { return nil }
        if scope == .restyle { return restyleKey(keyCode: keyCode, flags: flags) }
        let isEnter = keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter
        if scope == .cancelOnly { return keyCode == kVK_Escape ? .dismiss : nil }
        if scope == .finish {
            if isEnter { return .confirm }
            return keyCode == kVK_Escape ? .dismiss : nil
        }
        guard flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty else { return nil }
        if isEnter { return scope == .confirm ? .confirm : nil }
        return keyCode == kVK_Escape ? .dismiss : nil
    }

    private static let numberKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]

    private static func restyleKey(keyCode: Int, flags: CGEventFlags) -> PillKey? {
        guard flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty else { return nil }
        if keyCode == kVK_Escape { return .dismiss }
        if keyCode == kVK_ANSI_C { return .restyleToggleCopy }
        guard let index = numberKeys.firstIndex(of: keyCode) else { return nil }
        return .restylePick(RestyleStyle.allCases[index])
    }
}

extension PillState {
    /// The keys this state answers (`PillKeyScope`). A state that waits on the user for a moment
    /// can be finished from the keyboard: ⏎ where confirming is safe, esc always.
    ///
    /// A key the pill answers is taken by the event tap and never reaches the app in front
    /// (`HotkeyMonitor`). So a row that can sit for a long time answers none: a dictation failure
    /// (`.failed`) has no timer, and the not-pasted card (`.noField`) stays while it is read.
    /// Both close with ✕, their own button or the next dictation, and esc keeps going to the app
    /// being typed in. They are in `default` on purpose. The question about a list or calendar
    /// that isn't there waits as long, so its scope here holds only while the card's first key
    /// window is open; after that `PillModel.keyScope(now:ownTextFieldFocused:)` gives it none.
    var keyScope: PillKeyScope {
        switch self {
        // Rows pending: ⏎ confirms them. Nothing pending (a failed action waiting on Retry, a card
        // being executed): esc still closes it. That voice-action failure toast clears itself
        // after `PillState.failureToastDelay`, so it takes esc only for those seconds.
        // A row that asks whether to use the default list is a question too: ⏎ is its tick and
        // esc its ✕, for the first key window only. It has no timer (a timeout would lose the
        // item), so after that window it is answered by click and takes no key at all.
        case .actionConfirm(let card):
            card.rows.contains { $0.status == .pending } || card.soleOfferRow != nil ? .confirm : .dismiss
        case .actionListening: .finish
        // "Working…": esc cancels before anything is created. ⏎ is not taken: it already sent the
        // action, and a second one belongs to the app.
        case .actionProcessing: .cancelOnly
        case .held(copied: false): .dismiss
        // The done chip: esc clears it early; ⏎ never undoes.
        case .actionDone: .dismiss
        // A voice edit with Undo still offered: esc puts the selection back (its ✕). ⏎ stays the app's.
        case .voiceEdit(let chip): chip.canUndo ? .dismiss : .none
        case .restyle: .restyle
        // The answer card: esc closes it (⏎ still reaches the app; the card has no default
        // action). While a follow-up is being heard, ⏎ finishes it and esc discards it.
        case .answer(let card): card.isListening ? .finish : .dismiss
        default: .none
        }
    }
}

extension PillModel {
    static let cardKeyWindow: Duration = .seconds(8)

    /// The keys the event tap takes right now: the state's scope, with ⏎ for a confirm card only
    /// inside its key window (esc keeps dismissing it after), and never ⏎ while a text field in
    /// Hushy's own windows has focus (esc still dismisses there). An action being heard is the
    /// exception: ⏎ finishes it wherever focus is, as it does for hands-free dictation.
    ///
    /// A card that waits on a question (`waitsOnOffer`: a list or calendar that isn't there) is
    /// stricter. It stays until it is answered, so once its first key window closes it takes
    /// neither ⏎ nor esc: both reach the app in front, however long the row sits, and hovering
    /// does not open the window again (`renewCardKeys`). ✓ and ✕ still answer it by click.
    func keyScope(now: Date, ownTextFieldFocused: Bool) -> PillKeyScope {
        let scope = state.keyScope
        if case .actionConfirm(let card) = state, !cardKeysLive(now: now) {
            if card.waitsOnOffer { return .none }
            return scope == .confirm ? .dismiss : scope
        }
        guard scope == .confirm else { return scope }
        return ownTextFieldFocused ? .dismiss : .confirm
    }

    /// A key the event tap took for the pill (see `PillKeyScope`).
    func answer(_ key: PillKey) {
        switch (key, state) {
        case (.confirm, .actionConfirm): onActionConfirmAll?()
        case (.dismiss, .actionConfirm): onActionCancelAll?()
        case (.confirm, .actionListening): onActionStopListening?()
        case (.dismiss, .actionListening): onActionDiscardListening?()
        case (.confirm, .actionProcessing): break
        case (.dismiss, .actionProcessing): onActionCancelProcessing?()
        case (.confirm, .answer(let card)) where card.isListening: onActionStopListening?()
        case (.dismiss, .answer(let card)): card.isListening ? onActionDiscardListening?() : onAnswerClose?()
        case (.dismiss, .actionDone): state = .idle
        case (.dismiss, .held(copied: false)): onDismiss?()
        case (.dismiss, .voiceEdit(let chip)) where chip.canUndo: onVoiceEditUndo?()
        case (.dismiss, .restyle): onRestyleCancel?()
        case (.restylePick(let style), .restyle): onRestylePick?(style)
        case (.restyleToggleCopy, .restyle): onRestyleToggleCopy?()
        default: break
        }
    }
}

/// Whether a text input in Hushy's own windows has keyboard focus (the Assistant's chat box,
/// search, a settings field): ⏎ there always belongs to that field, never to the pill.
@MainActor
enum OwnTextFocus {
    static func isTextFieldFocused() -> Bool {
        NSApp.isActive && isTextInput(NSApp.keyWindow?.firstResponder)
    }

    /// An editable text field or text view (SwiftUI text fields focus the window's field editor).
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSTextView { return view.isEditable }
        if let field = responder as? NSTextField { return field.isEditable }
        return false
    }
}
