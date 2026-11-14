import Foundation
import Testing
@testable import MurmurCore

/// A list or calendar that was named and is not there: the action is refused (never swapped for
/// the default on Hushy's own say) and the refusal carries the one way forward. Pure: what is
/// offered, what taking it changes, and the words.
@Suite("Action recovery: a list or calendar that isn't there")
struct ActionRecoveryTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a missing list or calendar offers the default; nothing else that refuses an action does")
    func offeredOnlyForAMissingPlace() {
        #expect(ActionRecovery(for: .targetNotFound(.list, "Errands")) == .useDefault(.list, missing: "Errands"))
        #expect(ActionRecovery(for: .targetNotFound(.calendar, "Holidays")) == .useDefault(.calendar, missing: "Holidays"))
        // A Shortcut has no default to fall back to, and the rest are not about where it goes.
        let others: [ActionExecutionError] = [
            .targetNotFound(.shortcut, "Send Standup"), .missingStart, .permissionDenied("Reminders"), .notFound("x"),
            .saveFailed, .backendFailed("x"), .needsInput("x"), .mayHaveRun(.timedOut), .closestApps(heard: "x", apps: ["y"]),
        ]
        for error in others { #expect(ActionRecovery(for: error) == nil, "\(error)") }
    }

    @Test("taking the offer drops only the place that wasn't found: the title, time and length are what was asked")
    func appliedKeepsEverythingElse() {
        let reminder = ProposedAction(
            kind: .createReminder, title: "Team sync", start: start, listName: "Errands", dateSourcePhrase: "at 11",
            sourceText: "remind me about the team sync at 11")
        let recoveredReminder = ActionRecovery.useDefault(.list, missing: "Errands").applied(to: reminder)
        var expectedReminder = reminder
        expectedReminder.listName = nil
        #expect(recoveredReminder == expectedReminder)
        #expect(recoveredReminder.id == reminder.id, "the same row, not a new action")

        let event = ProposedAction(
            kind: .createEvent, title: "Dentist", start: start, end: start.addingTimeInterval(2_700),
            calendarName: "Holidays", location: "Main St", sourceText: "x")
        let recoveredEvent = ActionRecovery.useDefault(.calendar, missing: "Holidays").applied(to: event)
        var expectedEvent = event
        expectedEvent.calendarName = nil
        #expect(recoveredEvent == expectedEvent)
        #expect(ActionPreflight.namedTarget(of: recoveredEvent) == nil, "nothing named: the executor uses the default")
    }

    @Test("the question says what is missing and what the tick does, by kind")
    func wording() {
        #expect(ActionWording.useDefaultQuestion(.useDefault(.list, missing: "Errands"))
            == "No list called \u{201C}Errands\u{201D}. Add to your default list?")
        #expect(ActionWording.useDefaultQuestion(.useDefault(.calendar, missing: "Holidays"))
            == "No calendar called \u{201C}Holidays\u{201D}. Add to your default calendar?")
        #expect(ActionWording.useDefaultTitle(.useDefault(.list, missing: "Errands")) == "Add to default list")
        #expect(ActionWording.useDefaultTitle(.useDefault(.calendar, missing: "Holidays")) == "Add to default calendar")
        #expect(ActionWording.useDefaultButton == "Use default")
    }

    @Test("a very long name gives way and the question is whole, however little room the name is given")
    func longNameShortened() {
        let long = String(repeating: "Quarterly planning ", count: 4)
        let question = ActionWording.useDefaultQuestion(.useDefault(.list, missing: long))
        #expect(question.hasSuffix("\u{2026}\u{201D}. Add to your default list?"))
        #expect(question.count <= 80)
        // The row asks for a shorter name when the line would not fit: the question is never what is cut.
        for limit in [20, 12, ActionWording.questionNameFloor, 1, 0, -3] {
            let list = ActionWording.useDefaultQuestion(.useDefault(.list, missing: long), nameLimit: limit)
            #expect(list.hasPrefix("No list called \u{201C}Qua"), "\(limit)")
            #expect(list.hasSuffix("\u{2026}\u{201D}. Add to your default list?"), "\(limit)")
            let calendar = ActionWording.useDefaultQuestion(.useDefault(.calendar, missing: long), nameLimit: limit)
            #expect(calendar.hasSuffix("\u{2026}\u{201D}. Add to your default calendar?"), "\(limit)")
            let kept = max(limit, ActionWording.questionNameFloor)
            #expect(list.count <= "No list called \u{201C}\u{201D}. Add to your default list?".count + kept, "\(limit)")
        }
        // A name that fits the limit is shown as it is.
        #expect(ActionWording.useDefaultQuestion(.useDefault(.list, missing: "Errands"), nameLimit: 7).contains("\u{201C}Errands\u{201D}"))
        // The plain refusal line is unchanged: it names the list in full.
        #expect(ActionWording.targetNotFound(.list, long).contains(long))
    }

    @Test("an offer stands for the refusal it answers, so a question nobody takes counts as that failure")
    func refusalBehindTheOffer() {
        for error in [ActionExecutionError.targetNotFound(.list, "Errands"), .targetNotFound(.calendar, "Holidays")] {
            #expect(ActionRecovery(for: error)?.refusal == error)
            #expect(ActionRecovery(for: error).map { VoiceActionFailureCategory($0.refusal) } == .notFound)
        }
    }

    @Test("the refusal's own line and kind are unchanged: still refused, still not retryable as it stands")
    func refusalUnchanged() {
        let error = ActionExecutionError.targetNotFound(.list, "Errands")
        #expect(error.failureKind == .blocked)
        #expect(ActionWording.line(for: error) == "Couldn't find a Reminders list called \u{201C}Errands\u{201D}")
        #expect(error.logStepAndReason == "target lookup: list not found")
    }
}
