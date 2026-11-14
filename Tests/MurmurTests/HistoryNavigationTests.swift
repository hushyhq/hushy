import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// History's header and modes: the always-visible date scope, selecting many rows, and opening
/// one dictation from outside the page. Invented text only.
@Suite("History scope, selection and open-one")
@MainActor
struct HistoryNavigationTests {
    private let calendar = Calendar.current
    /// Noon, so day arithmetic is the same in every time zone.
    private var now: Date {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: base) ?? base
    }

    private func dictation(_ id: Int64, at date: Date, text: String = "Thanks, that works for me.", status: Dictation.Status = .inserted) -> Dictation {
        Dictation(id: id, createdAt: date, rawText: text.lowercased(), text: text, appBundleID: "com.apple.mail", appName: "Mail", durationSeconds: 2, status: status)
    }

    // MARK: Scope

    @Test("the three scopes are Today, Last 7 days and All dates, and All dates means no date filter")
    func scopes() {
        #expect(HistoryScope.allCases.map(\.title) == ["Today", "Last 7 days", "All dates"])
        #expect(HistoryScope.today.dateRange == .today)
        #expect(HistoryScope.lastSevenDays.dateRange == .last7Days)
        #expect(HistoryScope.allDates.dateRange == nil)
    }

    @Test("the scope that reads as chosen follows the date filter; History still opens on Today")
    func currentScope() {
        #expect(HistoryScope.current(for: HistoryView.defaultDateRange, now: now, calendar: calendar) == .today)
        #expect(HistoryScope.current(for: nil, now: now, calendar: calendar) == .allDates)
        #expect(HistoryScope.current(for: .last7Days, now: now, calendar: calendar) == .lastSevenDays)
        let today = calendar.startOfDay(for: now)
        #expect(HistoryScope.current(for: .custom(start: today, end: today), now: now, calendar: calendar) == .today, "tapping today's column is still Today")
    }

    @Test("a range the bar does not hold selects no scope, so its own chip names it")
    func otherRanges() {
        let today = calendar.startOfDay(for: now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today) ?? today
        for range in [HistoryDateRange.yesterday, .last30Days, .custom(start: threeDaysAgo, end: threeDaysAgo), .custom(start: threeDaysAgo, end: today)] {
            #expect(HistoryScope.current(for: range, now: now, calendar: calendar) == nil, "\(range)")
            #expect(HistoryScope.showsRangeChip(for: range, now: now, calendar: calendar))
        }
        #expect(!HistoryScope.showsRangeChip(for: nil, now: now, calendar: calendar))
        #expect(!HistoryScope.showsRangeChip(for: .today, now: now, calendar: calendar))
        #expect(!HistoryScope.showsRangeChip(for: .last7Days, now: now, calendar: calendar))
    }

    // MARK: Selecting many

    @Test("a click adds a row to the selection, and a second click takes it out")
    func toggle() {
        let one = HistorySelection.toggling(4, in: [])
        #expect(one == [4])
        #expect(HistorySelection.toggling(9, in: one) == [4, 9])
        #expect(HistorySelection.toggling(4, in: [4, 9]) == [9])
    }

    @Test("shift-click selects every row from the last one clicked to this one, in list order")
    func range() {
        let order: [Int64] = [10, 9, 8, 7, 6]
        #expect(HistorySelection.extending([9], from: 9, to: 6, order: order) == [9, 8, 7, 6])
        #expect(HistorySelection.extending([7], from: 7, to: 10, order: order) == [10, 9, 8, 7])
        #expect(HistorySelection.extending([3], from: nil, to: 8, order: order) == [3, 8], "no anchor: a plain add")
        #expect(HistorySelection.extending([], from: 99, to: 8, order: order) == [8], "an anchor that scrolled away: a plain add")
    }

    @Test("a selected stack of failures counts and deletes every recording in it")
    func stacks() {
        let single = HistoryRowModel(.single(dictation(1, at: now)))
        let failures = (2...4).map { dictation(Int64($0), at: now.addingTimeInterval(-Double($0)), text: "", status: .failed) }
        let stack = HistoryRowModel(.stack(failures))
        let other = HistoryRowModel(.single(dictation(5, at: now.addingTimeInterval(-600))))
        let chosen = HistorySelection.dictations(in: [single, stack, other], selected: [single.id, stack.id])
        #expect(chosen.compactMap(\.id) == [1, 2, 3, 4])
        #expect(HistorySelection.dictations(in: [single, stack, other], selected: []).isEmpty)
    }

    @Test("the band names what is being selected from, hidden search and filters included")
    func selectionSource() {
        #expect(HistorySelection.source(dateLabel: "Today", search: "", needsAttentionOnly: false, appName: nil) == "From Today.")
        #expect(HistorySelection.source(dateLabel: "All dates", search: " budget ", needsAttentionOnly: false, appName: nil)
            == "From All dates, matching “budget”.")
        #expect(HistorySelection.source(dateLabel: "Last 7 days", search: "", needsAttentionOnly: true, appName: nil)
            == "From Last 7 days, needing attention only.")
        #expect(HistorySelection.source(dateLabel: "Oct 3", search: "", needsAttentionOnly: false, appName: "Mail")
            == "From Oct 3, in Mail only.")
        #expect(HistorySelection.source(dateLabel: "All dates", search: "plan", needsAttentionOnly: false, appName: "Mail")
            == "From All dates, matching “plan”, in Mail only.")
    }

    @Test("the select-all button says how many it selects, and that more are not loaded yet when that is so")
    func selectAllWords() {
        #expect(HistorySelection.selectAllTitle(count: 12, hasMore: false) == "Select all 12")
        #expect(HistorySelection.selectAllTitle(count: 100, hasMore: true) == "Select the 100 loaded so far")
        #expect(HistorySelection.selectAllTitle(count: 1, hasMore: false) == "Select the 1 here")
        #expect(HistorySelection.selectAllTitle(count: 0, hasMore: false) == nil)
        // What it selects is every loaded row, in or out of view; a stack counts each recording.
        let single = HistoryRowModel(.single(dictation(1, at: now)))
        let failures = (2...4).map { dictation(Int64($0), at: now.addingTimeInterval(-Double($0)), text: "", status: .failed) }
        let rows = [single, HistoryRowModel(.stack(failures))]
        let all = HistorySelection.selectingAll(rows)
        #expect(all == [single.id, rows[1].id])
        #expect(HistorySelection.dictations(in: rows, selected: all).count == HistorySelection.loadedCount(rows))
        #expect(HistorySelection.loadedCount(rows) == 4)
    }

    @Test("Command-A selects all only while selecting, and never when a text field has the keyboard")
    func commandA() {
        #expect(HistorySelection.commandA(isSelecting: true, textFieldHasFocus: false) == .selectAll)
        #expect(HistorySelection.commandA(isSelecting: true, textFieldHasFocus: true) == .leaveToTextField)
        #expect(HistorySelection.commandA(isSelecting: false, textFieldHasFocus: false) == .ignore)
        #expect(HistorySelection.commandA(isSelecting: false, textFieldHasFocus: true) == .leaveToTextField)
    }

    // MARK: Deleting

    @Test("a delete request only ever asks to confirm, from the Delete button and from the Delete key alike")
    func deleteAlwaysConfirms() {
        // Selecting, with rows checked: the button and the key both ask about those rows.
        #expect(HistoryDeleteFlow.rowsToConfirm(isSelecting: true, selection: [4, 9], openRowID: 2) == [4, 9])
        // Selecting, nothing checked: nothing to ask, and the row that was open before is not touched.
        #expect(HistoryDeleteFlow.rowsToConfirm(isSelecting: true, selection: [], openRowID: 2) == nil)
        // Browsing: the Delete key asks about the open row.
        #expect(HistoryDeleteFlow.rowsToConfirm(isSelecting: false, selection: [], openRowID: 2) == [2])
        #expect(HistoryDeleteFlow.rowsToConfirm(isSelecting: false, selection: [7], openRowID: nil) == nil)
    }

    @Test("the number asked about, the number on the button and the rows removed are the same, a collapsed stack included")
    func deleteCountMatchesRemoval() throws {
        let store = try Store()
        let single = try store.save(dictation(0, at: now).withoutID)
        let failures = try (1...3).map { try store.save(dictation(0, at: now.addingTimeInterval(-Double($0)), text: "", status: .failed).withoutID) }
        let kept = try store.save(dictation(0, at: now.addingTimeInterval(-600)).withoutID)
        let rows = [HistoryRowModel(.single(single)), HistoryRowModel(.stack(failures)), HistoryRowModel(.single(kept))]

        let confirmation = HistoryDeleteFlow.confirmation(rows: rows, selected: [rows[0].id, rows[1].id])
        #expect(confirmation.count == 4)
        #expect(confirmation.title == "Delete 4 dictations?")
        #expect(HistorySelection.deleteTitle(count: confirmation.count) == "Delete 4")
        #expect(HistorySelection.title(count: confirmation.count) == "4 dictations selected")

        try store.deleteDictations(ids: confirmation.dictations.compactMap(\.id))
        let left = try store.recentDictations()
        #expect(left.count == 5 - confirmation.count)
        #expect(left.map(\.id) == [kept.id])
        #expect(HistoryDeleteFlow.confirmation(rows: [rows[2]], selected: [rows[2].id]).title == "Delete 1 dictation?")
    }

    @Test("the selection's words say the mode, how many, what a click does and what Delete does")
    func selectionCopy() {
        #expect(HistorySelection.modeTitle == "Selecting dictations")
        #expect(HistorySelection.title(count: 0) == "Nothing selected yet")
        #expect(HistorySelection.title(count: 1) == "1 dictation selected")
        #expect(HistorySelection.title(count: 3) == "3 dictations selected")
        #expect(HistorySelection.hint(count: 0) == "Click a row to select it. Nothing opens while you are selecting.")
        #expect(HistorySelection.hint(count: 2) == "Click a row to add or remove it. Done goes back to opening one at a time.")
        #expect(HistorySelection.paneMessage(count: 1) == "Delete removes it, and any saved audio with it. This can't be undone.")
        #expect(HistorySelection.paneMessage(count: 4) == "Delete removes them, and any saved audio with them. This can't be undone.")
        #expect(HistorySelection.paneMessage(count: 0).contains("Done goes back to opening one at a time."))
        #expect(HistorySelection.deleteTitle(count: 0) == "Delete")
        #expect(HistorySelection.deleteTitle(count: 3) == "Delete 3")
    }

    // MARK: Opening one from outside

    @Test("a request is handed to History once")
    func requestIsTakenOnce() {
        let request = HistoryOpenRequest()
        #expect(request.take() == nil)
        request.request(42)
        #expect(request.pendingID == 42)
        #expect(request.take() == 42)
        #expect(request.take() == nil)
        #expect(request.pendingID == nil)
    }

    @Test("a request that is not served within its lifetime is dropped, so a late unlock opens nothing")
    func requestExpires() {
        let request = HistoryOpenRequest()
        request.request(42, now: now)
        #expect(request.take(now: now.addingTimeInterval(HistoryOpenRequest.lifetime + 1)) == nil)
        #expect(request.pendingID == nil, "an expired request is cleared, not kept for later")

        request.request(43, now: now)
        #expect(request.take(now: now.addingTimeInterval(HistoryOpenRequest.lifetime - 1)) == 43)
        #expect(HistoryOpenRequest.lifetime == 60)
    }

    @Test("leaving History drops a request that was never served")
    func requestCancelledOnLeaving() {
        let request = HistoryOpenRequest()
        request.request(42, now: now)
        request.sectionChanged(isHistory: true)
        #expect(request.pendingID == 42, "arriving at History keeps it")
        request.sectionChanged(isHistory: false)
        #expect(request.pendingID == nil)
        #expect(request.take(now: now) == nil)
    }

    @Test("the newest request wins")
    func newestRequestWins() {
        let request = HistoryOpenRequest()
        request.request(1)
        request.request(2)
        #expect(request.take() == 2)
    }

    @Test("History shows the item's own day: Today for today, that single day otherwise")
    func targetDateRange() {
        #expect(HistoryOpenTarget.dateRange(for: now.addingTimeInterval(-60), now: now, calendar: calendar) == .today)
        let lastWeek = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let range = HistoryOpenTarget.dateRange(for: lastWeek, now: now, calendar: calendar)
        #expect(range.singleSelectedDay(now: now, calendar: calendar) == calendar.startOfDay(for: lastWeek))
    }

    @Test("a dictation that no longer exists is reported, not silently ignored")
    func planForMissing() {
        #expect(HistoryOpenTarget.plan(for: nil, now: now, calendar: calendar) == .missing)
        let old = dictation(5, at: calendar.date(byAdding: .day, value: -40, to: now) ?? now)
        let plan = HistoryOpenTarget.plan(for: old, now: now, calendar: calendar)
        #expect(plan == .show(HistoryOpenTarget.dateRange(for: old.createdAt, now: now, calendar: calendar)))
        #expect(HistoryOpenTarget.plan(for: dictation(6, at: now), now: now, calendar: calendar) == .show(.today))
        #expect(HistoryCopy.openedItemMissing == "That dictation is no longer in History.")
    }

    /// A stand-in for the pager: a day's rows arrive one page at a time.
    private final class FakeRows: HistoryRowLoading {
        private let pages: [[HistoryRowModel]]
        private let day: Date
        private(set) var loaded = 1
        private(set) var loadCalls = 0
        /// Says more is coming even when it is not, like a pager that failed to advance.
        var stuck = false

        init(pages: [[HistoryRowModel]], day: Date) {
            self.pages = pages
            self.day = day
        }

        var sections: [HistoryDaySection] { [HistoryDaySection(day: day, rows: pages.prefix(loaded).flatMap { $0 })] }
        var hasMore: Bool { stuck || loaded < pages.count }

        func loadNextPage() {
            loadCalls += 1
            if loaded < pages.count { loaded += 1 }
        }
    }

    private func pages(_ ids: [[Int64]]) -> FakeRows {
        FakeRows(
            pages: ids.map { page in page.map { HistoryRowModel(.single(dictation($0, at: now.addingTimeInterval(-Double($0))))) } },
            day: calendar.startOfDay(for: now))
    }

    @Test("a row already loaded is found without loading more")
    func locateLoaded() {
        let rows = pages([[1, 2, 3], [4, 5]])
        #expect(HistoryOpenTarget.locate(2, in: rows) == 2)
        #expect(rows.loadCalls == 0)
    }

    @Test("a row that is not loaded yet is found by loading the pages before it, and no more")
    func locateNotLoaded() {
        let rows = pages([[1, 2], [3, 4], [5, 6], [7, 8]])
        #expect(HistoryOpenTarget.locate(5, in: rows) == 5)
        #expect(rows.loadCalls == 2)
    }

    @Test("a row that is on no page ends the search when the pages run out or stop advancing")
    func locateAbsent() {
        let rows = pages([[1, 2], [3, 4]])
        #expect(HistoryOpenTarget.locate(99, in: rows) == nil)
        #expect(rows.loadCalls == 1)

        let stuck = pages([[1, 2]])
        stuck.stuck = true
        #expect(HistoryOpenTarget.locate(99, in: stuck) == nil)
        #expect(stuck.loadCalls == 1, "a page that adds nothing ends it")
    }

    @Test("the row to open is the dictation's own, or the stack it was folded into")
    func targetRow() {
        let single = HistoryRowModel(.single(dictation(1, at: now)))
        let failures = (2...4).map { dictation(Int64($0), at: now.addingTimeInterval(-Double($0)), text: "", status: .failed) }
        let stack = HistoryRowModel(.stack(failures))
        let sections = [HistoryDaySection(day: calendar.startOfDay(for: now), rows: [single, stack])]
        #expect(HistoryOpenTarget.rowID(for: 1, in: sections) == 1)
        #expect(HistoryOpenTarget.rowID(for: 3, in: sections) == stack.id)
        #expect(HistoryOpenTarget.rowID(for: 77, in: sections) == nil)
    }
}

private extension Dictation {
    /// As a row not stored yet, so the store assigns its id.
    var withoutID: Dictation {
        var copy = self
        copy.id = nil
        return copy
    }
}
