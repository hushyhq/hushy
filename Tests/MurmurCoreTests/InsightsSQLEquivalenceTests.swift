import Foundation
import Testing
@testable import MurmurCore

/// Verifies `Store.computeInsights` (SQL aggregates) produces byte-for-byte the same `Insights`
/// as the original in-memory `Insights.compute(from:)`, across a seed set deliberately varied
/// in day (including streak gaps), app, status, and edit state. Uses an in-memory store
/// (`Store.init()`), never the user's real database.
@Suite("Insights: SQL aggregates match in-memory compute")
struct InsightsSQLEquivalenceTests {
    let calendar = Calendar(identifier: .gregorian)

    func day(_ offset: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: now)!
    }

    /// A varied seed: several days with a gap (breaks/continues streaks), several apps across
    /// categories (including a browser needing no title classification, since `compute`'s main
    /// path only classifies by bundle id), the app's own bundle id (excluded from top apps),
    /// every `Dictation.Status`, and a mix of measured/unmeasured edit states.
    /// `editState` isn't part of `Dictation.init` (it's set after the fact, e.g. by
    /// `Store.setEditState`), so build it here and assign the field directly.
    func makeDictation(
        createdAt: Date, rawText: String, text: String, appBundleID: String? = nil,
        appName: String? = nil, durationSeconds: Double, fixes: Int = 0,
        status: Dictation.Status = .inserted, editState: Dictation.EditState? = nil
    ) -> Dictation {
        var item = Dictation(
            createdAt: createdAt, rawText: rawText, text: text, appBundleID: appBundleID,
            appName: appName, durationSeconds: durationSeconds, fixes: fixes, status: status)
        item.editState = editState
        return item
    }

    func seedRows(now: Date) -> [Dictation] {
        [
            // Day 0: two dictations, two different apps, one measured edit each.
            makeDictation(createdAt: day(0, from: now).addingTimeInterval(60), rawText: "one two three four five",
                      text: "one two three four five", appBundleID: "com.apple.mail", appName: "Mail",
                      durationSeconds: 6, fixes: 2, status: .inserted, editState: .kept),
            makeDictation(createdAt: day(0, from: now).addingTimeInterval(120), rawText: "six seven",
                      text: "six seven", appBundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                      durationSeconds: 3, fixes: 0, status: .inserted, editState: .edited),
            // Day -1: same app as day 0 (Mail), no edit state measured.
            makeDictation(createdAt: day(-1, from: now), rawText: "eight nine ten",
                      text: "eight nine ten", appBundleID: "com.apple.mail", appName: "Mail",
                      durationSeconds: 4, fixes: 1, status: .inserted),
            // Day -2 deliberately skipped: breaks the streak, tests the gap-handling path.
            // Day -3: a third app (Cursor -> .code), and a not-inserted status (still counted).
            makeDictation(createdAt: day(-3, from: now), rawText: "eleven twelve",
                      text: "eleven twelve", appBundleID: "cursor", appName: "Cursor",
                      durationSeconds: 2, fixes: 0, status: .notInserted, editState: .kept),
            // Day -4: no app recorded at all (appBundleID nil) -> AppCategory.other, doesn't
            // count toward appsUsed or topApps, but does count toward totals/day/streak.
            makeDictation(createdAt: day(-4, from: now), rawText: "thirteen",
                      text: "thirteen", appBundleID: nil, durationSeconds: 1, status: .inserted),
            // The app's own bundle id: counted in totals/days, excluded from topApps only.
            makeDictation(createdAt: day(-4, from: now).addingTimeInterval(30), rawText: "own app words here",
                      text: "own app words here", appBundleID: Insights.ownBundleID, appName: "Hushy",
                      durationSeconds: 3, fixes: 0, status: .inserted),
            // Excluded entirely: cancelled and failed dictations, even though "today".
            makeDictation(createdAt: now, rawText: "ignored cancelled words",
                      text: "ignored cancelled words", appBundleID: "com.apple.mail",
                      durationSeconds: 2, status: .cancelled),
            makeDictation(createdAt: now, rawText: "ignored failed words",
                      text: "ignored failed words", appBundleID: "com.apple.mail",
                      durationSeconds: 2, status: .failed),
        ]
    }

    @Test("words per app, for ordering the tone screens: counted dictations only, never Hushy itself or an unknown app")
    func appWordCounts() throws {
        let store = try Store()
        let now = Date()
        for row in seedRows(now: now) { _ = try store.save(row) }
        // Older than the window (90 days): not counted, however many words.
        _ = try store.save(makeDictation(
            createdAt: day(-Store.appUsageWindowDays - 30, from: now), rawText: "a b c d e f g h i j", text: "a b c d e f g h i j",
            appBundleID: "com.apple.mail", appName: "Mail", durationSeconds: 5))
        _ = try store.save(makeDictation(
            createdAt: day(-Store.appUsageWindowDays + 5, from: now), rawText: "k l", text: "k l",
            appBundleID: "com.example.recent", appName: "Recent", durationSeconds: 1))
        let counts = try store.appWordCounts(now: now)
        #expect(counts["com.example.recent"] == 2)
        #expect(Store.appUsageWindowDays == 90)
        #expect(counts["com.apple.mail"] == 8)
        #expect(counts["com.tinyspeck.slackmacgap"] == 2)
        #expect(counts[Insights.ownBundleID] == nil)
        #expect(counts.keys.allSatisfy { !$0.isEmpty })
    }

    @Test("matches in-memory Insights.compute on a varied multi-day, multi-app, multi-status seed")
    func matchesInMemoryCompute() throws {
        let store = try Store()
        let now = Date()
        let rows = seedRows(now: now)
        for row in rows { _ = try store.save(row) }

        let expected = Insights.compute(from: rows, now: now, calendar: calendar)
        let actual = try store.computeInsights(now: now, calendar: calendar)

        #expect(actual.totalWords == expected.totalWords)
        #expect(actual.totalDictations == expected.totalDictations)
        #expect(actual.averageWPM == expected.averageWPM)
        #expect(actual.fixes == expected.fixes)
        #expect(actual.currentStreak == expected.currentStreak)
        #expect(actual.longestStreak == expected.longestStreak)
        #expect(actual.minutesSaved == expected.minutesSaved)
        #expect(actual.appsUsed == expected.appsUsed)
        #expect(actual.editFreeRate == expected.editFreeRate)
        #expect(actual.editsMeasured == expected.editsMeasured)
        #expect(actual.weekEditsKept == expected.weekEditsKept)
        #expect(actual.weekEditsMeasured == expected.weekEditsMeasured)
        #expect(Set(actual.days) == Set(expected.days))
        // Compared as sets, not arrays: both implementations sort categories/topApps by
        // `words` descending, and this seed deliberately has a tie (`.code` and
        // `.workMessages` both have 2 words) whose relative order isn't determined by that
        // sort — a pre-existing property of `Insights.compute`'s dictionary-driven grouping,
        // not something the SQL version needs to reproduce bit-for-bit.
        #expect(Set(actual.categories) == Set(expected.categories))
        #expect(Set(actual.topApps) == Set(expected.topApps))
    }

    @Test("empty store returns .empty from both implementations")
    func emptyStoreMatches() throws {
        let store = try Store()
        let actual = try store.computeInsights()
        #expect(actual == .empty)
        #expect(actual == Insights.compute(from: []))
    }

    @Test("store with only cancelled/failed dictations returns .empty from both implementations")
    func allExcludedStatusesMatch() throws {
        let store = try Store()
        let now = Date()
        let rows = [
            Dictation(createdAt: now, rawText: "a", text: "a", durationSeconds: 1, status: .cancelled),
            Dictation(createdAt: now, rawText: "b", text: "b", durationSeconds: 1, status: .failed),
        ]
        for row in rows { _ = try store.save(row) }

        let actual = try store.computeInsights(now: now, calendar: calendar)
        #expect(actual == .empty)
        #expect(actual == Insights.compute(from: rows, now: now, calendar: calendar))
    }

    @Test("streak gap across a month boundary still matches, including longest vs current")
    func streakAcrossMonthBoundaryMatches() throws {
        let store = try Store()
        // Fixed instant that straddles a month boundary regardless of the machine's clock.
        let now = Date(timeIntervalSince1970: 1_706_745_600) // 2024-02-01 00:00:00 UTC
        var rows: [Dictation] = []
        // A 4-day run ending 2 days ago (longest), then a fresh 2-day run ending today (current).
        for offset in [-6, -5, -4, -3, 0, -1] {
            rows.append(Dictation(
                createdAt: day(offset, from: now).addingTimeInterval(3600),
                rawText: "word", text: "word", appBundleID: "com.apple.mail", durationSeconds: 1))
        }
        for row in rows { _ = try store.save(row) }

        let expected = Insights.compute(from: rows, now: now, calendar: calendar)
        let actual = try store.computeInsights(now: now, calendar: calendar)
        #expect(actual.currentStreak == expected.currentStreak)
        #expect(actual.longestStreak == expected.longestStreak)
        #expect(Set(actual.days) == Set(expected.days))
    }

    // MARK: the person's own number for the week

    @Test("this week is the last seven days, today included: both implementations agree, the edge in and the day before out")
    func weekWindowMatches() throws {
        let store = try Store()
        let now = Date()
        let start = Insights.weekStart(now: now, calendar: calendar)
        #expect(start == calendar.startOfDay(for: day(-6, from: now)))
        let rows = [
            makeDictation(createdAt: start.addingTimeInterval(1), rawText: "a b c", text: "a b c", durationSeconds: 1, editState: .kept),
            makeDictation(createdAt: start.addingTimeInterval(2), rawText: "d e f", text: "d e f", durationSeconds: 1, editState: .edited),
            makeDictation(createdAt: start.addingTimeInterval(3), rawText: "g h i", text: "g h i", durationSeconds: 1),                      // not checked
            makeDictation(createdAt: now, rawText: "j k l", text: "j k l", durationSeconds: 1, editState: .kept),
            makeDictation(createdAt: start.addingTimeInterval(-60), rawText: "m n o", text: "m n o", durationSeconds: 1, editState: .kept),  // the day before the window
            makeDictation(createdAt: day(-30, from: now), rawText: "p q r", text: "p q r", durationSeconds: 1, editState: .edited),
            makeDictation(createdAt: now, rawText: "s t u", text: "s t u", durationSeconds: 1, status: .failed, editState: .kept),           // never counted
        ]
        for row in rows { _ = try store.save(row) }
        let expected = Insights.compute(from: rows, now: now, calendar: calendar)
        let actual = try store.computeInsights(now: now, calendar: calendar)
        #expect(expected.weekEditsKept == 2 && expected.weekEditsMeasured == 3)
        #expect(actual.weekEditsKept == 2 && actual.weekEditsMeasured == 3)
        #expect(actual.editsMeasured == 5 && actual.keptThisWeekLine == "You kept 2 of 3 checked dictations as typed this week")
    }

    @Test("the line is a percentage once five have been checked, a plain count before, and nothing before one")
    func keptThisWeekLine() {
        #expect(Insights.keptThisWeekLine(kept: 0, measured: 0) == nil)
        #expect(Insights.keptThisWeekLine(kept: 1, measured: 1) == "You kept 1 of 1 checked dictations as typed this week")
        #expect(Insights.keptThisWeekLine(kept: 4, measured: 4) == "You kept 4 of 4 checked dictations as typed this week")
        #expect(Insights.keptThisWeekLine(kept: 5, measured: 5) == "You kept 100% of dictations as typed this week")
        #expect(Insights.keptThisWeekLine(kept: 43, measured: 50) == "You kept 86% of dictations as typed this week")
        #expect(Insights.keptThisWeekLine(kept: 0, measured: 8) == "You kept 0% of dictations as typed this week")
        #expect(Insights.keptThisWeekLine(kept: 9, measured: 8) == nil)    // cannot keep more than were checked
        #expect(Insights.empty.keptThisWeekLine == nil)
    }
}
