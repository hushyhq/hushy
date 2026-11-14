import Foundation

/// The two always-on shortcuts that hand over the last dictation, while the app lock is on.
/// Neither works then, and nothing on a recovery row names one. The rule is the menu items'
/// own, `LockedCopy.canUseLastTranscript`; this only words the refusal. Pure
/// (`AppLockShortcutTests`).
enum LastTranscriptShortcut: Sendable {
    case paste
    case copy

    /// What the pill says in place of pasting or copying: one line, shown like any short notice.
    var lockedNotice: String {
        switch self {
        case .paste: "Unlock Hushy to paste your last dictation"
        case .copy: "Unlock Hushy to copy your last dictation"
        }
    }

    /// The line to show instead of doing it, or nil when the shortcut may go ahead. The check
    /// comes before the last dictation is read, so "is there one" is not asked while locked.
    func refusal(isLocked: Bool) -> String? {
        LockedCopy.canUseLastTranscript(hasTranscript: true, isLocked: isLocked) ? nil : lockedNotice
    }

    /// The refusal is shown only on a free pill. While dictating, the pill belongs to the
    /// recording. A row that still holds words that were not pasted, or a failure with its
    /// Try again, is worth more than the notice and stays.
    static func showsNotice(isDictating: Bool, pillHoldsRecoveryRow: Bool) -> Bool {
        !isDictating && !pillHoldsRecoveryRow
    }
}

extension NoFieldMode {
    /// The card's quiet line that names paste last, or nil while the app lock is on: the card's
    /// own Copy still works then, and the line would offer a shortcut that refuses.
    func recoveryLine(isLocked: Bool) -> String? {
        LockedCopy.canUseLastTranscript(hasTranscript: true, isLocked: isLocked) ? recoveryLine : nil
    }

    /// Whether the capsule names copy last beside its reason ("Not typed · ⌃⌘C copies"). Locked,
    /// it keeps the reason alone.
    func namesCopyLast(isLocked: Bool) -> Bool {
        capsuleLabel != nil && LockedCopy.canUseLastTranscript(hasTranscript: true, isLocked: isLocked)
    }
}
