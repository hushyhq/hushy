import Foundation
import Testing
@testable import MurmurCore

@Suite("Home timeline selection")
struct HomeTimelineSelectionTests {
    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private let la = HomeTimelineSelectionTests.calendar("America/Los_Angeles")

    /// Monday 2026-10-05, 12:30 in the given calendar's zone.
    private func noon(_ calendar: Calendar) -> Date { at(calendar, 2026, 10, 5, 12, 30) }

    private func at(_ calendar: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        let parts = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        return parts.date ?? Date(timeIntervalSince1970: 0)
    }

    private func dictation(_ id: Int64, _ date: Date) -> Dictation {
        Dictation(id: id, createdAt: date, rawText: "d\(id)", text: "D\(id).", appBundleID: "com.a", appName: "A", durationSeconds: 2)
    }

    private func note(_ id: Int64, _ date: Date) -> Note {
        Note(id: id, title: "N\(id)", createdAt: date, updatedAt: date, status: .ready)
    }

    private func action(_ id: Int64, _ date: Date) -> ActionRecord {
        ActionRecord(id: id, createdAt: date, kind: .createEvent, title: "T\(id)", sourceText: "s")
    }

    /// `count` dictations spaced a minute apart, the newest at `latest`, ids `firstID...`.
    private func dictations(_ count: Int, latest: Date, firstID: Int64 = 1) -> [Dictation] {
        (0..<count).map { dictation(firstID + Int64($0), latest.addingTimeInterval(-60 * Double($0))) }
    }

    private func select(
        _ dictations: [Dictation] = [], notes: [Note] = [], actions: [ActionRecord] = [],
        now: Date? = nil, calendar: Calendar? = nil, cap: Int = HomeTimeline.dictationCap
    ) -> HomeTimelineSelection {
        let calendar = calendar ?? la
        return HomeTimeline.select(
            dictations: dictations, notes: notes, actions: actions, now: now ?? noon(calendar), calendar: calendar, cap: cap)
    }

    // MARK: - Cap

    @Test("the cap is eight")
    func capConstant() {
        #expect(HomeTimeline.dictationCap == 8)
    }

    @Test("an empty library selects nothing")
    func emptyLibrary() {
        let selection = select()
        #expect(selection.today.all.isEmpty)
        #expect(selection.today.hiddenDictationCount == 0)
        #expect(selection.earlier == nil)
    }

    @Test("a handful of dictations are all visible")
    func underCap() {
        let selection = select(dictations(3, latest: at(la, 2026, 10, 5, 9, 0)))
        #expect(selection.today.capped.count == 3)
        #expect(selection.today.hiddenDictationCount == 0)
    }

    @Test("cap exactly met hides nothing")
    func capExactlyMet() {
        let selection = select(dictations(8, latest: at(la, 2026, 10, 5, 9, 0)))
        #expect(selection.today.capped.count == 8)
        #expect(selection.today.hiddenDictationCount == 0)
    }

    @Test("cap exceeded by one hides exactly the oldest dictation")
    func capExceededByOne() {
        let items = dictations(9, latest: at(la, 2026, 10, 5, 9, 0))
        let selection = select(items)
        #expect(selection.today.capped.count == 8)
        #expect(selection.today.hiddenDictationCount == 1)
        #expect(selection.today.all.count == 9)
        #expect(!selection.today.capped.contains { $0.id == "d9" })
        #expect(selection.today.capped.contains { $0.id == "d1" })
    }

    @Test("twenty-five dictations are all reachable (no silent twenty limit)")
    func nothingDropped() {
        let selection = select(dictations(25, latest: at(la, 2026, 10, 5, 11, 0)))
        #expect(selection.today.dictationCount == 25)
        #expect(selection.today.all.count == 25)
        #expect(selection.today.hiddenDictationCount == 17)
    }

    @Test("voice actions and notes are never hidden")
    func actionsAndNotesAlwaysShown() {
        let morning = at(la, 2026, 10, 5, 7, 0)
        let selection = select(
            dictations(20, latest: at(la, 2026, 10, 5, 11, 0)),
            notes: [note(1, morning), note(2, morning.addingTimeInterval(60))],
            actions: [action(1, morning), action(2, morning.addingTimeInterval(30)), action(3, morning.addingTimeInterval(90))])
        let ids = Set(selection.today.capped.map(\.id))
        #expect(["n1", "n2", "a1", "a2", "a3"].allSatisfy(ids.contains))
        #expect(selection.today.capped.count == 8 + 5)
        #expect(selection.today.hiddenDictationCount == 12)
        #expect(selection.today.noteCount == 2)
        #expect(selection.today.actionCount == 3)
    }

    @Test("entries come newest first")
    func newestFirst() {
        let selection = select(
            dictations(2, latest: at(la, 2026, 10, 5, 9, 0)),
            actions: [action(1, at(la, 2026, 10, 5, 10, 0))])
        #expect(selection.today.all.map(\.id) == ["a1", "d1", "d2"])
    }

    // MARK: - Day boundaries

    @Test("one second before midnight is yesterday, midnight is today")
    func midnightBoundary() {
        let lastSecond = dictation(1, at(la, 2026, 10, 4, 23, 59, 59))
        let firstSecond = dictation(2, at(la, 2026, 10, 5, 0, 0, 0))
        let selection = select([lastSecond, firstSecond])
        #expect(selection.today.all.map(\.id) == ["d2"])
        #expect(selection.earlier?.all.map(\.id) == ["d1"])
    }

    @Test("just after midnight today is empty and yesterday is the earlier day")
    func justAfterMidnight() {
        let now = at(la, 2026, 10, 5, 0, 0, 30)
        let selection = select(dictations(3, latest: at(la, 2026, 10, 4, 19, 33)), now: now)
        #expect(selection.today.all.isEmpty)
        #expect(selection.earlier?.dictationCount == 3)
        #expect(selection.earlier?.label == "Yesterday")
    }

    @Test("the same instants split differently under another time zone's calendar")
    func timeZoneCalendar() {
        let auckland = Self.calendar("Pacific/Auckland")
        // 2026-10-05 02:00 UTC: 7 pm Oct 4 in Los Angeles, 3 pm Oct 5 in Auckland.
        // `now` is 07:00 UTC: just past midnight Oct 5 in Los Angeles, 8 pm Oct 5 in Auckland.
        let instant = Date(timeIntervalSince1970: 1_791_165_600)
        let now = instant.addingTimeInterval(5 * 3_600)
        let inLA = select([dictation(1, instant)], now: now, calendar: la)
        let inAuckland = select([dictation(1, instant)], now: now, calendar: auckland)
        #expect(inLA.today.all.isEmpty)
        #expect(inLA.earlier?.label == "Yesterday")
        #expect(inAuckland.today.all.count == 1)
        #expect(inAuckland.earlier == nil)
        // 06:00 UTC Oct 4 is 7 pm Oct 4 in Auckland: yesterday there.
        let older = instant.addingTimeInterval(-20 * 3_600)
        let aucklandOlder = select([dictation(2, older)], now: now, calendar: auckland)
        #expect(aucklandOlder.today.all.isEmpty)
        #expect(aucklandOlder.earlier?.label == "Yesterday")
    }

    @Test("an entry dated in the future is neither today nor earlier")
    func futureIgnored() {
        let selection = select([dictation(1, at(la, 2026, 10, 6, 9, 0))])
        #expect(selection.today.all.isEmpty)
        #expect(selection.earlier == nil)
    }

    // MARK: - Earlier day

    @Test("the earlier day skips days with nothing in them")
    func earlierDaySeveralDaysBack() {
        // Monday Oct 5 now; last activity on Friday Oct 2 (3 days back).
        let friday = at(la, 2026, 10, 2, 16, 0)
        let selection = select(dictations(2, latest: friday), notes: [note(1, friday.addingTimeInterval(-3_600))])
        #expect(selection.today.all.isEmpty)
        #expect(selection.earlier?.label == "Friday")
        #expect(selection.earlier?.dictationCount == 2)
        #expect(selection.earlier?.noteCount == 1)
        #expect(selection.earlier?.actionCount == 0)
    }

    @Test("only the most recent earlier day is selected")
    func onlyMostRecentEarlierDay() {
        let selection = select(
            dictations(2, latest: at(la, 2026, 10, 3, 10, 0), firstID: 1)
                + dictations(5, latest: at(la, 2026, 9, 30, 10, 0), firstID: 10))
        #expect(selection.earlier?.all.map(\.id) == ["d1", "d2"])
    }

    @Test("the earlier day follows the same cap rule")
    func earlierDayCap() {
        let selection = select(
            dictations(12, latest: at(la, 2026, 10, 4, 19, 0)),
            actions: [action(1, at(la, 2026, 10, 4, 8, 0))])
        #expect(selection.earlier?.dictationCount == 12)
        #expect(selection.earlier?.capped.count == 8 + 1)
        #expect(selection.earlier?.hiddenDictationCount == 4)
        #expect(selection.earlier?.all.count == 13)
    }

    // MARK: - Labels

    @Test("day labels: yesterday, weekday for two to six days, short date after")
    func dayLabels() {
        func label(daysBack: Int) -> String? {
            let day = la.date(byAdding: .day, value: -daysBack, to: at(la, 2026, 10, 5, 9, 0)) ?? Date()
            return select([dictation(1, day)]).earlier?.label
        }
        #expect(label(daysBack: 1) == "Yesterday")
        #expect(label(daysBack: 2) == "Saturday")
        #expect(label(daysBack: 6) == "Tuesday")
        #expect(label(daysBack: 7) == "Sep 28")
        #expect(label(daysBack: 30) == "Sep 5")
    }

    @Test("an older date in another year carries the year")
    func otherYearLabel() {
        let selection = select([dictation(1, at(la, 2025, 12, 24, 10, 0))])
        #expect(selection.earlier?.label == "Dec 24, 2025")
    }

    @Test("the summary names counts, drops zeros and uses singular forms")
    func summaryLine() {
        let day = at(la, 2026, 10, 4, 10, 0)
        let both = select(dictations(14, latest: day), actions: [action(1, day), action(2, day)])
        #expect(both.earlier?.summary == "Yesterday · 14 dictations · 2 voice actions")

        let single = select([dictation(1, day)], notes: [note(1, day)], actions: [action(1, day)])
        #expect(single.earlier?.summary == "Yesterday · 1 dictation · 1 voice action · 1 note")

        let onlyNotes = select(notes: [note(1, day), note(2, day)])
        #expect(onlyNotes.earlier?.summary == "Yesterday · 2 notes")
    }

    // MARK: - Visible entries and Quick Look order

    @Test("visible dictation ids follow what is expanded")
    func visibleDictationIDs() {
        let today = dictations(10, latest: at(la, 2026, 10, 5, 11, 0), firstID: 1)
        let yesterday = dictations(10, latest: at(la, 2026, 10, 4, 18, 0), firstID: 100)
        let selection = select(today + yesterday)
        let day = la.startOfDay(for: noon(la))

        let collapsed = HomeExpansion(day: day)
        #expect(selection.visibleDictationIDs(expansion: collapsed, calendar: la) == Array(1...8).map(Int64.init))

        let allToday = collapsed.togglingShowAllToday()
        #expect(selection.visibleDictationIDs(expansion: allToday, calendar: la) == Array(1...10).map(Int64.init))

        let earlierOpen = collapsed.togglingEarlier(todayIsEmpty: false)
        let expected = Array(1...8).map(Int64.init) + Array(100...107).map(Int64.init)
        #expect(selection.visibleDictationIDs(expansion: earlierOpen, calendar: la) == expected)

        let everything = allToday.togglingShowAllEarlier().togglingEarlier(todayIsEmpty: false)
        #expect(selection.visibleDictationIDs(expansion: everything, calendar: la).count == 20)
    }

    @Test("groups are built from the visible entries only")
    func groupsUseVisibleEntries() {
        let selection = select(dictations(12, latest: at(la, 2026, 10, 5, 11, 0)))
        let day = la.startOfDay(for: noon(la))
        let collapsed = selection.todayGroups(expansion: HomeExpansion(day: day), calendar: la)
        #expect(collapsed.flatMap(\.entries).count == 8)
        let expanded = selection.todayGroups(expansion: HomeExpansion(day: day).togglingShowAllToday(), calendar: la)
        #expect(expanded.flatMap(\.entries).count == 12)
    }
}

@Suite("Home expansion state")
struct HomeExpansionTests {
    private let day1 = Date(timeIntervalSince1970: 1_791_000_000)
    private let day2 = Date(timeIntervalSince1970: 1_791_086_400)

    @Test("the earlier day opens by default only while today is empty")
    func earlierDefault() {
        let fresh = HomeExpansion(day: day1)
        #expect(HomeExpansion.earlierDayOpenWhenTodayEmpty)
        #expect(fresh.isEarlierOpen(todayIsEmpty: true))
        #expect(!fresh.isEarlierOpen(todayIsEmpty: false))
    }

    @Test("a click overrides the default either way")
    func earlierToggle() {
        let fresh = HomeExpansion(day: day1)
        #expect(!fresh.togglingEarlier(todayIsEmpty: true).isEarlierOpen(todayIsEmpty: true))
        #expect(fresh.togglingEarlier(todayIsEmpty: false).isEarlierOpen(todayIsEmpty: false))
    }

    @Test("everything resets when the day changes, and stays put on the same day")
    func rollover() {
        let state = HomeExpansion(day: day1).togglingShowAllToday().togglingShowAllEarlier().togglingEarlier(todayIsEmpty: false)
        #expect(state.rolledOver(to: day1) == state)
        #expect(state.rolledOver(to: day2) == HomeExpansion(day: day2))
    }
}
