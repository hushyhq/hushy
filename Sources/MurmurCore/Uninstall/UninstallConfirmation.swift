import Foundation

/// The confirmation in front of the uninstall. Return never confirms: it cancels, like Escape.
///
/// The Uninstall button works only when all of these hold: the plan on screen has been measured
/// (so it is the plan that will run, with its sizes shown), the acknowledgement is ticked, and,
/// if an export left notes unsaved, a second acknowledgement naming that number is ticked too.
public struct UninstallConfirmation: Sendable, Equatable {
    public enum Input: Sendable, CaseIterable {
        case toggleAcknowledgement, toggleUnsavedAcknowledgement, uninstallButton, cancelButton, defaultKey, escapeKey
    }

    public enum Decision: Sendable, Equatable {
        case stay, cancel, uninstall
    }

    public private(set) var isAcknowledged = false
    public private(set) var acknowledgesUnsavedNotes = false
    /// False from the moment the plan on screen changes until its sizes have been added up.
    public private(set) var isMeasured = false
    /// Notes the last export could not save.
    public private(set) var unsavedNotes = 0

    public init() {}

    public var needsUnsavedAcknowledgement: Bool { unsavedNotes > 0 }

    public var canUninstall: Bool {
        isMeasured && isAcknowledged && (!needsUnsavedAcknowledgement || acknowledgesUnsavedNotes)
    }

    /// A different plan is on screen and its sizes are not known yet.
    public mutating func planChanged() { isMeasured = false }

    /// The sizes of the plan on screen are known.
    public mutating func measured() { isMeasured = true }

    /// An export finished. A new count of unsaved notes has to be acknowledged afresh.
    public mutating func exportFinished(unsaved: Int) {
        unsavedNotes = max(0, unsaved)
        acknowledgesUnsavedNotes = false
    }

    public mutating func handle(_ input: Input) -> Decision {
        switch input {
        case .toggleAcknowledgement:
            isAcknowledged.toggle()
            return .stay
        case .toggleUnsavedAcknowledgement:
            if needsUnsavedAcknowledgement { acknowledgesUnsavedNotes.toggle() }
            return .stay
        case .uninstallButton: return canUninstall ? .uninstall : .stay
        case .cancelButton, .defaultKey, .escapeKey: return .cancel
        }
    }
}
