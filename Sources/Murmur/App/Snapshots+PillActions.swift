import MurmurCore
import SwiftUI

/// The pill's voice-action confirmation in both layouts (UI round 2026-09-28 §1, A2): one action
/// is the pill itself (`pill-actionConfirm-single`); two or three are rows stacked on the capsule
/// (`pill-actionConfirm-stacked`, 2 pending + 1 added; `pill-actionConfirm-stacked-3`, 3 pending).
extension Snapshots {
    static func renderPillActions(scheme: ColorScheme, directory: URL) async {
        let actions = sampleActions()
        var stacked = ActionConfirmationCardState(actions: actions)
        stacked.rows[2].status = .succeeded(undoToken: nil)
        let cards: [(String, ActionConfirmationCardState)] = [
            ("pill-actionConfirm-single", ActionConfirmationCardState(actions: [actions[0]])),
            ("pill-actionConfirm-stacked", stacked),
            ("pill-actionConfirm-stacked-3", ActionConfirmationCardState(actions: actions)),
        ]
        for (name, card) in cards {
            let pill = PillModel()
            pill.state = .actionConfirm(card)
            await captureCard(pill, name: name, scheme: scheme, directory: directory)
        }
        // After the 8 s ⏎ window: "Confirm all · esc none" — esc still clears a lingering card.
        let expired = PillModel()
        expired.state = .actionConfirm(ActionConfirmationCardState(actions: actions))
        expired.expireCardKeys()
        await captureCard(expired, name: "pill-actionConfirm-stacked-3-expired", scheme: scheme, directory: directory)
    }

    private static func captureCard(_ pill: PillModel, name: String, scheme: ColorScheme, directory: URL) async {
        let view = PillView(model: pill)
            .padding(40)
            .background(Theme.bgSunken)
            .environment(\.colorScheme, scheme)
        await capture(view, name: name, scheme: scheme, size: CGSize(width: 560, height: 360),
                      directory: directory, fixedSize: true)
    }

    private static func sampleActions() -> [ProposedAction] {
        let tomorrow3pm = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0,
                                                of: Date().addingTimeInterval(86_400)) ?? Date()
        return [
            ProposedAction(kind: .createEvent, title: "Dentist", start: tomorrow3pm,
                           end: tomorrow3pm.addingTimeInterval(3600), sourceText: "dentist tomorrow at three"),
            ProposedAction(kind: .createReminder, title: "Send Priya the deck", start: tomorrow3pm,
                           sourceText: "remind me to send priya the deck"),
            ProposedAction(kind: .createReminder, title: "Buy oat milk", sourceText: "add oat milk"),
        ]
    }
}
