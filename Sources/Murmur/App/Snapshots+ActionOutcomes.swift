import MurmurCore
import SwiftUI

/// Task 114's review set (`t114-*`, light and dark): the Shortcut card with its warning, a
/// Shortcut that may have run, the cards that refuse (a calendar that isn't there, an event with
/// no time), the done chip with every default on it, Undo running and failing, and History's
/// done, undo-failed, undone, failed and uncertain rows. `HUSHY_SNAPSHOT_ONLY=t114-` renders just these.
extension Snapshots {
    static func renderActionOutcomes(scheme: ColorScheme, directory: URL) async {
        for (name, state) in outcomeStates() {
            let pill = PillModel()
            pill.state = state
            let view = PillView(model: pill)
                .padding(40)
                .background(Theme.bgSunken)
                .environment(\.colorScheme, scheme)
            await capture(view, name: "t114-\(name)", scheme: scheme, size: CGSize(width: 560, height: 360),
                          directory: directory, fixedSize: true)
        }
        await capture(
            historyRows().frame(width: 620).padding(24),
            name: "t114-history-outcomes", scheme: scheme, size: CGSize(width: 680, height: 330),
            directory: directory, fixedSize: true)
    }

    private static func outcomeStates() -> [(String, PillState)] {
        let shortcut = ProposedAction(
            kind: .runShortcut, title: "Send Standup", shortcutName: "Send Standup", sourceText: "run send standup")
        let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
        let event = ProposedAction(
            kind: .createEvent, title: "Dentist", start: start, end: start.addingTimeInterval(1800),
            calendarName: "Holidays", sourceText: "add dentist to holidays")
        let undated = ProposedAction(kind: .createEvent, title: "Dentist", sourceText: "add dentist")
        let list = ProposedAction(kind: .createReminder, title: "Oat milk", listName: "Errands", sourceText: "add oat milk to errands")

        var uncertain = ActionConfirmationCardState(actions: [shortcut])
        uncertain.rows[0].status = .uncertain(ActionWording.mayHaveRun(.timedOut))
        var running = ActionConfirmationCardState(actions: [shortcut])
        running.rows[0].status = .confirming
        var calendarMissing = ActionConfirmationCardState(actions: [event])
        calendarMissing.rows[0].status = .blocked(ActionWording.targetNotFound(.calendar, "Holidays"))
        var listMissing = ActionConfirmationCardState(actions: [list])
        listMissing.rows[0].status = .blocked(ActionWording.targetNotFound(.list, "Errands"))
        var failed = ActionConfirmationCardState(actions: [list])
        failed.rows[0].status = .failed("Reminders access needed")

        let eventChip = DoneChipState(
            title: "Added: Dentist",
            detail: VoiceActionsController.detail(for: ProposedAction(
                kind: .createEvent, title: "Dentist", start: start, end: start.addingTimeInterval(1800), sourceText: "x"),
                placedIn: "Home"),
            kind: .createEvent, undoRecordID: 1)
        var undoing = eventChip
        undoing.isUndoing = true
        var undoFailed = eventChip
        undoFailed.undoFailure = ActionWording.undoFailed(for: .createEvent)

        return [
            ("shortcut-confirm", .actionConfirm(ActionConfirmationCardState(actions: [shortcut]))),
            ("shortcut-confirm-stacked", .actionConfirm(ActionConfirmationCardState(actions: [
                shortcut, ProposedAction(kind: .createReminder, title: "Call Dana", sourceText: "x")]))),
            ("shortcut-running", .actionConfirm(running)),
            ("shortcut-uncertain", .actionConfirm(uncertain)),
            ("calendar-not-found", .actionConfirm(calendarMissing)),
            ("list-not-found", .actionConfirm(listMissing)),
            ("needs-time", .actionConfirm(ActionConfirmationCardState(actions: [undated]))),
            ("failed-retry", .actionConfirm(failed)),
            ("done-defaults", .actionDone(eventChip)),
            ("undo-running", .actionDone(undoing)),
            ("undo-failed", .actionDone(undoFailed)),
            ("confirmed-chip", .actionDone(DoneChipState(
                title: "Added: Call Dana", detail: VoiceActionsController.detail(
                    for: ProposedAction(kind: .createReminder, title: "Call Dana", sourceText: "x"), placedIn: "Reminders"),
                kind: .createReminder, undoRecordID: 2))),
            ("undo-not-recorded", .actionDone(DoneChipState(
                title: "Added: Dentist", detail: nil, kind: .createEvent, undoRecordID: nil,
                undoFailure: ActionWording.undoNotRecorded))),
            ("undo-done", .actionDone(DoneChipState(title: "Added: Dentist", kind: .createEvent, undoRecordID: 1, undone: true))),
        ]
    }

    private static func historyRows() -> some View {
        let now = Date()
        let rows: [ActionRecord] = [
            ActionRecord(createdAt: now, kind: .createEvent, title: "Dentist", detail: "Oct 7, 2026 at 3:00 PM",
                         sourceText: "x", status: .completed, undoBackendID: "token"),
            ActionRecord(createdAt: now.addingTimeInterval(-60), kind: .createReminder, title: "Call Dana",
                         detail: "Oct 7, 2026 at 9:00 AM", sourceText: "x", status: .completed, undoBackendID: "token",
                         undoFailedAt: now),
            ActionRecord(createdAt: now.addingTimeInterval(-120), kind: .createReminder, title: "Oat milk",
                         sourceText: "x", status: .undone),
            ActionRecord(createdAt: now.addingTimeInterval(-180), kind: .createEvent, title: "Dentist",
                         detail: "Oct 7, 2026 at 3:00 PM", sourceText: "x", status: .failed),
            ActionRecord(createdAt: now.addingTimeInterval(-240), kind: .runShortcut, title: "Send Standup",
                         detail: "Shortcut: Send Standup", sourceText: "x", status: .uncertain),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, record in
                TimelineEntryRow(
                    entry: .action(record), isLast: index == rows.count - 1,
                    onUndo: record.status == .completed && record.undoBackendID != nil ? {} : nil)
            }
        }
    }
}


/// The Assistant's cards for the review rounds: a run History could not record, a restored card
/// for something that may already have run, a start that could not be saved, a removal History
/// could not note.
extension Snapshots {
    static func renderAssistantActionOutcomes(model: AppModel, scheme: ColorScheme, directory: URL) async {
        let assistant = model.assistant
        let reminder = ProposedAction(kind: .createReminder, title: "Send the deck", sourceText: "x")
        let shortcut = ProposedAction(
            kind: .runShortcut, title: "Send Standup", shortcutName: "Send Standup", sourceText: "x")
        let event = ProposedAction(kind: .createEvent, title: "Deck review", sourceText: "x")
        let cases: [(String, ChatActionEntry, String?)] = [
            ("not-recorded", ChatActionEntry(action: shortcut, status: .added), ActionWording.notRecorded),
            ("restored-uncertain", ChatActionEntry(action: shortcut, status: .uncertain), nil),
            ("not-started", ChatActionEntry(action: reminder), ActionWording.notStartedChatNotSaved),
            ("undone-not-recorded", ChatActionEntry(action: event, status: .undone, recordID: 3),
             ActionWording.undoNotRecorded),
        ]
        assistant.actionHandlers.isEntitled = { true }
        for (name, entry, note) in cases {
            let message = AssistantModel.Message(role: .assistant, text: "Here you go", actions: [entry])
            assistant.pinForSnapshot(installed: [.claudeCode], messages: [message])
            assistant.actionNotes = note.map { [entry.id: $0] } ?? [:]
            await capture(
                ChatActionCard(message: message).environment(model).padding(24).frame(width: 480)
                    .background(Theme.bgSunken),
                name: "t114-assistant-\(name)", scheme: scheme, size: CGSize(width: 480, height: 170),
                directory: directory, fixedSize: true)
        }
        assistant.actionNotes = [:]
    }
}
