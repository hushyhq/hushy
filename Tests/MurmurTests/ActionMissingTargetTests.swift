import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// A voice action that names a list or calendar which isn't there (the person misnamed it, or the
/// model filled one in). It is still refused, never moved to the default on Hushy's own say; but the
/// pill now asks, one tick adds the same item to the default with Undo, and History ends with one
/// row that says what happened. Fake backends and an in-memory store only.
@Suite("Voice actions: a list or calendar that isn't there")
@MainActor
struct ActionMissingTargetTests {
    typealias Rig = VoiceActionOutcomeTests.Rig

    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// The fake has the lists "Reminders" (default) and "Groceries", and the calendars "Home"
    /// (default) and "Work". "Errands" and "Holidays" exist in neither.
    func reminder(list: String? = "Errands", title: String = "Team sync") -> ProposedAction {
        ProposedAction(
            kind: .createReminder, title: title, start: start, listName: list,
            sourceText: "remind me about the team sync at eleven")
    }

    func event(calendar: String? = "Holidays") -> ProposedAction {
        ProposedAction(
            kind: .createEvent, title: "Dentist", start: start, end: start.addingTimeInterval(1_800),
            calendarName: calendar, sourceText: "add dentist tomorrow at three")
    }

    /// Dispatches one action and returns the refused row.
    func refusedRow(_ rig: Rig, _ action: ProposedAction) async throws -> ActionConfirmationRow {
        await rig.controller.dispatch([action], utterance: action.sourceText)
        return try #require(rig.card?.rows.first)
    }

    func accept(_ rig: Rig, _ row: ActionConfirmationRow) async {
        rig.controller.acceptOffer(row)
        await rig.settle { rig.chip != nil || rig.card?.rows.first.map { $0.status != .confirming } == true }
    }

    /// Every reminder created, read only after anything a wrong tick could have started has
    /// landed. No fixed wait: two more reminders go through the same executor and backend, one
    /// after the other, behind whatever was started before them. When the second is in, so is the rest.
    func createdAfterDrain(_ rig: Rig) async -> [String] {
        for marker in ["Marker 1", "Marker 2"] {
            await rig.controller.dispatch([reminder(list: nil, title: marker)], utterance: marker)
        }
        return await rig.calendar.createdReminders.map(\.action.title)
    }

    func records(_ rig: Rig, titled title: String = "Team sync") -> [ActionRecord] {
        rig.records.filter { $0.title == title }
    }

    // MARK: The refusal carries the way forward

    @Test("a missing list is still refused and nothing is saved, but the row offers the default and waits for an answer")
    func missingListOffersDefault() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        #expect(row.status == .blocked("Couldn't find a Reminders list called \u{201C}Errands\u{201D}"))
        #expect(!row.status.canRunAgain, "the same action again would fail the same way")
        #expect(row.offer == .useDefault(.list, missing: "Errands"))
        #expect(await rig.calendar.createdReminders.isEmpty, "never moved to the default without the person's tick")
        #expect(rig.records.map(\.status) == [.failed])

        let card = try #require(rig.card)
        #expect(card.soleOfferRow?.id == row.id)
        #expect(!card.isFailureToast, "a question waits; it does not clear itself and take the reminder with it")
        #expect(PillState.actionConfirm(card).selfDismissDelay == nil)
        #expect(PillState.actionConfirm(card).keyScope == .confirm, "return takes the offer, esc dismisses, while its key window is open")
        #expect(card.waitsOnOffer)
    }

    @Test("the pill asks in one line what the tick will do, and the hover says which item")
    func pillWording() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        #expect(ActionProblemRow.line(for: row) == "No list called \u{201C}Errands\u{201D}. Add to your default list?")
        #expect(ActionProblemRow.acceptHint(for: row, keysLive: true) == PillHint(title: "Add to default list", key: "return"))
        #expect(ActionProblemRow.acceptHint(for: row, keysLive: false) == PillHint(title: "Add to default list", key: nil),
                "no key is named once return has stopped answering the pill")
        #expect(rig.pill.state.hoverDetail?.hasPrefix("Add \"Team sync\" \u{00B7} ") == true, "what the tick adds: the title and its time")

        // A row with nothing to offer reads as before and has no tick.
        var plain = ActionConfirmationRow(action: reminder(list: nil))
        plain.status = .failed("Reminders access needed")
        #expect(ActionProblemRow.line(for: plain) == "Reminders access needed")
        #expect(ActionProblemRow.acceptHint(for: plain, keysLive: true) == nil)
    }

    // MARK: Taking the offer

    @Test("one tick adds the same reminder to the default list; the chip names the list and carries Undo")
    func acceptAddsToDefault() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        await accept(rig, row)

        let created = await rig.calendar.createdReminders
        #expect(created.count == 1)
        #expect(created.first?.action.listName == nil, "the place that wasn't found is gone; nothing else is guessed")
        #expect(created.first?.action.title == "Team sync")
        #expect(created.first?.action.start == start)
        let chip = try #require(rig.chip)
        #expect(chip.title == "Added: Team sync")
        #expect(chip.detail?.hasSuffix("Reminders") == true, "where it landed is on the chip")
        #expect(chip.canUndo)
    }

    @Test("History ends with one row for the one request: added, where it landed, not a failure left behind")
    func historyOneTruthfulRow() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        let failed = try #require(rig.records.first)
        #expect(ActionRecordLine.text(for: failed).hasPrefix("Couldn't add \u{201C}Team sync\u{201D} to Reminders"))
        #expect(failed.sourceText.isEmpty, "a refused attempt keeps no spoken words")

        await accept(rig, row)
        let records = rig.records
        #expect(records.count == 1)
        let done = try #require(records.first)
        #expect(done.id == failed.id, "the refused row became the done row")
        #expect(done.status == .completed)
        #expect(done.undoBackendID != nil)
        #expect(ActionRecordLine.text(for: done).hasPrefix("Added \u{201C}Team sync\u{201D} to Reminders"))
        #expect(done.detail?.hasSuffix("Reminders") == true)
        #expect(!(done.detail ?? "").contains("Errands"), "the list that isn't there is never written to History")
    }

    @Test("Undo after the offer really removes the reminder and History says undone")
    func undoAfterAccept() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        await accept(rig, row)
        rig.controller.undoDone()
        await rig.settle { rig.chip?.undone == true || rig.chip?.undoFailure != nil }
        #expect(rig.chip?.undone == true)
        #expect(await rig.calendar.createdReminders.isEmpty)
        #expect(rig.records.map(\.status) == [.undone])
    }

    @Test("return takes the offer; a second tick or return adds nothing more")
    func returnAcceptsOnce() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        rig.controller.confirmAll()
        rig.controller.confirmAll()
        rig.controller.acceptOffer(row)
        await rig.settle { rig.chip != nil }
        #expect(await createdAfterDrain(rig) == ["Team sync", "Marker 1", "Marker 2"])
        #expect(records(rig).map(\.status) == [.completed])
    }

    @Test("esc or the cross dismisses: nothing is added and History keeps the refused attempt")
    func dismissAddsNothing() async throws {
        for dismiss in ["esc", "cross"] {
            let rig = try Rig()
            let row = try await refusedRow(rig, reminder())
            if dismiss == "esc" { rig.controller.cancelAll() } else { rig.controller.cancel(row) }
            #expect(rig.pill.state == .idle, "\(dismiss)")
            rig.controller.acceptOffer(row)
            rig.controller.confirmAll()
            #expect(rig.pill.state == .idle, "\(dismiss): a dismissed question takes no tick")
            #expect(await createdAfterDrain(rig) == ["Marker 1", "Marker 2"], "\(dismiss)")
            #expect(records(rig).map(\.status) == [.failed], "\(dismiss)")
        }
    }

    @Test("a missing calendar works the same way: asked, then the event goes on the default calendar")
    func missingCalendar() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, event())
        #expect(row.offer == .useDefault(.calendar, missing: "Holidays"))
        #expect(ActionProblemRow.line(for: row) == "No calendar called \u{201C}Holidays\u{201D}. Add to your default calendar?")
        await accept(rig, row)
        let created = await rig.calendar.createdEvents
        #expect(created.count == 1)
        #expect(created.first?.action.calendarName == nil)
        #expect(created.first?.action.end == start.addingTimeInterval(1_800), "the length that was asked for")
        #expect(rig.chip?.detail?.hasSuffix("Home") == true)
        #expect(rig.records.map(\.status) == [.completed])
    }

    // MARK: What does not change

    @Test("a list that exists is used as named, with no question")
    func existingListUnchanged() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([reminder(list: "groceries")], utterance: "x")
        #expect(rig.card == nil)
        #expect(rig.chip?.detail?.hasSuffix("groceries") == true)
        #expect(await rig.calendar.createdReminders.first?.action.listName == "groceries")
    }

    @Test("a missing Shortcut, an event with no time and a plain failure offer nothing")
    func noOfferElsewhere() async throws {
        let shortcuts = try Rig(installed: ["Other"])
        let shortcut = ProposedAction(kind: .runShortcut, title: "Send Standup", shortcutName: "Send Standup", sourceText: "x")
        await shortcuts.controller.dispatch([shortcut], utterance: "x")
        let pending = try #require(shortcuts.card)
        shortcuts.controller.confirm(pending.rows[0], in: pending)
        await shortcuts.settle { shortcuts.card?.rows.first?.status != .confirming }
        #expect(shortcuts.card?.rows.first?.offer == nil)
        #expect(shortcuts.card?.isFailureToast == true)

        let undated = try Rig(setting: .never)
        await undated.controller.dispatch([ProposedAction(kind: .createEvent, title: "Dentist", sourceText: "x")], utterance: "x")
        #expect(undated.card?.rows.first?.offer == nil)

        let failing = try Rig()
        await failing.calendar.setNextError(.backendFailed("Calendar is busy"))
        let row = try await refusedRow(failing, reminder(list: nil))
        #expect(row.offer == nil)
        #expect(row.status.canRunAgain)
        let failedCard = try #require(failing.card)
        #expect(PillState.actionConfirm(failedCard).keyScope == .dismiss)
    }

    @Test("if the default can't take it either, the row says so with Retry, and History still has one row")
    func defaultFailsToo() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        await rig.calendar.setNextError(.backendFailed("Calendar is busy"))
        await accept(rig, row)
        let after = try #require(rig.card?.rows.first)
        #expect(after.status == .failed("Calendar is busy"))
        #expect(after.offer == nil, "the offer was taken; what is left is an ordinary Retry")
        #expect(rig.records.map(\.status) == [.failed])

        let retryCard = try #require(rig.card)
        rig.controller.confirm(after, in: retryCard)
        await rig.settle { rig.chip != nil }
        #expect(await rig.calendar.createdReminders.count == 1)
        #expect(rig.records.map(\.status) == [.completed], "still the one row, now done")
    }

    @Test("the refused attempt costs no free action; the one that is added costs one")
    func allowanceCountsTheAddOnly() async throws {
        let rig = try Rig()
        rig.controller.isEntitled = { false }
        let row = try await refusedRow(rig, reminder())
        let usedBefore = try rig.store.voiceActionsThisMonth()
        #expect(usedBefore == 0)
        await accept(rig, row)
        let usedAfter = try rig.store.voiceActionsThisMonth()
        #expect(usedAfter == 1)
    }

    @Test("usage numbers: one request is one event. Nothing while it is asked, then one success when the tick adds it")
    func metrics() async throws {
        let rig = try Rig()
        var events: [VoiceActionMetricEvent] = []
        rig.controller.onMetric = { events.append($0) }
        let row = try await refusedRow(rig, reminder())
        #expect(events.isEmpty, "a question is not an outcome yet")
        await accept(rig, row)
        #expect(events == [VoiceActionMetricEvent(outcome: .succeeded, failure: nil)])
    }

    // MARK: A card the person confirmed

    @Test("a confirmed row that names a missing list gets the same offer")
    func confirmedRowOffers() async throws {
        let rig = try Rig(setting: .always)
        await rig.controller.dispatch([reminder()], utterance: "x")
        let card = try #require(rig.card)
        #expect(card.rows[0].status == .pending)
        rig.controller.confirm(card.rows[0], in: card)
        await rig.settle { rig.card?.rows.first?.status != .confirming }
        let row = try #require(rig.card?.rows.first)
        #expect(row.offer == .useDefault(.list, missing: "Errands"))
        await accept(rig, row)
        #expect(rig.chip?.canUndo == true)
        #expect(rig.records.map(\.status) == [.completed])
    }

    @Test("in a card of two, the refused row offers the default on its own row and the other is untouched")
    func stackedRowOffers() async throws {
        let rig = try Rig()
        let other = ProposedAction(kind: .createReminder, title: "Call Dana", sourceText: "x")
        await rig.controller.dispatch([reminder(), other], utterance: "x")
        rig.controller.confirmAll()
        await rig.settle { rig.card?.rows.allSatisfy { $0.status != .confirming && $0.status != .pending } == true }
        let card = try #require(rig.card)
        #expect(card.rows[0].offer == .useDefault(.list, missing: "Errands"))
        #expect(card.rows[1].status == .succeeded(undoToken: ActionUndoToken(backendID: "fake-reminder-1")))
        #expect(card.soleOfferRow == nil, "the pill row is for a card of one; here the row carries its own button")
        #expect(!card.isFailureToast, "the card stays while its question is open")
        #expect(ActionConfirmationRowView.detail(for: card.rows[0]) == "Couldn't find a Reminders list called \u{201C}Errands\u{201D}")

        rig.controller.acceptOffer(card.rows[0])
        await rig.settle { rig.card == nil }
        #expect(await rig.calendar.createdReminders.count == 2)
        #expect(Set(rig.records.map(\.status)) == [.completed])
        #expect(rig.records.count == 2)
    }
}
