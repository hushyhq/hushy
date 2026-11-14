import Foundation

/// What a dictation does to the clipboard when it ends with no editable text field.
///
/// This is the one switch for that rule. Change `current` and the delivery, the pill card
/// (Copy button or "Copied to clipboard") and the tests that pin the default all follow.
///
/// Founder rule (2026-10-10): a dictation pasted into a text box is never left on the clipboard;
/// one that is not pasted anywhere goes on the clipboard (and the pill shows it) so the person can
/// paste it themselves. This policy covers only the "no text box at key-down" half of "not pasted".
/// It never applies after a ⌘V was dispatched (the unknown-focus path), where the dictation may
/// well have landed.
public enum NoFieldClipboardPolicy: Sendable, Equatable {
    /// The clipboard is not touched. The text stays in History and in the pill's result card, and
    /// reaches the clipboard only when the user presses Copy, copy-last or paste-last.
    case leaveClipboardAlone
    /// The text is copied for ⌘V the moment the dictation ends (the behaviour before the result card).
    case copyAutomatically

    /// The behaviour the app ships with.
    public static let current: NoFieldClipboardPolicy = .copyAutomatically

    /// True when delivery should put the text on the clipboard itself.
    public var copiesAutomatically: Bool { self == .copyAutomatically }
}
