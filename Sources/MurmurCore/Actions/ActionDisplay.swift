import Foundation

/// The words a card and the done chip use for an action's time, so a value Hushy filled in (an
/// event's 30-minute length, a start of 9 a.m. for a named day) is always on screen. Compact: the
/// year appears only when it isn't the current one. History keeps its own, unchanged detail line.
public enum ActionDisplay {
    /// "Oct 7, 3:00 PM": a reminder's due time, or an event's start.
    public static func startText(
        _ start: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        let calendar = Self.calendar(timeZone)
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
        return format(sameYear ? "MMMd, jmm" : "MMMd, y, jmm", start, locale, timeZone)
    }

    /// An event's time with its length: "Oct 7, 3:00 PM – 3:30 PM" on one day, both full ends when
    /// it spans days. With no end it is the start alone.
    public static func eventText(
        start: Date, end: Date?, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        let startText = startText(start, now: now, locale: locale, timeZone: timeZone)
        guard let end, end > start else { return startText }
        if calendar(timeZone).isDate(start, inSameDayAs: end) {
            return "\(startText) \u{2013} \(format("jmm", end, locale, timeZone))"
        }
        return "\(startText) \u{2013} \(Self.startText(end, now: now, locale: locale, timeZone: timeZone))"
    }

    /// The line for a proposed or finished action's time: an event shows its length, a reminder
    /// its due time, anything else nothing.
    public static func whenText(
        for action: ProposedAction, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String? {
        guard let start = action.start else { return nil }
        switch action.kind {
        case .createEvent: return eventText(start: start, end: action.end, now: now, locale: locale, timeZone: timeZone)
        case .createReminder: return startText(start, now: now, locale: locale, timeZone: timeZone)
        case .runShortcut, .openLink: return nil
        }
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func format(_ template: String, _ date: Date, _ locale: Locale, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
