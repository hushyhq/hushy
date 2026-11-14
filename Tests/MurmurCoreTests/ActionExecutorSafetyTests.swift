import Foundation
import Testing
@testable import MurmurCore

/// Fix 1 and fix 4 at the executor: nothing is guessed at execution, and a Shortcut that may have
/// run is never reported as a plain failure. Fake backends only: no real calendar, reminders or
/// Shortcut is touched.
@Suite("ActionExecutor: no guessed targets, honest Shortcut outcomes")
struct ActionExecutorSafetyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        title: String = "Dentist", start: Date?, calendar: String? = nil
    ) -> ProposedAction {
        ProposedAction(
            kind: .createEvent, title: title, start: start, end: start?.addingTimeInterval(1800),
            calendarName: calendar, sourceText: "test")
    }

    private func reminder(list: String? = nil, start: Date? = nil) -> ProposedAction {
        ProposedAction(kind: .createReminder, title: "Call Dana", start: start, listName: list, sourceText: "test")
    }

    // MARK: Event start

    @Test("an event with no start is refused and nothing is created, not even \"now\"")
    func eventWithoutStartRefused() async {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        await #expect(throws: ActionExecutionError.missingStart) {
            _ = try await executor.execute(event(start: nil))
        }
        #expect(await calendar.createdEvents.isEmpty)
    }

    @Test("the refusal comes before any permission prompt")
    func refusalBeforeAccessPrompt() async {
        let calendar = FakeCalendarBackend(eventsAccessGranted: false)
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        _ = try? await executor.execute(event(start: nil))
        #expect(await calendar.eventsAccessGranted == false, "no system prompt for an action that can't run")
    }

    @Test("a reminder with no due date is fine: it has no start to guess")
    func undatedReminderIsFine() async throws {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        _ = try await executor.execute(reminder())
        #expect(await calendar.createdReminders.count == 1)
    }

    // MARK: Named calendar and list

    @Test("a calendar the person named that does not exist is refused, not replaced by the default")
    func namedCalendarMissing() async {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        await #expect(throws: ActionExecutionError.targetNotFound(.calendar, "Holidays")) {
            _ = try await executor.execute(event(start: start, calendar: "Holidays"))
        }
        #expect(await calendar.createdEvents.isEmpty)
    }

    @Test("a Reminders list the person named that does not exist is refused")
    func namedListMissing() async {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        await #expect(throws: ActionExecutionError.targetNotFound(.list, "Errands")) {
            _ = try await executor.execute(reminder(list: "Errands"))
        }
        #expect(await calendar.createdReminders.isEmpty)
    }

    @Test("a named calendar that exists is used, matched without regard to case")
    func namedCalendarFound() async throws {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        let result = try await executor.execute(event(start: start, calendar: "work"))
        #expect(result.placedIn == "work")
        #expect(await calendar.createdEvents.count == 1)
    }

    @Test("no calendar named: the default is used, and the result names it")
    func unnamedCalendarUsesDefault() async throws {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        let result = try await executor.execute(event(start: start))
        #expect(result.placedIn == "Home")
    }

    @Test("no list named: the default list is used, and the result names it")
    func unnamedListUsesDefault() async throws {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        let result = try await executor.execute(reminder())
        #expect(result.placedIn == "Reminders")
    }

    @Test("a blank name counts as not named")
    func blankNameIsNotNamed() async throws {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        _ = try await executor.execute(event(start: start, calendar: "   "))
        #expect(await calendar.createdEvents.count == 1)
    }

    @Test("a confirmed card row cannot bypass the checks: the same action fails the same way on every run")
    func revalidatedEveryTime() async {
        let calendar = FakeCalendarBackend()
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        let action = event(start: start, calendar: "Holidays")
        for _ in 0..<2 {
            await #expect(throws: ActionExecutionError.targetNotFound(.calendar, "Holidays")) {
                _ = try await executor.execute(action)
            }
        }
        #expect(await calendar.createdEvents.isEmpty)
    }

    @Test("access is requested before the named calendar is looked up")
    func accessThenLookup() async throws {
        let calendar = FakeCalendarBackend(eventsAccessGranted: false)
        let executor = ActionExecutor(calendar: calendar, shortcuts: FakeShortcutsBackend())
        _ = try await executor.execute(event(start: start, calendar: "Work"))
        #expect(await calendar.eventsAccessGranted)
    }

    // MARK: Shortcuts

    @Test("a Shortcut that isn't installed is reported as a missing shortcut, not a missing app")
    func missingShortcutNamed() async {
        let executor = ActionExecutor(calendar: FakeCalendarBackend(), shortcuts: FakeShortcutsBackend(installedShortcuts: ["Other"]))
        let action = ProposedAction(kind: .runShortcut, title: "Ghost", shortcutName: "Ghost", sourceText: "x")
        await #expect(throws: ActionExecutionError.targetNotFound(.shortcut, "Ghost")) {
            _ = try await executor.execute(action)
        }
    }

    @Test("a Shortcut that may have run comes back as uncertain, and only one run was attempted")
    func shortcutMayHaveRun() async {
        let shortcuts = FakeShortcutsBackend(installedShortcuts: ["Send Standup"])
        await shortcuts.setNextError(.mayHaveRun(.timedOut))
        let executor = ActionExecutor(calendar: FakeCalendarBackend(), shortcuts: shortcuts)
        let action = ProposedAction(kind: .runShortcut, title: "Send Standup", shortcutName: "Send Standup", sourceText: "x")
        await #expect(throws: ActionExecutionError.mayHaveRun(.timedOut)) {
            _ = try await executor.execute(action)
        }
        #expect(ActionExecutionError.mayHaveRun(.timedOut).failureKind == .uncertain)
        #expect(await shortcuts.attempts == 1, "the executor never retries a Shortcut on its own")
    }

    @Test("a successful Shortcut offers no undo token")
    func shortcutHasNoUndo() async throws {
        let executor = ActionExecutor(calendar: FakeCalendarBackend(), shortcuts: FakeShortcutsBackend(installedShortcuts: ["Start Focus"]))
        let action = ProposedAction(kind: .runShortcut, title: "Start Focus", shortcutName: "Start Focus", sourceText: "x")
        let result = try await executor.execute(action)
        #expect(result.undoToken == nil)
        #expect(result.placedIn == nil)
    }

    // MARK: Links

    @Test("a named browser that couldn't take the link is reported, so the chip can say the default opened it")
    func browserFallbackNamed() async throws {
        let links = FakeLinkBackend()
        await links.setFallsBack(true)
        let executor = ActionExecutor(calendar: FakeCalendarBackend(), shortcuts: FakeShortcutsBackend(), links: links)
        let action = ProposedAction(kind: .openLink, title: "Open Gmail", location: "safari", url: "https://mail.google.com/", sourceText: "x")
        let result = try await executor.execute(action)
        #expect(result.placedIn == "your default browser")
        let plain = ProposedAction(kind: .openLink, title: "Open Gmail", url: "https://mail.google.com/", sourceText: "x")
        #expect(try await executor.execute(plain).placedIn == nil)
    }
}
