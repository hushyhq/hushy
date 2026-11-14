import Foundation

/// The checks an action must pass immediately before it can touch anything. Pure, so the same
/// rule is applied where the card is built (to show the problem before the person taps) and
/// again inside `ActionExecutor`, so a confirmed row can never bypass it.
///
/// What it refuses is a guess made at execution time: an event with no start would otherwise be
/// created "now". Time defaults that are documented (30 minutes, 9 a.m. for a named day) are made
/// when the date is parsed, are visible on the card, and are not touched here.
public enum ActionPreflight {
    /// Why this action cannot run as proposed, from the action alone. Nil when nothing is missing.
    public static func problem(in action: ProposedAction) -> ActionExecutionError? {
        switch action.kind {
        case .createEvent: action.start == nil ? .missingStart : nil
        case .createReminder, .runShortcut, .openLink: nil
        }
    }

    /// The name the person said for a calendar or list, or nil when none was said (the default
    /// is then fine). Blank names count as not named.
    public static func namedTarget(of action: ProposedAction) -> (target: ActionExecutionError.Target, name: String)? {
        let raw: String?
        let target: ActionExecutionError.Target
        switch action.kind {
        case .createEvent: (raw, target) = (action.calendarName, .calendar)
        case .createReminder: (raw, target) = (action.listName, .list)
        case .runShortcut, .openLink: return nil
        }
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return (target, name)
    }

    /// Whether `name` is one of `available`, ignoring case: the same match the backend uses to
    /// pick the calendar, so a name that passes here resolves there.
    public static func resolves(_ name: String, among available: [String]) -> Bool {
        available.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
