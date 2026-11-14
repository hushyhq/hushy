import Foundation

/// The one plain line History shows for a voice action, from what the record already stores
/// (kind, title, detail, status). Nothing about why a failure happened is stored or shown: a
/// reason can carry a calendar, app or Shortcut name the person never saw on a card.
public enum ActionRecordLine {
    /// "Added “Dentist” to Calendar · Oct 7, 2026 at 3:00 PM", "Couldn’t add “Dentist” to Calendar",
    /// "“Start Focus” may have run. Hushy can’t tell."
    public static func text(for record: ActionRecord) -> String {
        switch record.status {
        case .completed: completedLine(record)
        case .undone: "Undone: \(completedLine(record))"
        case .failed: failedLine(record)
        case .uncertain: "\u{201C}\(record.title)\u{201D} may have run. Hushy can't tell."
        }
    }

    /// The second line under a completed action whose Undo failed, or nil.
    public static func undoNote(for record: ActionRecord) -> String? {
        guard record.status == .completed, record.undoFailedAt != nil else { return nil }
        switch record.kind {
        case .createEvent: return "Couldn't undo. It's still in Calendar."
        case .createReminder: return "Couldn't undo. It's still in Reminders."
        case .runShortcut, .openLink: return nil
        }
    }

    private static func completedLine(_ record: ActionRecord) -> String {
        switch record.kind {
        case .createEvent:
            return line(verb: "Added", title: record.title, destination: "to Calendar", detail: record.detail)
        case .createReminder:
            return line(verb: "Added", title: record.title, destination: "to Reminders", detail: record.detail)
        case .runShortcut:
            return line(verb: "Ran", title: record.title, destination: "shortcut", detail: record.detail)
        case .openLink:
            if AIHandoffLink.isHandoffDoneChipTitle(record.title) {
                return handoffLine(title: record.title, detail: record.detail)
            }
            return line(verb: "Opened", title: record.title, destination: "", detail: record.detail)
        }
    }

    private static func handoffLine(title: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return title }
        return "\(title) \u{00B7} \(detail)"
    }

    private static func failedLine(_ record: ActionRecord) -> String {
        switch record.kind {
        case .createEvent: line(verb: "Couldn't add", title: record.title, destination: "to Calendar", detail: record.detail)
        case .createReminder: line(verb: "Couldn't add", title: record.title, destination: "to Reminders", detail: record.detail)
        case .runShortcut: "Couldn't run shortcut \u{201C}\(record.title)\u{201D}"
        case .openLink: line(verb: "Couldn't open", title: openedName(record.title), destination: "", detail: record.detail)
        }
    }

    /// "Open Chrome" is the card's title; the name alone reads right after "Couldn’t open".
    private static func openedName(_ title: String) -> String {
        title.lowercased().hasPrefix("open ") ? String(title.dropFirst(5)) : title
    }

    private static func line(verb: String, title: String, destination: String, detail: String?) -> String {
        let base = destination.isEmpty
            ? "\(verb) \u{201C}\(title)\u{201D}" : "\(verb) \u{201C}\(title)\u{201D} \(destination)"
        guard let detail, !detail.isEmpty else { return base }
        return "\(base) \u{00B7} \(detail)"
    }
}
