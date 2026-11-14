import Foundation

/// The one-step way forward a refused action can offer. A list or calendar that was named and is
/// not there is never swapped for the default on Hushy's own say (`ActionExecutor`); the person is
/// asked instead, and one tap saves the same item to their default list or calendar. Nothing else
/// that refuses an action has a way forward Hushy can take for the person: a Shortcut has no
/// default, and a missing time has to be said.
public enum ActionRecovery: Sendable, Equatable {
    /// What can be missing and still have a default to fall back on. A Shortcut is not here, so
    /// no offer can be made for one.
    public enum Place: Sendable, Equatable {
        case list, calendar
    }

    /// The named list or calendar was not found: save to the default one instead.
    case useDefault(Place, missing: String)

    public init?(for error: ActionExecutionError) {
        guard case .targetNotFound(let target, let name) = error else { return nil }
        switch target {
        case .list: self = .useDefault(.list, missing: name)
        case .calendar: self = .useDefault(.calendar, missing: name)
        case .shortcut: return nil
        }
    }

    /// The same action without the place that was not found. Everything else (title, time, length,
    /// location) stays as asked; the executor then uses the default and the result names it.
    public func applied(to action: ProposedAction) -> ProposedAction {
        var recovered = action
        switch self {
        case .useDefault(.list, _): recovered.listName = nil
        case .useDefault(.calendar, _): recovered.calendarName = nil
        }
        return recovered
    }

    /// The refusal this offer answers. A question nobody takes is counted as that failure, once,
    /// by its fixed category (`VoiceActionFailureCategory`); the name never leaves the Mac.
    public var refusal: ActionExecutionError {
        switch self {
        case .useDefault(.list, let name): .targetNotFound(.list, name)
        case .useDefault(.calendar, let name): .targetNotFound(.calendar, name)
        }
    }
}
