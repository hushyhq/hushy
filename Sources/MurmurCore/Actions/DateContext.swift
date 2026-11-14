import Foundation

/// The clock, time zone and locale every spoken-date function resolves against.
///
/// Injected everywhere instead of reading `Date()` inside the date code, so a test or an eval
/// case with a fixed "now" gets exactly what the app would get at that moment — the old
/// `DateAnchor` shifted `NSDataDetector` results by (fixed now − real now), which put weekday
/// phrases on the wrong day whenever the two fell on different weekdays. `current()` is the one
/// place the real clock is read, at the app boundary.
public struct DateContext: Sendable, Equatable {
    public let now: Date
    public let timeZone: TimeZone
    public let locale: Locale

    public init(now: Date, timeZone: TimeZone, locale: Locale = Locale(identifier: "en_US")) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
    }

    /// The real clock, system time zone and locale. Only call sites that act for the user right
    /// now (the pill's voice-action flow, the golden-set runner) use this.
    public static func current() -> DateContext {
        DateContext(now: Date(), timeZone: .current, locale: .current)
    }

    /// Gregorian, in `timeZone` — so day arithmetic follows that zone's DST rules.
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    /// Whether a numeric date like "12/10" is day-first in this locale (en_IN, en_GB: 12 Oct;
    /// en_US: Dec 10). Read from the locale's own short-date pattern, not a hard-coded list.
    public var prefersDayFirst: Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "dM", options: 0, locale: locale) ?? "M/d"
        guard let day = pattern.firstIndex(of: "d"), let month = pattern.firstIndex(of: "M") else { return false }
        return day < month
    }
}
