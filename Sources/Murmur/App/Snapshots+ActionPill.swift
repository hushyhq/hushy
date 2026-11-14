import MurmurCore
import SwiftUI

/// The voice-action pill's review set (`vap-*`, light and dark): every state a voice action can put
/// the pill in, beside dictation's hands-free pill, so the two can be compared as one object.
/// `vap-sheet` is all of them on one page; `vap-<nn>-<name>` is each one alone at real size.
/// `HUSHY_SNAPSHOT_ONLY=vap-` renders just these.
extension Snapshots {
    struct ActionPillCase {
        let name: String
        /// What the row is, in the founder's words.
        let caption: String
        let state: PillState
        var cancelKey: String?
        /// The one hover hint to force visible (`snapshotTooltipText`).
        var tooltip: String?
        /// Room the row needs: a hint or a card opens above the capsule.
        var height: CGFloat = 64
        /// fn + control is held (no buttons), rather than latched.
        var chordHeld = false
        /// The pointer rests on the capsule: a compact row shows what it left out.
        var hovered = false
        /// How long "working" has lasted, for the label that arrives late.
        var workingFor: TimeInterval = 0
        /// A dictation whose headset is still connecting: the cue in place of the bars.
        var inputCue: PillModel.InputCue = .hearing
    }

    static func renderActionPill(scheme: ColorScheme, directory: URL) async {
        let cases = actionPillCases()
        for (index, item) in cases.enumerated() {
            await capture(
                actionPillRow(item).padding(.vertical, 28).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: String(format: "vap-%02d-%@", index + 1, item.name), scheme: scheme,
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
                    actionPillRow(item).frame(width: 520)
                }
                .padding(.vertical, 10)
                Divider().opacity(0.4)
            }
        }
        .padding(24)
        .background(Theme.bgSunken)
        .environment(\.colorScheme, scheme)
        let height = cases.reduce(CGFloat(48)) { $0 + $1.height + 21 }
        await capture(sheet, name: "vap-sheet", scheme: scheme, size: CGSize(width: 830, height: height),
                      directory: directory, fixedSize: true)
    }

    private static func actionPillRow(_ item: ActionPillCase) -> some View {
        let pill = PillModel()
        pill.state = item.state
        pill.showWhenIdle = true
        pill.actionCancelKey = item.cancelKey
        pill.actionChordHeld = item.chordHeld
        pill.isHovered = item.hovered
        pill.inputCue = item.inputCue
        pill.setLevels([0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55])
        return PillView(model: pill)
            .environment(\.snapshotTooltipText, item.tooltip)
            .environment(\.snapshotWritingElapsed, item.workingFor)
            .frame(height: item.height)
    }

    static func actionPillCases() -> [ActionPillCase] {
        let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
        let event = ProposedAction(
            kind: .createEvent, title: "Dentist", start: start, end: start.addingTimeInterval(1800), sourceText: "x")
        let reminder = ProposedAction(kind: .createReminder, title: "Call Dana about the lease renewal", start: start, sourceText: "x")
        let list = ProposedAction(kind: .createReminder, title: "Oat milk", listName: "Errands", sourceText: "add oat milk to errands")

        let eventChip = DoneChipState(
            title: ActionDispatch.doneTitle(for: event),
            detail: VoiceActionsController.detail(for: event, placedIn: "Home"), kind: .createEvent, undoRecordID: 1)
        let longChip = DoneChipState(
            title: ActionDispatch.doneTitle(for: reminder),
            detail: VoiceActionsController.detail(for: reminder, placedIn: "Reminders"), kind: .createReminder, undoRecordID: 2)
        var undoing = eventChip
        undoing.isUndoing = true
        var undoFailed = eventChip
        undoFailed.undoFailure = ActionWording.undoFailed(for: .createEvent)
        var undone = eventChip
        undone.undone = true

        var needsAccess = ActionConfirmationCardState(actions: [list])
        needsAccess.rows[0].status = .failed("Reminders access needed")
        var listMissing = ActionConfirmationCardState(actions: [list])
        listMissing.rows[0].status = .blocked(ActionWording.targetNotFound(.list, "Errands"))

        let stacked = ActionConfirmationCardState(actions: [
            event, ProposedAction(kind: .createReminder, title: "Call Dana", start: start, sourceText: "x")])
        let choice = ActionConfirmationCardState(
            choosingAmong: ["Slack", "Flush", "Notion"], heard: "flask", sourceText: "open flask")
        var uncertain = ActionConfirmationCardState(actions: [
            ProposedAction(kind: .runShortcut, title: "Send Standup", shortcutName: "Send Standup", sourceText: "x")])
        uncertain.rows[0].status = .uncertain(ActionWording.mayHaveRun(.timedOut))

        return [
            ActionPillCase(name: "dictation-handsfree", caption: "Dictation, hands-free (for comparison)",
                           state: .handsFree(startedAt: Date().addingTimeInterval(-42))),
            ActionPillCase(name: "dictation-listening", caption: "Dictation, key held (for comparison)", state: .listening),
            ActionPillCase(name: "dictation-connecting", caption: "Dictation, key held, the headset's microphone is still connecting",
                           state: .listening, inputCue: .connectingHeadset),
            ActionPillCase(name: "dictation-handsfree-connecting", caption: "Dictation, hands-free, the headset is still connecting",
                           state: .handsFree(startedAt: Date().addingTimeInterval(-1)), inputCue: .connectingHeadset),
            ActionPillCase(name: "listening-handsfree", caption: "Action, hands-free (action key twice)",
                           state: .actionListening, cancelKey: "control"),
            ActionPillCase(name: "listening-handsfree-hover-cancel", caption: "Hands-free, pointer on ✕",
                           state: .actionListening, cancelKey: "control", tooltip: "Cancel", height: 84),
            ActionPillCase(name: "listening-handsfree-hover-send", caption: "Hands-free, pointer on ✓",
                           state: .actionListening, cancelKey: "control", tooltip: PillHint.runAction.title, height: 84),
            ActionPillCase(name: "listening-clicked", caption: "Action, started from the pill's ⚡ button",
                           state: .actionListening),
            ActionPillCase(name: "listening-held", caption: "Action, fn + control held (let go to send)",
                           state: .actionListening, chordHeld: true),
            ActionPillCase(name: "processing", caption: "Working on the command", state: .actionProcessing),
            ActionPillCase(name: "processing-hover-cancel", caption: "Working, pointer on ✕",
                           state: .actionProcessing, tooltip: "Cancel", height: 84),
            ActionPillCase(name: "processing-slow", caption: "Working, after 5 seconds",
                           state: .actionProcessing, workingFor: 6),
            ActionPillCase(name: "done-event", caption: "Done: an event, with Undo", state: .actionDone(eventChip)),
            ActionPillCase(name: "done-event-hover", caption: "Done, pointer on the pill: when and where",
                           state: .actionDone(eventChip), height: 84, hovered: true),
            ActionPillCase(name: "done-long-title", caption: "Done: a long reminder title", state: .actionDone(longChip)),
            ActionPillCase(name: "done-opened", caption: "Done: an app opened (nothing to undo)",
                           state: .actionDone(DoneChipState(title: "Opened: Chrome", kind: .openLink))),
            ActionPillCase(name: "undoing", caption: "Undo running", state: .actionDone(undoing)),
            ActionPillCase(name: "undone", caption: "Undone", state: .actionDone(undone)),
            ActionPillCase(name: "undo-failed", caption: "Undo failed", state: .actionDone(undoFailed)),
            ActionPillCase(name: "needs-access", caption: "Needs access (Retry)", state: .actionConfirm(needsAccess)),
            ActionPillCase(name: "needs-access-hover", caption: "Needs access, pointer on the pill: which action",
                           state: .actionConfirm(needsAccess), height: 84, hovered: true),
            ActionPillCase(name: "not-found", caption: "List not found (no Retry)", state: .actionConfirm(listMissing)),
            ActionPillCase(name: "uncertain", caption: "May have run (no Retry)", state: .actionConfirm(uncertain)),
            ActionPillCase(name: "stopped", caption: "Hands-free ran out (20 s)", state: .error("Stopped listening")),
            ActionPillCase(name: "confirm", caption: "Asks first: one action (not changed)",
                           state: .actionConfirm(ActionConfirmationCardState(actions: [event]))),
            ActionPillCase(name: "confirm-stacked", caption: "Asks first: two actions", state: .actionConfirm(stacked),
                           height: 150),
            ActionPillCase(name: "confirm-stacked-hover-confirm", caption: "Two actions, pointer on ✓",
                           state: .actionConfirm(stacked), tooltip: "Confirm all", height: 150),
            ActionPillCase(name: "app-choice", caption: "Did you mean… (app not found)", state: .actionConfirm(choice),
                           height: 190),
            ActionPillCase(name: "app-choice-hover-dismiss", caption: "Did you mean…, pointer on ✕",
                           state: .actionConfirm(choice), tooltip: "Dismiss all", height: 190),
        ]
    }
}
