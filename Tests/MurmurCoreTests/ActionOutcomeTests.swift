import Foundation
import Testing
@testable import MurmurCore

/// Fix 2: failed and uncertain outcomes are durable, plain, and never offered a blind retry.
@Suite("Action outcomes: failed, uncertain, undo failure")
struct ActionOutcomeTests {
    // MARK: Which outcome

    @Test("a Shortcut process that never started is a plain failure; anything after it started is uncertain")
    func shortcutOutcome() {
        #expect(ShortcutRunOutcome.error(started: true, timedOut: false, exitStatus: 0) == nil)
        #expect(ShortcutRunOutcome.error(started: true, timedOut: true, exitStatus: 15) == .mayHaveRun(.timedOut))
        #expect(ShortcutRunOutcome.error(started: true, timedOut: false, exitStatus: 1) == .mayHaveRun(.didNotFinish))
        #expect(ShortcutRunOutcome.error(started: false, timedOut: false, exitStatus: -1)?.failureKind == .failed)
    }

    @Test("a timeout wins over the exit status the killed process reports")
    func timeoutBeatsExit() {
        #expect(ShortcutRunOutcome.error(started: true, timedOut: true, exitStatus: 0) == .mayHaveRun(.timedOut))
    }

    @Test("what each error means for Retry", arguments: [
        (ActionExecutionError.permissionDenied("Calendar"), ActionFailureKind.failed),
        (.notFound("Slack"), .failed),
        (.backendFailed("x"), .failed),
        (.mayHaveRun(.timedOut), .uncertain),
        (.mayHaveRun(.didNotFinish), .uncertain),
        (.missingStart, .blocked),
        (.targetNotFound(.calendar, "Work"), .blocked),
        (.needsInput("x"), .blocked),
    ])
    func failureKinds(error: ActionExecutionError, kind: ActionFailureKind) {
        #expect(error.failureKind == kind)
    }

    @Test("the metrics categories stay inside the existing fixed list")
    func metricsCategories() {
        #expect(VoiceActionFailureCategory(.mayHaveRun(.timedOut)) == .timedOut)
        #expect(VoiceActionFailureCategory(.mayHaveRun(.didNotFinish)) == .backendFailed)
        #expect(VoiceActionFailureCategory(.missingStart) == .needsInput)
        #expect(VoiceActionFailureCategory(.targetNotFound(.list, "x")) == .notFound)
    }

    // MARK: Words

    @Test("an uncertain run says plainly that it may already have run")
    func uncertainWording() {
        #expect(ActionWording.mayHaveRun(.timedOut) == "Timed out. It may already have run.")
        #expect(ActionWording.mayHaveRun(.didNotFinish).contains("may have partly run"))
        #expect(ActionWording.line(for: .mayHaveRun(.timedOut)) == "Timed out. It may already have run.")
    }

    @Test("a missing target names exactly what was not found")
    func notFoundWording() {
        #expect(ActionWording.line(for: .targetNotFound(.calendar, "Holidays")) == "Couldn't find a calendar called \u{201C}Holidays\u{201D}")
        #expect(ActionWording.line(for: .targetNotFound(.list, "Errands")) == "Couldn't find a Reminders list called \u{201C}Errands\u{201D}")
        #expect(ActionWording.line(for: .targetNotFound(.shortcut, "Ghost")) == "Couldn't find a shortcut called \u{201C}Ghost\u{201D}")
    }

    @Test("the Shortcut warning is the one plain line the card shows")
    func shortcutWarning() {
        #expect(ActionWording.shortcutWarning == "This runs your shortcut. Hushy can't undo what it does.")
        #expect(ActionWording.undoFailed(for: .createEvent) == "Couldn't undo. The event is still in Calendar.")
        #expect(ActionWording.undoFailed(for: .createReminder) == "Couldn't undo. The reminder is still in Reminders.")
    }

    // MARK: History

    @Test("failed and uncertain actions are stored and read back with their status")
    func statusRoundTrip() throws {
        let store = try Store()
        let failed = try store.save(ActionRecord(kind: .createEvent, title: "Dentist", detail: "Oct 7", sourceText: "x", status: .failed))
        let uncertain = try store.save(ActionRecord(kind: .runShortcut, title: "Send Standup", sourceText: "x", status: .uncertain))
        #expect(try store.actionRecord(id: failed.id!)?.status == .failed)
        #expect(try store.actionRecord(id: uncertain.id!)?.status == .uncertain)
        #expect(try store.actionRecord(id: uncertain.id!)?.undoBackendID == nil)
    }

    @Test("History gives each outcome one plain line")
    func historyLines() {
        func record(_ kind: ProposedAction.Kind, _ title: String, _ status: ActionRecord.Status, detail: String? = nil) -> ActionRecord {
            ActionRecord(kind: kind, title: title, detail: detail, sourceText: "x", status: status)
        }
        #expect(ActionRecordLine.text(for: record(.createEvent, "Dentist", .completed, detail: "Oct 7")) == "Added \u{201C}Dentist\u{201D} to Calendar \u{00B7} Oct 7")
        #expect(ActionRecordLine.text(for: record(.createEvent, "Dentist", .failed, detail: "Oct 7")) == "Couldn't add \u{201C}Dentist\u{201D} to Calendar \u{00B7} Oct 7")
        #expect(ActionRecordLine.text(for: record(.createReminder, "Call Dana", .failed)) == "Couldn't add \u{201C}Call Dana\u{201D} to Reminders")
        #expect(ActionRecordLine.text(for: record(.runShortcut, "Start Focus", .failed)) == "Couldn't run shortcut \u{201C}Start Focus\u{201D}")
        #expect(ActionRecordLine.text(for: record(.openLink, "Open Chrome", .failed)) == "Couldn't open \u{201C}Chrome\u{201D}")
        #expect(ActionRecordLine.text(for: record(.runShortcut, "Send Standup", .uncertain, detail: "Shortcut: Send Standup"))
            == "\u{201C}Send Standup\u{201D} may have run. Hushy can't tell.")
        #expect(ActionRecordLine.text(for: record(.createReminder, "Call Dana", .undone)).hasPrefix("Undone: "))
    }

    @Test("a failed or uncertain line carries no reason and no more than a done line does")
    func linesCarryNothingExtra() {
        let secret = "Work calendar (alice@example.com)"
        let uncertain = ActionRecord(kind: .runShortcut, title: "Send Standup", detail: nil, sourceText: "x", status: .uncertain)
        #expect(!ActionRecordLine.text(for: uncertain).contains(secret))
        #expect(ActionRecordLine.text(for: uncertain).count < 60)
    }

    @Test("a failed or uncertain action needs attention in the timeline")
    func attention() {
        for status in [ActionRecord.Status.failed, .uncertain] {
            #expect(TimelineEntry.action(ActionRecord(kind: .runShortcut, title: "x", sourceText: "x", status: status)).needsAttention)
        }
        #expect(!TimelineEntry.action(ActionRecord(kind: .runShortcut, title: "x", sourceText: "x")).needsAttention)
    }

    // MARK: Undo failure

    @Test("a failed Undo marks the record, keeps it completed and keeps the token")
    func undoFailureRecorded() throws {
        let store = try Store()
        let saved = try store.save(ActionRecord(kind: .createEvent, title: "Dentist", sourceText: "x", undoBackendID: "abc"))
        try store.markActionUndoFailed(id: saved.id!, at: Date(timeIntervalSince1970: 100))
        let fetched = try #require(try store.actionRecord(id: saved.id!))
        #expect(fetched.status == .completed)
        #expect(fetched.undoBackendID == "abc")
        #expect(fetched.undoFailedAt == Date(timeIntervalSince1970: 100))
        #expect(ActionRecordLine.undoNote(for: fetched) == "Couldn't undo. It's still in Calendar.")
    }

    @Test("a later successful Undo clears the failure mark")
    func undoSuccessClearsMark() throws {
        let store = try Store()
        let saved = try store.save(ActionRecord(kind: .createReminder, title: "Call Dana", sourceText: "x", undoBackendID: "abc"))
        try store.markActionUndoFailed(id: saved.id!)
        try store.markActionUndone(id: saved.id!)
        let fetched = try #require(try store.actionRecord(id: saved.id!))
        #expect(fetched.status == .undone)
        #expect(fetched.undoFailedAt == nil)
        #expect(ActionRecordLine.undoNote(for: fetched) == nil)
    }

    @Test("the failure mark is only written on a completed record")
    func undoFailureOnlyWhenCompleted() throws {
        let store = try Store()
        let saved = try store.save(ActionRecord(kind: .createEvent, title: "Dentist", sourceText: "x", status: .failed))
        try store.markActionUndoFailed(id: saved.id!)
        #expect(try store.actionRecord(id: saved.id!)?.undoFailedAt == nil)
    }

    // MARK: What is shown

    @Test("an event shows its length, so the 30-minute default is on screen")
    func eventLengthShown() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let start = Date(timeIntervalSince1970: 1_791_385_200) // 2026-10-07 15:00 UTC
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let text = ActionDisplay.eventText(start: start, end: start.addingTimeInterval(1800), now: now, locale: locale, timeZone: zone)
        #expect(text.contains("3:00"))
        #expect(text.contains("3:30"))
        #expect(text.contains("\u{2013}"))
        #expect(!text.contains("2026"), "this year is left off")
    }

    @Test("a start in another year shows the year; no end shows the start alone")
    func yearAndNoEnd() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let start = Date(timeIntervalSince1970: 1_791_385_200)
        let later = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(ActionDisplay.startText(start, now: later, locale: locale, timeZone: zone).contains("2026"))
        #expect(!ActionDisplay.eventText(start: start, end: nil, now: start, locale: locale, timeZone: zone).contains("\u{2013}"))
    }

    @Test("only events and reminders have a time line")
    func whenOnlyForDated() {
        let when = Date()
        #expect(ActionDisplay.whenText(for: ProposedAction(kind: .runShortcut, title: "x", start: when, sourceText: "x")) == nil)
        #expect(ActionDisplay.whenText(for: ProposedAction(kind: .createReminder, title: "x", sourceText: "x")) == nil)
        #expect(ActionDisplay.whenText(for: ProposedAction(kind: .createReminder, title: "x", start: when, sourceText: "x")) != nil)
    }
}
