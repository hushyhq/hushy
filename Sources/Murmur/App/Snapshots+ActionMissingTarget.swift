import MurmurCore
import SwiftUI

/// A voice action that names a list or calendar which isn't there (`amt-*`, light and dark): the
/// pill's question with its tick, the pointer on the tick and on the pill, the calendar form, a
/// long name, the add running, the done chip it ends in, the same offer on a row of a two-action
/// card, a long calendar name (the tightest line), the pointer on ✕ after the key window, and
/// History's row before and after. `amt-sheet` is all of the pill states on one page.
/// `HUSHY_SNAPSHOT_ONLY=amt-` renders just these.
extension Snapshots {
    struct MissingTargetCase {
        let name: String
        let caption: String
        let state: PillState
        /// The one hover hint to force visible (`snapshotTooltipText`).
        var tooltip: String?
        /// Room the row needs: a hint or a card opens above the capsule.
        var height: CGFloat = 64
        /// The pointer rests on the capsule.
        var hovered = false
        /// ⏎ and esc no longer answer the pill (its key window closed).
        var keysExpired = false
    }

    static func renderActionMissingTarget(scheme: ColorScheme, directory: URL) async {
        let cases = missingTargetCases()
        for (index, item) in cases.enumerated() {
            await capture(
                missingTargetRow(item).padding(.vertical, 28).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: String(format: "amt-%02d-%@", index + 1, item.name), scheme: scheme,
                size: CGSize(width: 560, height: item.height + 56), directory: directory, fixedSize: true)
        }
        let sheet = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .bottom, spacing: 16) {
                    Text(item.caption)
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 230, alignment: .leading)
                        .padding(.bottom, 8)
                    missingTargetRow(item).frame(width: 520)
                }
                .padding(.vertical, 10)
                Divider().opacity(0.4)
            }
        }
        .padding(24)
        .background(Theme.bgSunken)
        .environment(\.colorScheme, scheme)
        let height = cases.reduce(CGFloat(48)) { $0 + $1.height + 21 }
        await capture(sheet, name: "amt-sheet", scheme: scheme, size: CGSize(width: 830, height: height),
                      directory: directory, fixedSize: true)
        await capture(
            missingTargetHistory().frame(width: 620).padding(24),
            name: "amt-history", scheme: scheme, size: CGSize(width: 680, height: 200),
            directory: directory, fixedSize: true)
    }

    private static func missingTargetRow(_ item: MissingTargetCase) -> some View {
        let pill = PillModel()
        pill.state = item.state
        pill.showWhenIdle = true
        pill.isHovered = item.hovered
        if item.keysExpired { pill.expireCardKeys() }
        return PillView(model: pill)
            .environment(\.snapshotTooltipText, item.tooltip)
            .frame(height: item.height)
    }

    private static func refused(_ action: ProposedAction, _ error: ActionExecutionError) -> ActionConfirmationCardState {
        var card = ActionConfirmationCardState(actions: [action])
        card.rows[0].refuse(error, recordID: nil)
        return card
    }

    static func missingTargetCases() -> [MissingTargetCase] {
        let start = Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
        let reminder = ProposedAction(
            kind: .createReminder, title: "Team sync", start: start, listName: "Errands", sourceText: "x")
        let event = ProposedAction(
            kind: .createEvent, title: "Dentist", start: start, end: start.addingTimeInterval(1_800),
            calendarName: "Holidays", sourceText: "x")
        let longName = ProposedAction(
            kind: .createReminder, title: "Order lanyards", listName: "Quarterly planning offsite and travel", sourceText: "x")

        let list = refused(reminder, .targetNotFound(.list, "Errands"))
        let calendar = refused(event, .targetNotFound(.calendar, "Holidays"))
        let long = refused(longName, .targetNotFound(.list, "Quarterly planning offsite and travel"))
        let longCalendar = refused(event, .targetNotFound(.calendar, "Family and friends birthdays"))
        let hint = ActionWording.useDefaultTitle(.useDefault(.list, missing: "Errands"))

        let recovered = ActionRecovery.useDefault(.list, missing: "Errands").applied(to: reminder)
        var adding = ActionConfirmationCardState(actions: [recovered])
        adding.rows[0].status = .confirming
        let chip = DoneChipState(
            title: ActionDispatch.doneTitle(for: recovered),
            detail: VoiceActionsController.detail(for: recovered, placedIn: "Reminders"), kind: .createReminder, undoRecordID: 1)

        var stacked = ActionConfirmationCardState(actions: [
            reminder, ProposedAction(kind: .createReminder, title: "Call Dana", start: start, sourceText: "x")])
        stacked.rows[0].refuse(ActionExecutionError.targetNotFound(.list, "Errands"), recordID: nil)
        stacked.rows[1].status = .succeeded(undoToken: nil)

        return [
            MissingTargetCase(name: "list-offer", caption: "List isn't there: the question and its tick", state: .actionConfirm(list)),
            MissingTargetCase(name: "list-offer-hover-tick", caption: "Pointer on ✓: what it does, and its key",
                              state: .actionConfirm(list), tooltip: hint, height: 84),
            MissingTargetCase(name: "list-offer-hover-tick-late", caption: "Pointer on ✓ after 8 seconds: no key named",
                              state: .actionConfirm(list), tooltip: hint, height: 84, keysExpired: true),
            MissingTargetCase(name: "list-offer-hover-dismiss", caption: "Pointer on ✕",
                              state: .actionConfirm(list), tooltip: "Dismiss", height: 84),
            MissingTargetCase(name: "list-offer-hover-pill", caption: "Pointer on the pill: what the tick will add",
                              state: .actionConfirm(list), height: 84, hovered: true),
            MissingTargetCase(name: "calendar-offer", caption: "Calendar isn't there", state: .actionConfirm(calendar)),
            MissingTargetCase(name: "long-name", caption: "A very long list name", state: .actionConfirm(long)),
            MissingTargetCase(name: "adding", caption: "Tick taken: adding to the default", state: .actionConfirm(adding)),
            MissingTargetCase(name: "added", caption: "Added to the default, with Undo", state: .actionDone(chip)),
            MissingTargetCase(name: "added-hover", caption: "Added, pointer on the pill: when and which list",
                              state: .actionDone(chip), height: 84, hovered: true),
            MissingTargetCase(name: "stacked-offer", caption: "Two actions, one names a list that isn't there",
                              state: .actionConfirm(stacked), height: 150),
            MissingTargetCase(name: "long-calendar-name", caption: "A very long calendar name: the question is whole",
                              state: .actionConfirm(longCalendar)),
            MissingTargetCase(name: "list-offer-hover-dismiss-late", caption: "Pointer on ✕ after 8 seconds: no key named",
                              state: .actionConfirm(list), tooltip: "Dismiss", height: 84, keysExpired: true),
        ]
    }

    /// History for one request: the refused attempt when the question was dismissed, and the same
    /// row once the tick was taken (it names the list the reminder landed in).
    private static func missingTargetHistory() -> some View {
        let now = Date()
        let rows: [ActionRecord] = [
            ActionRecord(createdAt: now, kind: .createReminder, title: "Team sync",
                         detail: "Oct 12, 2026 at 11:00 AM \u{00B7} Reminders", sourceText: "x", status: .completed,
                         undoBackendID: "token"),
            ActionRecord(createdAt: now.addingTimeInterval(-300), kind: .createReminder, title: "Team sync",
                         detail: "Oct 12, 2026 at 11:00 AM", sourceText: "", status: .failed),
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
