import Foundation
import Testing
@testable import MurmurCore

@Suite("HistoryDayStrip")
struct HistoryDayStripTests {
    private var calendar: Calendar { Calendar.current }

    @Test("week has exactly 7 days ending on the given day")
    func weekHasSevenDays() {
        let today = calendar.startOfDay(for: Date())
        let days = HistoryDayStrip.week(endingOn: today, entryCounts: [:])
        #expect(days.count == 7)
        #expect(calendar.isDate(days.last!.date, inSameDayAs: today))
    }

    @Test("a day with entries but no attention shows hasEntries dot")
    func hasEntriesDot() {
        let today = calendar.startOfDay(for: Date())
        let days = HistoryDayStrip.week(endingOn: today, entryCounts: [today: 3])
        #expect(days.last?.dot == .hasEntries)
    }

    @Test("a day with a needs-attention item shows the needsAttention dot even if it also has entries")
    func needsAttentionDotWins() {
        let today = calendar.startOfDay(for: Date())
        let days = HistoryDayStrip.week(endingOn: today, entryCounts: [today: 3], attentionCounts: [today: 1])
        #expect(days.last?.dot == .needsAttention)
    }

    @Test("a day with nothing is dimmed")
    func emptyDayIsDimmed() {
        let today = calendar.startOfDay(for: Date())
        let days = HistoryDayStrip.week(endingOn: today, entryCounts: [:])
        #expect(days.allSatisfy { $0.isDimmed })
    }

    @Test("the selected day is marked selected")
    func selectedDayMarked() {
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let days = HistoryDayStrip.week(endingOn: today, entryCounts: [:], selectedDay: yesterday)
        #expect(days.first { $0.isSelected }?.date == yesterday)
    }

    @Test("today is marked isToday")
    func todayMarked() {
        let today = calendar.startOfDay(for: Date())
        let days = HistoryDayStrip.week(endingOn: today, entryCounts: [:])
        #expect(days.last?.isToday == true)
        #expect(days.dropLast().allSatisfy { day in !day.isToday })
    }

    @Test("days with dictations are active, not selected, when there's no date filter")
    func activeDaysAreNotSelected() {
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let days = HistoryDayStrip.week(endingOn: today, entryCounts: [today: 3, yesterday: 2], attentionCounts: [yesterday: 1])
        #expect(days.filter { $0.emphasis == .selected }.isEmpty)
        #expect(days.filter { $0.emphasis == .active }.map(\.date) == [yesterday])
        #expect(days.last?.emphasis == .today)
        #expect(days.filter { $0.emphasis == .empty }.count == 5)
    }

    @Test("only the selected day gets the selected emphasis, even among days with dictations")
    func onlySelectedDayIsSelected() {
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let days = HistoryDayStrip.week(endingOn: today, entryCounts: [today: 3, yesterday: 2], selectedDay: yesterday)
        #expect(days.filter { $0.emphasis == .selected }.map(\.date) == [yesterday])
        #expect(days.last?.emphasis == .today)
    }

    @Test("an empty day that is selected still reads as selected")
    func selectedEmptyDay() {
        let today = calendar.startOfDay(for: Date())
        let days = HistoryDayStrip.week(endingOn: today, entryCounts: [:], selectedDay: today)
        #expect(days.last?.emphasis == .selected)
    }

    // Founder report: "History doesn't default to the current date — two dates look selected".
    // No day was ever `.selected` on open; every day with dictations was drawn in primary text,
    // so two active days (e.g. today + Thursday) looked like two selections. On open there must
    // be no selected day and exactly one emphasized day: today.
    @Test("on open (no date filter) nothing is selected and only today is emphasized, however many days have dictations")
    func openingHistoryEmphasizesOnlyToday() {
        let today = calendar.startOfDay(for: Date())
        var counts: [Date: Int] = [:]
        for offset in 0..<7 { counts[calendar.date(byAdding: .day, value: -offset, to: today)!] = 2 }
        let days = HistoryDayStrip.week(endingOn: Date(), entryCounts: counts, selectedDay: nil)
        #expect(days.filter { $0.emphasis == .selected }.isEmpty)
        #expect(days.filter { $0.emphasis == .today }.map(\.date) == [today])
        #expect(days.filter { $0.emphasis == .active }.count == 6)
    }

    @Test("filtering to today makes it the single selected day, with no separate today marker")
    func selectingTodayIsOneMark() {
        let today = calendar.startOfDay(for: Date())
        let days = HistoryDayStrip.week(endingOn: Date(), entryCounts: [today: 1], selectedDay: today)
        #expect(days.filter { $0.emphasis == .selected }.map(\.date) == [today])
        #expect(days.filter { $0.emphasis == .today }.isEmpty)
    }

    @Test("selection and today match by calendar day, not by exact instant, in a non-UTC time zone")
    func dayMatchingIgnoresTimeOfDay() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 23:30 Tokyo time — a different UTC date than the local day.
        let now = tokyo.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 23, minute: 30))!
        let yesterdayEvening = tokyo.date(byAdding: .hour, value: -26, to: now)!  // 21:30 on the 26th
        let days = HistoryDayStrip.week(
            endingOn: now, entryCounts: [:], selectedDay: yesterdayEvening, calendar: tokyo, now: now)
        #expect(days.filter(\.isSelected).count == 1)
        #expect(days.filter(\.isToday).count == 1)
        #expect(tokyo.component(.day, from: days.first { $0.isSelected }!.date) == 27 - 1)
        #expect(tokyo.component(.day, from: days.first { $0.isToday }!.date) == 27)
    }
}
