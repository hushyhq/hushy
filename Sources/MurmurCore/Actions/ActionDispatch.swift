import Foundation

/// Applies `ActionPolicy` to what the extractor proposed: one certain Tier-1 action acts now
/// and shows "Done · Undo"; anything else (Tier 2, an uncertain parse, "Ask before doing:
/// Always", or more than one action, which is itself a less certain parse) goes on the card.
/// An action that is missing something it cannot run without (an event with no start time)
/// goes on the card whatever the setting, so the card can say what is missing.
public enum ActionDispatch {
    public enum Plan: Sendable, Equatable {
        /// Execute at once; the pill shows the done chip with Undo.
        case actNow(ProposedAction)
        /// Show the confirm card with these rows.
        case card([ProposedAction])
    }

    public static func plan(
        _ actions: [ProposedAction], utterance: String, setting: ActionPolicy.AskBeforeDoing
    ) -> Plan {
        guard actions.count == 1, let action = actions.first else { return .card(actions) }
        if ActionPreflight.problem(in: action) != nil { return .card(actions) }
        let actionClass = ActionPolicy.actionClass(of: action)
        let confidence = ActionConfidence.assess(action, utterance: utterance)
        switch ActionPolicy.tier(for: actionClass, confidence: confidence, setting: setting) {
        case .actFirst: return .actNow(action)
        case .confirmFirst: return .card(actions)
        }
    }

    /// "Added: Call Dana · Fri 9:00", "Opened Gmail", "Opened in Claude — press ↩": the done chip's line.
    public static func doneTitle(for action: ProposedAction) -> String {
        switch action.kind {
        case .createReminder: return "Added: \(action.title)"
        case .createEvent: return "Added: \(action.title)"
        case .runShortcut: return "Ran: \(action.shortcutName ?? action.title)"
        case .openLink:
            if ActionPolicy.actionClass(of: action) == .aiHandoff,
               let service = AIHandoffLink.service(for: action.url) {
                return AIHandoffLink.doneChipTitle(service: service)
            }
            return "Opened: \(action.title.replacingOccurrences(of: "Open ", with: ""))"
        }
    }
}
