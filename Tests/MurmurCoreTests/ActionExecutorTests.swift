import Foundation
import Testing
@testable import MurmurCore

@Suite("ActionExecutor")
struct ActionExecutorTests {
    private func makeAction(kind: ProposedAction.Kind, title: String = "Dentist") -> ProposedAction {
        ProposedAction(kind: kind, title: title, start: Date(), end: Date().addingTimeInterval(1800), sourceText: "test")
    }

    @Test("creates a calendar event through the fake backend and returns an undo token")
    func createsEvent() async throws {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        let result = try await executor.execute(makeAction(kind: .createEvent))
        #expect(result.undoToken != nil)
        let created = await calendar.createdEvents
        #expect(created.count == 1)
        #expect(created.first?.action.title == "Dentist")
    }

    @Test("creates a reminder through the fake backend")
    func createsReminder() async throws {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        _ = try await executor.execute(makeAction(kind: .createReminder, title: "Call Dana"))
        let created = await calendar.createdReminders
        #expect(created.count == 1)
        #expect(created.first?.action.title == "Call Dana")
    }

    @Test("requests access lazily when not yet granted")
    func requestsAccessLazily() async throws {
        let calendar = FakeCalendarBackend(eventsAccessGranted: false)
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        _ = try await executor.execute(makeAction(kind: .createEvent))
        let granted = await calendar.eventsAccessGranted
        #expect(granted)
    }

    @Test("a granted request creates a reminder even when the next status read is stale")
    func grantedRequestWithStaleStatusCreatesReminder() async throws {
        let calendar = FakeCalendarBackend(remindersAccessGranted: false)
        await calendar.setRequestResult(true, for: .createReminder, updatesStatus: false)
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        _ = try await executor.execute(makeAction(kind: .createReminder, title: "Call Dana"))
        #expect(await calendar.createdReminders.count == 1)
        _ = try await executor.execute(makeAction(kind: .createReminder, title: "Second"))
        #expect(await calendar.createdReminders.count == 2)
    }

    @Test("a granted request creates an event even when the next status read is stale")
    func grantedRequestWithStaleStatusCreatesEvent() async throws {
        let calendar = FakeCalendarBackend(eventsAccessGranted: false)
        await calendar.setRequestResult(true, for: .createEvent, updatesStatus: false)
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        _ = try await executor.execute(makeAction(kind: .createEvent))
        #expect(await calendar.createdEvents.count == 1)
    }

    @Test("failure log reasons have fixed words and omit target names")
    func fixedFailureLogReasons() {
        #expect(ActionExecutionError.permissionDenied("Reminders").logStepAndReason == "access: permission denied")
        #expect(ActionExecutionError.targetNotFound(.list, "Private list").logStepAndReason == "target lookup: list not found")
        #expect(ActionExecutionError.saveFailed.logStepAndReason == "save: save failed")
        #expect(ActionExecutionError.backendFailed("private system detail").logStepAndReason == "backend: failed")
    }

    @Test("a refused request keeps Reminders access needed and creates nothing")
    func refusedReminderRequest() async {
        let calendar = FakeCalendarBackend(remindersAccessGranted: false)
        await calendar.setRequestResult(false, for: .createReminder)
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        await #expect(throws: ActionExecutionError.permissionDenied("Reminders")) {
            _ = try await executor.execute(makeAction(kind: .createReminder))
        }
        #expect(ActionWording.line(for: .permissionDenied("Reminders")) == "Reminders access needed")
        #expect(await calendar.createdReminders.isEmpty)
    }

    @Test("a granted request does not replace a missing named list with the default")
    func grantedRequestMissingNamedList() async {
        let calendar = FakeCalendarBackend(remindersAccessGranted: false)
        await calendar.setRequestResult(true, for: .createReminder, updatesStatus: false)
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        let action = ProposedAction(kind: .createReminder, title: "Call Dana", listName: "Absent", sourceText: "test")
        await #expect(throws: ActionExecutionError.targetNotFound(.list, "Absent")) {
            _ = try await executor.execute(action)
        }
        #expect(await calendar.createdReminders.isEmpty)
    }

    @Test("undo removes the previously created event")
    func undoRemovesEvent() async throws {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        let result = try await executor.execute(makeAction(kind: .createEvent))
        guard let token = result.undoToken else {
            Issue.record("expected an undo token")
            return
        }
        try await executor.undo(token, kind: .createEvent)
        let created = await calendar.createdEvents
        #expect(created.isEmpty)
    }

    @Test("runs a Shortcut that exists, matching case-insensitively")
    func runsShortcut() async throws {
        let shortcuts = FakeShortcutsBackend(installedShortcuts: ["Start Focus"])
        let executor = ActionExecutor(calendar: FakeCalendarBackend(), shortcuts: shortcuts)
        let action = ProposedAction(kind: .runShortcut, title: "start focus", shortcutName: "start focus", sourceText: "test")
        let result = try await executor.execute(action)
        #expect(result.undoToken == nil, "Shortcuts have no general undo")
        let runs = await shortcuts.runs
        #expect(runs.count == 1)
        #expect(runs.first?.name == "Start Focus")
    }

    @Test("throws notFound for a Shortcut that isn't installed")
    func shortcutNotFound() async throws {
        let shortcuts = FakeShortcutsBackend(installedShortcuts: ["Something Else"])
        let executor = ActionExecutor(calendar: FakeCalendarBackend(), shortcuts: shortcuts)
        let action = ProposedAction(kind: .runShortcut, title: "Ghost Shortcut", shortcutName: "Ghost Shortcut", sourceText: "test")
        await #expect(throws: ActionExecutionError.self) {
            _ = try await executor.execute(action)
        }
    }

    @Test("suggests close-matching Shortcut names when the exact name is missing")
    func suggestsShortcutNames() async throws {
        let shortcuts = FakeShortcutsBackend(installedShortcuts: ["Start My Focus Routine", "Stop Focus"])
        let executor = ActionExecutor(calendar: FakeCalendarBackend(), shortcuts: shortcuts)
        let suggestions = await executor.suggestedShortcutNames(for: "start focus routine")
        #expect(suggestions.first == "Start My Focus Routine")
    }

    @Test("propagates a permission-denied error from the backend")
    func propagatesPermissionError() async throws {
        let calendar = FakeCalendarBackend()
        await calendar.setNextError(.permissionDenied("Calendar"))
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        await #expect(throws: ActionExecutionError.self) {
            _ = try await executor.execute(makeAction(kind: .createEvent))
        }
    }
}

private extension FakeCalendarBackend {
    func setNextError(_ error: ActionExecutionError) {
        nextError = error
    }
}
