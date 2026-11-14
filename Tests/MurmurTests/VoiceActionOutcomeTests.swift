import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Fixes 1 to 4 through the voice-action controller, with fake backends only: nothing here touches
/// a real calendar, Reminders list, Shortcut or the person's data folder (the store is in memory).
@Suite("Voice actions: outcomes, undo, Shortcuts")
@MainActor
struct VoiceActionOutcomeTests {
    @MainActor
    struct Rig {
        let controller: VoiceActionsController
        let pill: PillModel
        let store: Store
        let calendar: FakeCalendarBackend
        let shortcuts: FakeShortcutsBackend
        let links: FakeLinkBackend

        init(installed: [String] = ["Send Standup", "Start Focus"], setting: ActionPolicy.AskBeforeDoing = .risky) throws {
            store = try Store()
            pill = PillModel()
            calendar = FakeCalendarBackend()
            shortcuts = FakeShortcutsBackend(installedShortcuts: installed)
            links = FakeLinkBackend()
            let integrity = SpeechModelIntegrity(
                fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: "hushy-test-\(UUID().uuidString)")
            controller = VoiceActionsController(
                hotkeys: ActionHotkeyMonitor(), pill: pill,
                speech: SpeechEngine(status: SpeechModelStatus(), integrity: integrity),
                modelStatus: SpeechModelStatus(), store: store, calendarBackend: calendar,
                shortcutsBackend: shortcuts, linkBackend: links)
            controller.isEntitled = { true }
            controller.askBeforeDoing = { setting }
        }

        var card: ActionConfirmationCardState? {
            if case .actionConfirm(let card) = pill.state { card } else { nil }
        }

        var chip: DoneChipState? {
            if case .actionDone(let chip) = pill.state { chip } else { nil }
        }

        var records: [ActionRecord] { (try? store.recentActions()) ?? [] }

        /// Lets the confirm Task and any Undo Task finish.
        func settle(until done: () -> Bool) async {
            var tries = 0
            while !done(), tries < 400 {
                try? await Task.sleep(for: .milliseconds(5))
                tries += 1
            }
        }
    }

    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func shortcut(_ name: String = "Send Standup") -> ProposedAction {
        ProposedAction(kind: .runShortcut, title: name, shortcutName: name, sourceText: "run \(name)")
    }

    func event(calendar: String? = nil, start: Date?) -> ProposedAction {
        ProposedAction(
            kind: .createEvent, title: "Dentist", start: start, end: start?.addingTimeInterval(1800),
            calendarName: calendar, sourceText: "add dentist")
    }

    func reminder(_ title: String = "Call Dana") -> ProposedAction {
        ProposedAction(kind: .createReminder, title: title, sourceText: "remind me to \(title.lowercased())")
    }

    func confirmFirstRow(_ rig: Rig) async {
        guard let card = rig.card, let row = card.rows.first else { return }
        rig.controller.confirm(row, in: card)
        await rig.settle { rig.card?.rows.first?.status != .confirming }
    }

    // MARK: Fix 4: Shortcuts

    @Test("a Shortcut always gets the card, even with Ask before doing set to Never, and nothing ran yet")
    func shortcutAlwaysConfirmed() async throws {
        let rig = try Rig(setting: .never)
        await rig.controller.dispatch([shortcut()], utterance: "run send standup")
        let card = try #require(rig.card)
        #expect(card.rows.count == 1)
        #expect(card.rows[0].status == .pending)
        #expect(await rig.shortcuts.attempts == 0)
        #expect(ActionConfirmationRowView.detail(for: card.rows[0]) == "This runs your shortcut. Hushy can't undo what it does.")
        #expect(rig.records.isEmpty)
    }

    @Test("a confirmed Shortcut runs once, is recorded as done, and has no Undo")
    func shortcutRunsOnceWithoutUndo() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([shortcut()], utterance: "run send standup")
        await confirmFirstRow(rig)
        #expect(await rig.shortcuts.runs.count == 1)
        let record = try #require(rig.records.first)
        #expect(record.status == .completed)
        #expect(record.undoBackendID == nil)
        #expect(rig.card == nil || rig.card?.rows.first?.status == .succeeded(undoToken: nil))
    }

    @Test("a Shortcut that timed out is recorded as uncertain, says it may already have run, and is never run again")
    func shortcutUncertainNoRetry() async throws {
        let rig = try Rig()
        await rig.shortcuts.setNextError(.mayHaveRun(.timedOut))
        await rig.controller.dispatch([shortcut()], utterance: "run send standup")
        await confirmFirstRow(rig)
        let row = try #require(rig.card?.rows.first)
        #expect(row.status == .uncertain("Timed out. It may already have run."))
        #expect(!row.status.canRunAgain)
        #expect(rig.records.first?.status == .uncertain)
        #expect(await rig.shortcuts.attempts == 1)

        // Retry, Return and a second tap all go nowhere.
        rig.controller.confirm(row, in: try #require(rig.card))
        rig.controller.confirmAll()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await rig.shortcuts.attempts == 1, "no second run after a run that may have happened")
        #expect(rig.records.count == 1)
    }

    @Test("an uncertain row offers no Retry and still closes")
    func uncertainRowControls() {
        var row = ActionConfirmationRow(action: shortcut())
        row.status = .uncertain("Timed out. It may already have run.")
        #expect(!row.status.canRunAgain)
        #expect(!row.isResolved)
        var card = ActionConfirmationCardState(actions: [shortcut()])
        card.rows[0].status = .uncertain("x")
        #expect(card.isFailureToast, "it clears itself like any failure")
    }

    @Test("a Shortcut that isn't there says so by name and records a failure")
    func missingShortcut() async throws {
        let rig = try Rig(installed: ["Other"])
        await rig.controller.dispatch([shortcut("Send Standup")], utterance: "run send standup")
        await confirmFirstRow(rig)
        #expect(rig.card?.rows.first?.status == .blocked("Couldn't find a shortcut called \u{201C}Send Standup\u{201D}"))
        #expect(rig.records.first?.status == .failed)
    }

    // MARK: Fix 1: nothing guessed

    @Test("an event with no start never becomes an event: the card says it needs a time and offers no Retry")
    func eventWithoutStart() async throws {
        let rig = try Rig(setting: .never)
        await rig.controller.dispatch([event(start: nil)], utterance: "add dentist")
        let card = try #require(rig.card)
        #expect(card.rows[0].status == .blocked("Needs a time. Say it again with one."))
        #expect(!card.rows[0].status.canRunAgain)
        rig.controller.confirm(card.rows[0], in: card)
        rig.controller.confirmAll()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await rig.calendar.createdEvents.isEmpty)
        #expect(rig.records.isEmpty, "a card that never ran is not an attempt")
    }

    @Test("a calendar the person named that isn't there is refused by name, not saved to the default")
    func namedCalendarMissing() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([event(calendar: "Holidays", start: start)], utterance: "add dentist to holidays")
        let row = try #require(rig.card?.rows.first)
        #expect(row.status == .blocked("Couldn't find a calendar called \u{201C}Holidays\u{201D}"))
        #expect(await rig.calendar.createdEvents.isEmpty)
        #expect(rig.records.first?.status == .failed)
    }

    @Test("an unnamed calendar uses the default, and the done chip names it and the event's length")
    func defaultsVisibleOnChip() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([event(start: start)], utterance: "add dentist tomorrow at 3")
        // An event is Tier 1 only when its date is certain; "tomorrow at 3" has no vague phrase.
        let chip = try #require(rig.chip)
        let detail = try #require(chip.detail)
        #expect(detail.contains("\u{2013}"), "the 30-minute length is shown")
        #expect(detail.hasSuffix("Home"), "the default calendar is named")
    }

    @Test("an unnamed list uses the default and the chip says which")
    func defaultListVisible() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        #expect(rig.chip?.detail == "Reminders")
    }

    @Test("a named browser that couldn't take the link shows that the default opened it")
    func browserDefaultVisible() async throws {
        let rig = try Rig()
        await rig.links.setFallsBack(true)
        let open = ProposedAction(kind: .openLink, title: "Open Gmail", location: "safari", url: "https://mail.google.com/", sourceText: "x")
        await rig.controller.dispatch([open], utterance: "open gmail in safari")
        #expect(rig.chip?.detail == "mail.google.com \u{00B7} your default browser")
    }

    // MARK: Fix 2: outcomes recorded honestly

    @Test("a plain failure is recorded as failed, Retry works, and a retry that works is recorded too")
    func failedThenRetried() async throws {
        let rig = try Rig()
        await rig.calendar.setNextError(.backendFailed("Calendar is busy"))
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        let row = try #require(rig.card?.rows.first)
        #expect(row.status == .failed("Calendar is busy"))
        #expect(row.status.canRunAgain)
        #expect(rig.records.map(\.status) == [.failed])
        #expect(rig.records.first?.undoBackendID == nil)

        await confirmFirstRow(rig)
        #expect(await rig.calendar.createdReminders.count == 1)
        #expect(Set(rig.records.map(\.status)) == [.failed, .completed])
    }

    @Test("a failed attempt stores only what a done action stores: no reason, no calendar or list name")
    func failedStoresNoReason() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([event(calendar: "Alice's private calendar", start: start)], utterance: "x")
        let record = try #require(rig.records.first)
        let stored = [record.title, record.detail ?? "", record.sourceText].joined(separator: " ")
        #expect(!stored.contains("Alice"))
    }

    @Test("a failed attempt is not counted against the Free allowance")
    func failureNotCounted() async throws {
        let rig = try Rig()
        rig.controller.isEntitled = { false }
        await rig.calendar.setNextError(.backendFailed("x"))
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        let uses = try rig.store.voiceActionsThisMonth()
        #expect(uses == 0)
    }

    // MARK: Fix 3: Undo tells the truth

    @Test("Undo reads \"Undoing…\" while it runs and \"Undone\" only after the delete succeeded")
    func undoInProgressThenDone() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        let chip = try #require(rig.chip)
        #expect(chip.canUndo)
        rig.controller.undoDone()
        let during = try #require(rig.chip)
        #expect(during.isUndoing)
        #expect(!during.undone, "never \"Undone\" before the delete ran")
        #expect(!during.canUndo)

        await rig.settle { rig.chip?.undone == true || rig.chip?.undoFailure != nil }
        let after = try #require(rig.chip)
        #expect(after.undone)
        #expect(!after.isUndoing)
        #expect(rig.records.first?.status == .undone)
        #expect(await rig.calendar.createdReminders.isEmpty)
    }

    @Test("a delete that fails says so, leaves the record not undone, offers Undo again and records the failure")
    func undoFailure() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        await rig.calendar.setNextUndoError(.backendFailed("EKErrorDomain"))
        rig.controller.undoDone()
        await rig.settle { rig.chip?.isUndoing == false }
        let chip = try #require(rig.chip)
        #expect(!chip.undone)
        #expect(chip.undoFailure == "Couldn't undo. The reminder is still in Reminders.")
        #expect(chip.canUndo, "the item is still there, so Undo is offered again")
        let record = try #require(rig.records.first)
        #expect(record.status == .completed)
        #expect(record.undoBackendID != nil)
        #expect(record.undoFailedAt != nil)
        #expect(await rig.calendar.createdReminders.count == 1)
    }

    @Test("an item already deleted by hand counts as gone")
    func undoAlreadyGone() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        await rig.calendar.setNextUndoError(.notFound("x"))
        rig.controller.undoDone()
        await rig.settle { rig.chip?.undone == true }
        #expect(rig.chip?.undone == true)
        #expect(rig.records.first?.status == .undone)
    }

    @Test("two Undo taps on one record delete once")
    func undoOnce() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        let id = try #require(rig.records.first?.id)
        async let first = rig.controller.performUndo(recordID: id)
        async let second = rig.controller.performUndo(recordID: id)
        let outcomes = await [first, second]
        #expect(outcomes.filter { $0 == .undone }.count == 1)
        #expect(await rig.calendar.undone.count == 1)
    }

    @Test("the chip's lifetime covers a slow Undo, and no Undo is offered while it runs")
    func chipWhileUndoing() {
        var chip = DoneChipState(title: "Added: x", kind: .createReminder, undoRecordID: 1)
        #expect(chip.canUndo)
        chip.isUndoing = true
        #expect(!chip.canUndo)
        #expect(PillState.actionDone(chip).selfDismissDelay == .seconds(15))
        #expect(chip.accessibilityText == "Undoing.")
    }
}
