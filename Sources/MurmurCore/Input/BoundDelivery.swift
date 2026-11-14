import Foundation

/// Orders focus-sensitive paste and delayed Return dispatch. The app supplies live focus,
/// cancellation, clipboard ownership, and keyboard-event adapters; tests can exercise the
/// same sequencing without sending system-wide keyboard events.
@MainActor
public enum BoundDelivery {
    public enum Outcome: Sendable, Equatable {
        case pasted
        case pastedReturnSkipped
        case focusChanged
        case dispatchFailed
    }

    public static func perform(
        pressReturn: Bool,
        isCurrent: () -> Bool,
        hasFocus: () -> Bool,
        prepareClipboard: () -> Bool,
        clipboardIsOwned: () -> Bool,
        paste: () -> Bool,
        waitBeforeReturn: () async -> Void,
        sendReturn: () -> Bool
    ) async -> Outcome {
        guard !Task.isCancelled, isCurrent(), hasFocus() else { return .focusChanged }
        guard prepareClipboard() else { return .dispatchFailed }
        guard !Task.isCancelled, isCurrent(), clipboardIsOwned(), hasFocus() else { return .focusChanged }
        guard paste() else { return .dispatchFailed }
        guard pressReturn else { return .pasted }

        await waitBeforeReturn()
        guard !Task.isCancelled, isCurrent(), clipboardIsOwned(), hasFocus() else {
            return .pastedReturnSkipped
        }
        return sendReturn() ? .pasted : .pastedReturnSkipped
    }

    /// For a command-only result (e.g. the user said only "press enter"): no text to paste,
    /// so the clipboard is never touched, but Return still only reaches the bound target and
    /// is re-checked after the pre-Return wait, same as a normal insertion.
    public static func performReturnOnly(
        isCurrent: () -> Bool,
        hasFocus: () -> Bool,
        waitBeforeReturn: () async -> Void,
        sendReturn: () -> Bool
    ) async -> Outcome {
        guard !Task.isCancelled, isCurrent(), hasFocus() else { return .focusChanged }
        await waitBeforeReturn()
        guard !Task.isCancelled, isCurrent(), hasFocus() else { return .focusChanged }
        return sendReturn() ? .pasted : .dispatchFailed
    }
}

/// Tracks which pre-paste clipboard snapshot belongs to Murmur's current temporary paste.
/// A user copy changes the pasteboard count, so the next insertion snapshots that new content.
@MainActor
public struct ClipboardSnapshotLedger<Snapshot> {
    private struct Entry {
        let snapshot: Snapshot
        let changeCount: Int
    }

    private var entry: Entry?

    public init() {}

    /// The clipboard to restore for the next paste: the saved one while the pasteboard is still
    /// the staged paste (same change count, or `isStillOurs` when something merely re-wrote our
    /// own item), otherwise a fresh capture of whatever the user has copied since.
    public mutating func original(
        currentChangeCount: Int, isStillOurs: () -> Bool = { false }, capture: () -> Snapshot
    ) -> Snapshot {
        if let entry, entry.changeCount == currentChangeCount || isStillOurs() { return entry.snapshot }
        return capture()
    }

    public mutating func record(_ snapshot: Snapshot, at changeCount: Int) {
        entry = Entry(snapshot: snapshot, changeCount: changeCount)
    }

    public mutating func clear(ifChangeCount changeCount: Int? = nil) {
        guard changeCount == nil || entry?.changeCount == changeCount else { return }
        entry = nil
    }
}
