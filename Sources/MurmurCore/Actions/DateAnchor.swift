import Foundation

/// A date/time (and optional end/duration) resolved from a spoken phrase, plus the exact
/// substring it came from — kept together so the confirmation card can show both the resolved
/// value and, on hover, "tomorrow" → "Sat, Sep 27" (voice-actions.md §4.1's trust pattern).
public struct AnchoredDate: Sendable, Equatable {
    public let start: Date
    public let end: Date?
    public let sourcePhrase: String
    public let hasExplicitTimeZone: Bool

    public init(start: Date, end: Date?, sourcePhrase: String, hasExplicitTimeZone: Bool = false) {
        self.start = start
        self.end = end
        self.sourcePhrase = sourcePhrase
        self.hasExplicitTimeZone = hasExplicitTimeZone
    }
}

/// Resolves the date/time phrase in a transcript (or in the model's copied `when` phrase)
/// deterministically, before and instead of asking the model to compute dates
/// (docs/research/voice-actions.md §4.3).
///
/// Two stages, both against an injected `DateContext` (never the wall clock):
/// 1. `RelativeDateParser` — the spoken forms voice commands use: "in 3 hours", "at 4 15",
///    "on the 10th", "by eod", "day after tomorrow", "evening 7", "12/10" (day-first in en_IN),
///    weekdays, month names, ranges ("2 to 3 pm").
/// 2. `NSDataDetector`, for anything the parser doesn't know — but only when the matched text
///    names an absolute date (a month name or a year). The detector always resolves
///    relative words against the real clock; the old code shifted its answer by
///    (context now − real now), which put weekday phrases on the wrong day whenever the two
///    fell on different weekdays. Relative detector matches are therefore dropped.
public enum DateAnchor {
    /// Default event duration when the speaker gave no end time or duration
    /// (voice-actions.md's MVP scope: "default durations 30 min").
    public static let defaultDurationSeconds: TimeInterval = 30 * 60

    /// Finds the first date/time phrase in `text` and resolves it in `context` (its clock, time
    /// zone — "never silently assume UTC" — and locale).
    public static func firstDate(in text: String, context: DateContext) -> AnchoredDate? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let parsed = RelativeDateParser.parse(text, context: context) {
            return AnchoredDate(
                start: parsed.start, end: parsed.end ?? parsed.start.addingTimeInterval(defaultDurationSeconds),
                sourcePhrase: parsed.sourcePhrase)
        }
        return detectedAbsoluteDate(in: text, context: context)
    }

    /// `NSDataDetector`'s first match that names an absolute date, rebuilt in `context`.
    static func detectedAbsoluteDate(in text: String, context: DateContext) -> AnchoredDate? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let detected = match.date, let swiftRange = Range(match.range, in: text) else { continue }
            let phrase = String(text[swiftRange])
            let words = SpokenDateLexicon.tokens(in: phrase).map(\.text)
            let year = words.compactMap { $0.count == 4 ? Int($0) : nil }.first { (2000...2100).contains($0) }
            // Numeric dates ("12/10") are the parser's job, with its locale and "24/7" guards.
            let namesDate = year != nil || words.contains { SpokenDateLexicon.months[$0] != nil }
            guard namesDate else { continue }
            let duration = match.duration > 0 ? match.duration : defaultDurationSeconds
            if match.timeZone != nil {
                return AnchoredDate(start: detected, end: detected.addingTimeInterval(duration), sourcePhrase: phrase, hasExplicitTimeZone: true)
            }
            // The detector read wall-clock values in the system zone; rebuild them in the context's.
            var systemCalendar = Calendar(identifier: .gregorian)
            systemCalendar.timeZone = .current
            let wall = systemCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: detected)
            guard let month = wall.month, let day = wall.day,
                  let dayStart = RelativeDateResolver.day(
                    .monthDay(month: month, day: day, year: year), today: context.calendar.startOfDay(for: context.now), context: context),
                  let start = RelativeDateResolver.at(dayStart, hour: wall.hour ?? 9, minute: wall.minute ?? 0, context.calendar)
            else { continue }
            return AnchoredDate(start: start, end: start.addingTimeInterval(duration), sourcePhrase: phrase)
        }
        return nil
    }
}
