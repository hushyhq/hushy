import EventKit
import MurmurCore
import os

/// Real Calendar/Reminders backend via `EventKit`. Requests full access on first use
/// (`requestFullAccessToEvents`/`requestFullAccessToReminders`, macOS 14+) with the system TCC
/// prompt, per docs/research/voice-actions.md §3. Never used directly by tests — see
/// `FakeCalendarBackend` in MurmurCore for the protocol-backed fake tests exercise instead.
actor EventKitActionBackend: CalendarActionBackend {
    private let store = EKEventStore()
    private let log = Logger(subsystem: "app.hushy", category: "voice-actions")

    func hasAccess(for kind: ProposedAction.Kind) async -> Bool {
        let type: EKEntityType = kind == .createReminder ? .reminder : .event
        let status = EKEventStore.authorizationStatus(for: type)
        let granted: Bool
        switch status {
        case .authorized, .fullAccess: granted = true
        case .notDetermined, .restricted, .denied, .writeOnly: granted = false
        @unknown default: granted = false
        }
        if !granted {
            log.info("action access check: status \(Self.statusName(status), privacy: .public)")
        }
        return granted
    }

    func requestAccess(for kind: ProposedAction.Kind) async -> Bool {
        do {
            let granted = if kind == .createReminder {
                try await store.requestFullAccessToReminders()
            } else {
                try await store.requestFullAccessToEvents()
            }
            if granted {
                // This store may have been instantiated before TCC granted access.
                store.reset()
            } else {
                log.error("action access request: refused")
            }
            return granted
        } catch {
            log.error("action access request: threw")
            return false
        }
    }

    private static func statusName(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .fullAccess: "fullAccess"
        case .writeOnly: "writeOnly"
        @unknown default: "unknown"
        }
    }

    func writableTargetNames(for kind: ProposedAction.Kind) async -> [String] {
        let type: EKEntityType = kind == .createReminder ? .reminder : .event
        return store.calendars(for: type).filter(\.allowsContentModifications).map(\.title)
    }

    func createEvent(_ action: ProposedAction) async throws -> ActionExecutionResult {
        // Never "now": the executor refuses an event with no start first; this is the backstop.
        guard let start = action.start else { throw ActionExecutionError.missingStart }
        let target = try destination(named: action.calendarName, as: .calendar, entityType: .event)
        let event = EKEvent(eventStore: store)
        event.title = action.title
        event.startDate = start
        event.endDate = action.end ?? start.addingTimeInterval(DateAnchor.defaultDurationSeconds)
        event.location = action.location
        event.notes = action.notes
        event.calendar = target
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw ActionExecutionError.saveFailed
        }
        return ActionExecutionResult(undoToken: ActionUndoToken(backendID: event.eventIdentifier), placedIn: target.title)
    }

    func createReminder(_ action: ProposedAction) async throws -> ActionExecutionResult {
        let target = try destination(named: action.listName, as: .list, entityType: .reminder)
        let reminder = EKReminder(eventStore: store)
        reminder.title = action.title
        reminder.notes = action.notes
        if let due = action.start {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        reminder.calendar = target
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ActionExecutionError.saveFailed
        }
        return ActionExecutionResult(undoToken: ActionUndoToken(backendID: reminder.calendarItemIdentifier), placedIn: target.title)
    }

    func undo(_ token: ActionUndoToken, kind: ProposedAction.Kind) async throws {
        if kind == .createReminder {
            guard let reminder = store.calendarItem(withIdentifier: token.backendID) as? EKReminder else {
                throw ActionExecutionError.notFound(token.backendID)
            }
            try store.remove(reminder, commit: true)
        } else {
            guard let event = store.event(withIdentifier: token.backendID) else {
                throw ActionExecutionError.notFound(token.backendID)
            }
            try store.remove(event, span: .thisEvent)
        }
    }

    /// The calendar or list to save into. A name the person said must exist: it is never swapped
    /// for the default. With no name said, the default is used, and the result names it.
    private func destination(
        named name: String?, as target: ActionExecutionError.Target, entityType: EKEntityType
    ) throws -> EKCalendar {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            guard let found = store.calendars(for: entityType).first(where: {
                $0.allowsContentModifications && $0.title.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw ActionExecutionError.targetNotFound(target, name) }
            return found
        }
        let fallback = entityType == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let fallback else { throw ActionExecutionError.backendFailed("No calendar to save to") }
        return fallback
    }
}
