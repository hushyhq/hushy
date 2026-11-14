import Foundation
import Testing
@testable import MurmurCore

@Suite("ActionValidator")
struct ActionValidatorTests {
    private var fixedNow: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 23; components.hour = 10
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    @Test("drops an action with an empty title")
    func dropsEmptyTitle() {
        let generated = GeneratedAction(kind: .createEvent, title: "  ", when: "tomorrow", durationMinutes: 0, listOrCalendarName: "", location: "", shortcutInput: "")
        let result = ActionValidator.validate(generated, utterance: "x", fallbackAnchor: nil, context: DateContext(now: fixedNow, timeZone: .init(identifier: "UTC")!))
        #expect(result == nil)
    }

    @Test("drops 'none' kind — this isn't a command")
    func dropsNoneKind() {
        let generated = GeneratedAction(kind: .none, title: "irrelevant", when: "", durationMinutes: 0, listOrCalendarName: "", location: "", shortcutInput: "")
        let result = ActionValidator.validate(generated, utterance: "x", fallbackAnchor: nil, context: DateContext(now: fixedNow, timeZone: .init(identifier: "UTC")!))
        #expect(result == nil)
    }

    @Test("createEvent defaults to a 30 minute duration when none is given")
    func defaultsDuration() {
        let generated = GeneratedAction(kind: .createEvent, title: "Dentist", when: "tomorrow at 3pm", durationMinutes: 0, listOrCalendarName: "", location: "", shortcutInput: "")
        guard let action = ActionValidator.validate(generated, utterance: "x", fallbackAnchor: nil, context: DateContext(now: fixedNow, timeZone: .init(identifier: "UTC")!)),
              let start = action.start, let end = action.end else {
            Issue.record("expected a resolved event")
            return
        }
        #expect(end.timeIntervalSince(start) == DateAnchor.defaultDurationSeconds)
    }

    @Test("createEvent honors an explicit duration")
    func honorsExplicitDuration() {
        let generated = GeneratedAction(kind: .createEvent, title: "Standup", when: "tomorrow at 9am", durationMinutes: 15, listOrCalendarName: "", location: "", shortcutInput: "")
        guard let action = ActionValidator.validate(generated, utterance: "x", fallbackAnchor: nil, context: DateContext(now: fixedNow, timeZone: .init(identifier: "UTC")!)),
              let start = action.start, let end = action.end else {
            Issue.record("expected a resolved event")
            return
        }
        #expect(end.timeIntervalSince(start) == 15 * 60)
    }

    @Test("runShortcut carries the shortcut name and input through")
    func shortcutSlots() {
        let generated = GeneratedAction(kind: .runShortcut, title: "Start Focus", when: "", durationMinutes: 0, listOrCalendarName: "", location: "", shortcutInput: "deep work")
        guard let action = ActionValidator.validate(generated, utterance: "x", fallbackAnchor: nil, context: DateContext(now: fixedNow, timeZone: .init(identifier: "UTC")!)) else {
            Issue.record("expected a resolved shortcut action")
            return
        }
        #expect(action.shortcutName == "Start Focus")
        #expect(action.shortcutInput == "deep work")
    }

    @Test("createReminder with no date still validates (Edit can fill it in)")
    func reminderWithoutDate() {
        let generated = GeneratedAction(kind: .createReminder, title: "Buy flowers", when: "", durationMinutes: 0, listOrCalendarName: "", location: "", shortcutInput: "")
        let action = ActionValidator.validate(generated, utterance: "x", fallbackAnchor: nil, context: DateContext(now: fixedNow, timeZone: .init(identifier: "UTC")!))
        #expect(action != nil)
        #expect(action?.start == nil)
    }

    /// The tools eval found reminders losing their date: `NSDataDetector` returned nothing for
    /// these phrases and the validator dropped the date. Now `RelativeDateParser` resolves them.
    @Test("keeps the date for spoken phrases NSDataDetector missed", arguments: [
        ("in 3 hours", "2026-09-23T13:00:00Z"),
        ("in 10 minutes", "2026-09-23T10:10:00Z"),
        ("at 4 15", "2026-09-23T16:15:00Z"),
        ("on the 10th", "2026-10-10T09:00:00Z"),
        ("by eod", "2026-09-23T17:00:00Z"),
        ("end of day", "2026-09-23T17:00:00Z"),
        ("day after tomorrow", "2026-09-25T09:00:00Z"),
        ("evening 7", "2026-09-23T19:00:00Z"),
    ])
    func keepsRelativeDates(_ phrase: String, _ expected: String) {
        let generated = GeneratedAction(kind: .createReminder, title: "Stretch", when: phrase, durationMinutes: 0, listOrCalendarName: "", location: "", shortcutInput: "")
        let action = ActionValidator.validate(generated, utterance: "x", fallbackAnchor: nil, context: DateContext(now: fixedNow, timeZone: .init(identifier: "UTC")!))
        #expect(action?.start == ProposalFields.parseISO8601(expected))
        #expect(action?.dateSourcePhrase == phrase)
    }

    @Test("en_IN day-first numeric dates")
    func dayFirstInIndia() {
        let generated = GeneratedAction(kind: .createReminder, title: "Pay rent", when: "12/10 at 10 am", durationMinutes: 0, listOrCalendarName: "", location: "", shortcutInput: "")
        let context = DateContext(now: fixedNow, timeZone: TimeZone(identifier: "Asia/Kolkata")!, locale: Locale(identifier: "en_IN"))
        let action = ActionValidator.validate(generated, utterance: "x", fallbackAnchor: nil, context: context)
        #expect(action?.start == ProposalFields.parseISO8601("2026-10-12T10:00:00+05:30"))
    }

    @Test("a spoken range sets the event's end")
    func rangeSetsEnd() {
        let generated = GeneratedAction(kind: .createEvent, title: "Workshop", when: "tomorrow 2 to 4 pm", durationMinutes: 0, listOrCalendarName: "", location: "", shortcutInput: "")
        let action = ActionValidator.validate(generated, utterance: "x", fallbackAnchor: nil, context: DateContext(now: fixedNow, timeZone: .init(identifier: "UTC")!))
        #expect(action?.start == ProposalFields.parseISO8601("2026-09-24T14:00:00Z"))
        #expect(action?.end == ProposalFields.parseISO8601("2026-09-24T16:00:00Z"))
    }
}
