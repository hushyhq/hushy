import Foundation

/// The History sidebar badge: how many dictations since the user last looked at History still
/// hold words they can get back. A badge only earns its place when it asks the user to do
/// something (see `.claude/DECISIONS.md`, "Sidebar badges: only actionable counts"), so this is
/// deliberately narrower than `Dictation.needsAttention` (which drives the status dots and the
/// "Needs attention" filter and also covers deliberate cancels and dead-end failures).
public enum HistoryAttention {
    /// True when the dictation didn't land where the user was typing *and* there is still
    /// something to recover from it:
    /// - `.notInserted` with text — the words exist but were never pasted.
    /// - `.failed` with a cleaned or raw transcript, or saved audio that Retry can re-run.
    ///
    /// Not actionable: `.inserted` (landed fine), `.cancelled` (the user chose to throw it away;
    /// swept after 24 h anyway), `.failed` with no text and no audio (nothing left to recover),
    /// and a `.notInserted` Return-only dictation with no text.
    public static func isActionable(_ dictation: Dictation) -> Bool {
        switch dictation.status {
        case .inserted, .cancelled:
            return false
        case .notInserted:
            return !isBlank(dictation.text)
        case .failed:
            return !isBlank(dictation.text) || !isBlank(dictation.rawText) || dictation.audioPath != nil
        }
    }

    /// Actionable dictations created after `seenThrough` — i.e. ones the user hasn't had History
    /// open for yet. Opening History moves `seenThrough` to "now", which is what clears the badge;
    /// anything the user already looked at stays marked in the list (its status dot) but never
    /// re-inflates the number.
    public static func badgeCount(_ dictations: [Dictation], seenThrough: Date) -> Int {
        dictations.count { $0.createdAt > seenThrough && isActionable($0) }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
