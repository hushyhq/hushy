import Foundation

/// One day column in History's header week/date strip: a weekday letter over a date number,
/// with a dot to say whether that day has dictations (grey) or needs-attention items (red).
public struct DayStripEntry: Identifiable, Equatable, Sendable {
    public enum Dot: Equatable, Sendable {
        case none
        case hasEntries
        case needsAttention
    }

    public let date: Date
    public let weekdayLetter: String
    public let dayNumber: Int
    public let dot: Dot
    public let isSelected: Bool
    public let isToday: Bool
    /// Dimmed when nothing was dictated that day — still tappable to filter to an empty day.
    public var isDimmed: Bool { dot == .none }

    /// How a day column is drawn. Exactly one visual state per day, so nothing but the filter
    /// can read as "selected":
    /// - `.selected`: the filtered-to day (a filled accent circle) — at most one, and none with
    ///   no date filter (History opens on "All dates", newest first, so today is on top anyway).
    /// - `.today`: today when it isn't the filter — accent-coloured number, *no* fill, so the
    ///   "you are here" marker never looks like a second selection.
    /// - `.active`: other days with dictations — secondary text plus a dot. Deliberately quieter
    ///   than today: when these used primary text, a week with dictations on two days opened
    ///   with two equally dark numbers that read as two selected dates.
    /// - `.empty`: dimmed.
    public enum Emphasis: Equatable, Sendable {
        case selected
        case today
        case active
        case empty
    }

    public var emphasis: Emphasis {
        if isSelected { return .selected }
        if isToday { return .today }
        return dot == .none ? .empty : .active
    }

    public var id: Date { date }

    public init(date: Date, weekdayLetter: String, dayNumber: Int, dot: Dot, isSelected: Bool, isToday: Bool) {
        self.date = date
        self.weekdayLetter = weekdayLetter
        self.dayNumber = dayNumber
        self.dot = dot
        self.isSelected = isSelected
        self.isToday = isToday
    }
}

/// Pure builder for History's day strip: given a week window and per-day activity counts,
/// produces the row of `DayStripEntry` the header renders. Kept free of SwiftUI/Store so it's
/// unit-testable and reusable if the window size ever changes.
public enum HistoryDayStrip {
    /// Builds a 7-day strip ending on `endingOn` (inclusive), oldest-to-newest (left-to-right,
    /// matching a calendar week read order).
    ///
    /// - Parameters:
    ///   - entryCounts: dictation count per calendar day (`Calendar.startOfDay` keys).
    ///   - attentionCounts: needs-attention count per calendar day, same keying.
    ///   - selectedDay: the day currently filtered to, if any (matched by calendar day).
    public static func week(
        endingOn: Date, entryCounts: [Date: Int], attentionCounts: [Date: Int] = [:],
        selectedDay: Date? = nil, calendar: Calendar = .current, now: Date = Date()
    ) -> [DayStripEntry] {
        let endOfWeek = calendar.startOfDay(for: endingOn)
        let today = calendar.startOfDay(for: now)
        let selectedStart = selectedDay.map { calendar.startOfDay(for: $0) }
        return (0..<7).reversed().compactMap { offset -> DayStripEntry? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endOfWeek) else { return nil }
            let hasAttention = (attentionCounts[day] ?? 0) > 0
            let hasEntries = (entryCounts[day] ?? 0) > 0
            let dot: DayStripEntry.Dot = hasAttention ? .needsAttention : (hasEntries ? .hasEntries : .none)
            return DayStripEntry(
                date: day,
                weekdayLetter: String(day.formatted(.dateTime.weekday(.narrow))),
                dayNumber: calendar.component(.day, from: day),
                dot: dot,
                isSelected: selectedStart.map { calendar.isDate($0, inSameDayAs: day) } ?? false,
                isToday: calendar.isDate(day, inSameDayAs: today))
        }
    }

    /// The month label shown once above the strip (e.g. "September") — the month the *majority*
    /// of the strip's days fall in, so a week spanning a month boundary still reads sensibly.
    public static func monthLabel(for days: [DayStripEntry], calendar: Calendar = .current) -> String {
        guard let midpoint = days[safe: days.count / 2] ?? days.last else { return "" }
        return midpoint.date.formatted(.dateTime.month(.wide))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
