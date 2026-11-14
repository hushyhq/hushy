import Foundation
import Testing
@testable import MurmurCore

/// Lightweight fixture conforming to `HistoryScrubbable`, so bucketing tests don't need real
/// `Dictation`/`HistoryRowModel` rows.
private struct Fixture: HistoryScrubbable, Equatable {
    let scrubberID: Int64
    let scrubberCreatedAt: Date
    let scrubberAppBundleID: String?
    var scrubberTimeLabel: String { scrubberCreatedAt.formatted(date: .omitted, time: .shortened) }
    var scrubberFirstLine: String { "item \(scrubberID)" }
}

@Suite("HistoryScrubberModel bucketing")
struct HistoryScrubberModelTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Builds `count` newest-first fixtures, one every 5 minutes, cycling through 3 apps,
    /// spread across enough distinct days to exercise day-bucketing at scale.
    private func makeItems(count: Int, minutesApart: Double = 5, apps: [String?] = ["com.a", "com.b", "com.c"]) -> [Fixture] {
        (0..<count).map { index in
            Fixture(
                scrubberID: Int64(index),
                scrubberCreatedAt: Self.base.addingTimeInterval(-Double(index) * minutesApart * 60),
                scrubberAppBundleID: apps[index % apps.count])
        }
    }

    @Test("empty input produces no ticks")
    func emptyInput() {
        #expect(HistoryScrubberModel.ticks(for: [Fixture](), calendar: Self.calendar).isEmpty)
    }

    @Test("at or below the item threshold (10), one tick per item")
    func atItemThreshold() {
        let items = makeItems(count: HistoryScrubberModel.itemTickThreshold)
        let ticks = HistoryScrubberModel.ticks(for: items, calendar: Self.calendar)
        #expect(ticks.count == items.count)
        #expect(ticks.allSatisfy { $0.kind == .item })
    }

    @Test("just above the item threshold, ticks switch to run-based and no longer equal item count 1:1")
    func justAboveItemThreshold() {
        // 11 items, one every 5 minutes, alternating 3 apps -> every item is its own run since
        // consecutive apps differ, so tick count still equals item count, but the KIND changes.
        let items = makeItems(count: HistoryScrubberModel.itemTickThreshold + 1)
        let ticks = HistoryScrubberModel.ticks(for: items, calendar: Self.calendar)
        #expect(ticks.allSatisfy { $0.kind == .run })
    }

    @Test("1,000 items collapse via run-tier bucketing to far fewer ticks when apps repeat in long runs")
    func at1000ItemsRunsCollapseLongSameAppSequences() {
        // Long runs of the same app (30 in a row) so grouping actually collapses ticks, not the
        // pathological alternating-app case where every item is its own run.
        var items: [Fixture] = []
        var id: Int64 = 0
        var offsetMinutes = 0.0
        let apps = ["com.a", "com.b", "com.c"]
        var appIndex = 0
        while items.count < 1_000 {
            let app = apps[appIndex % apps.count]
            for _ in 0..<30 where items.count < 1_000 {
                items.append(Fixture(scrubberID: id, scrubberCreatedAt: Self.base.addingTimeInterval(-offsetMinutes * 60), scrubberAppBundleID: app))
                id += 1
                offsetMinutes += 1
            }
            appIndex += 1
        }
        let ticks = HistoryScrubberModel.ticks(for: items, calendar: Self.calendar)
        #expect(ticks.count < items.count)
        #expect(ticks.allSatisfy { $0.kind == .run })
        // Every tick should represent a run of up to 30 items.
        #expect(ticks.allSatisfy { $0.itemCount <= 30 })
    }

    @Test("above the run threshold (20,000), ticks collapse to one per day regardless of row count")
    func at20000ItemsCollapseToDayBuckets() {
        // 20,000 items spread evenly across 20 days (1,000/day), one every ~1.4 minutes.
        let dayCount = 20
        let perDay = 1_000
        var items: [Fixture] = []
        var id: Int64 = 0
        for day in 0..<dayCount {
            for minuteOffset in 0..<perDay {
                let createdAt = Self.calendar.date(byAdding: .day, value: -day, to: Self.base)!
                    .addingTimeInterval(-Double(minuteOffset) * 60)
                items.append(Fixture(scrubberID: id, scrubberCreatedAt: createdAt, scrubberAppBundleID: "com.a"))
                id += 1
            }
        }
        #expect(items.count == dayCount * perDay)
        let ticks = HistoryScrubberModel.ticks(for: items, calendar: Self.calendar)
        #expect(ticks.count == dayCount)
        #expect(ticks.allSatisfy { $0.kind == .bucket })
        #expect(ticks.allSatisfy { $0.isDayBoundary })
        // Tick count must stay flat/bounded — nowhere near the 20,000 row count.
        #expect(ticks.count < 100)
    }

    @Test("day boundaries are marked on the first tick of each new day")
    func dayBoundariesMarked() {
        // 3 items today, then a gap of a day, then 3 more — small enough to stay in the
        // item-tier so each item keeps its own tick.
        let today = Self.base
        let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: today)!
        let items = [
            Fixture(scrubberID: 0, scrubberCreatedAt: today, scrubberAppBundleID: "com.a"),
            Fixture(scrubberID: 1, scrubberCreatedAt: today.addingTimeInterval(-60), scrubberAppBundleID: "com.a"),
            Fixture(scrubberID: 2, scrubberCreatedAt: yesterday, scrubberAppBundleID: "com.a"),
            Fixture(scrubberID: 3, scrubberCreatedAt: yesterday.addingTimeInterval(-60), scrubberAppBundleID: "com.a"),
        ]
        let ticks = HistoryScrubberModel.ticks(for: items, calendar: Self.calendar)
        #expect(ticks[0].isDayBoundary)
        #expect(!ticks[1].isDayBoundary)
        #expect(ticks[2].isDayBoundary)
        #expect(!ticks[3].isDayBoundary)
        #expect(ticks[0].dayLabel != nil)
        #expect(ticks[2].dayLabel != nil)
    }

    @Test("activeTickID picks the tick matching or preceding the visible item")
    func activeTickMatchesVisibleItem() {
        let items = makeItems(count: 5, minutesApart: 10)
        let ticks = HistoryScrubberModel.ticks(for: items, calendar: Self.calendar)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.scrubberID, $0.scrubberCreatedAt) })
        // Visible item is the 3rd (index 2); active tick should be that item's own tick since
        // every item has its own tick at this scale.
        let active = HistoryScrubberModel.activeTickID(ticks: ticks, visibleID: 2, allItemsByID: byID)
        #expect(active == 2)
    }

    @Test("activeTickID falls back to the first tick when visibleID is nil or unknown")
    func activeTickFallsBackToFirst() {
        let items = makeItems(count: 5)
        let ticks = HistoryScrubberModel.ticks(for: items, calendar: Self.calendar)
        #expect(HistoryScrubberModel.activeTickID(ticks: ticks, visibleID: nil, allItemsByID: [:]) == ticks.first?.id)
        #expect(HistoryScrubberModel.activeTickID(ticks: ticks, visibleID: 999, allItemsByID: [:]) == ticks.first?.id)
    }

    @Test("dayLabel matches today/yesterday/formatted-date rules")
    func dayLabelRules() {
        let now = Self.base
        #expect(HistoryScrubberModel.dayLabel(for: now, calendar: Self.calendar, now: now) == "Today")
        let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now)!
        #expect(HistoryScrubberModel.dayLabel(for: yesterday, calendar: Self.calendar, now: now) == "Yesterday")
        let lastWeek = Self.calendar.date(byAdding: .day, value: -7, to: now)!
        let label = HistoryScrubberModel.dayLabel(for: lastWeek, calendar: Self.calendar, now: now)
        #expect(label != "Today")
        #expect(label != "Yesterday")
    }
}
