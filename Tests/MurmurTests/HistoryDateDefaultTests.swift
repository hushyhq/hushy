import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Founder report: "History doesn't default to the current date — two dates look selected".
/// History now opens filtered to Today, and the day strip must show exactly one mark for it.
@Suite("History date default")
struct HistoryDateDefaultTests {
    private let calendar = Calendar.current

    @Test("History opens filtered to Today")
    func defaultsToToday() {
        #expect(HistoryView.defaultDateRange == .today)
    }

    @Test("the default selects exactly one strip column — today — and no separate today marker")
    func defaultSelectsOnlyToday() {
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let thursday = calendar.date(byAdding: .day, value: -3, to: today)!
        let days = HistoryDayStrip.week(
            endingOn: now, entryCounts: [today: 4, thursday: 2],
            selectedDay: HistoryView.defaultDateRange?.singleSelectedDay(now: now), now: now)
        #expect(days.filter(\.isSelected).map(\.date) == [today])
        #expect(days.filter { $0.emphasis == .selected }.count == 1)
        #expect(days.filter { $0.emphasis == .today }.isEmpty)
        #expect(days.first { $0.date == thursday }?.emphasis == .active)
    }

    @Test("tapping today's column selects the same single day as the default")
    func tappedTodayMatchesDefault() {
        let now = Date()
        let today = calendar.startOfDay(for: now)
        #expect(HistoryDateRange.custom(start: today, end: today).singleSelectedDay(now: now) == today)
        #expect(HistoryDateRange.today.singleSelectedDay(now: now) == today)
    }

    @Test("multi-day ranges and Any time select no column")
    func multiDaySelectsNothing() {
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: today)!
        #expect(HistoryDateRange.last7Days.singleSelectedDay(now: now) == nil)
        #expect(HistoryDateRange.last30Days.singleSelectedDay(now: now) == nil)
        #expect(HistoryDateRange.custom(start: weekAgo, end: today).singleSelectedDay(now: now) == nil)
    }

    @Test("yesterday selects yesterday's start of day, late in the evening too")
    func yesterdayStartOfDay() {
        let today = calendar.startOfDay(for: Date())
        let lateEvening = calendar.date(byAdding: .minute, value: 23 * 60 + 50, to: today)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        #expect(HistoryDateRange.yesterday.singleSelectedDay(now: lateEvening) == yesterday)
    }
}
