import Foundation

/// One tick along the History scrubber. A tick represents either a single dictation, a whole
/// run (see `HistoryGrouping`), or a fixed time bucket, depending on how many items are loaded
/// — see `HistoryScrubberModel.ticks(for:)`'s doc comment for the exact thresholds. `anchorID`
/// is the id of the first (newest) item the tick represents, used to scroll the list and to
/// decide which tick is "active" for a given visible row.
public struct HistoryTick: Identifiable, Equatable {
    public enum Kind: Equatable {
        /// One dictation.
        case item
        /// A run of consecutive same-app dictations (see `HistoryGrouping`).
        case run
        /// A fixed time bucket covering many items, used only past the high-volume threshold.
        case bucket
    }

    public let id: Int64
    public let kind: Kind
    public let anchorID: Int64
    public let createdAt: Date
    public let timeLabel: String
    public let firstLine: String
    /// True for the first tick of a new calendar day — the scrubber draws these slightly
    /// longer and can attach a day label ("Today", "Yesterday", or a formatted date).
    public let isDayBoundary: Bool
    public let dayLabel: String?
    /// How many underlying dictations this tick stands for (1 for `.item`, run/bucket size
    /// otherwise) — surfaced so the tooltip can say "12 recordings" instead of showing just one.
    public let itemCount: Int

    public init(
        id: Int64, kind: Kind, anchorID: Int64, createdAt: Date, timeLabel: String, firstLine: String,
        isDayBoundary: Bool, dayLabel: String?, itemCount: Int
    ) {
        self.id = id
        self.kind = kind
        self.anchorID = anchorID
        self.createdAt = createdAt
        self.timeLabel = timeLabel
        self.firstLine = firstLine
        self.isDayBoundary = isDayBoundary
        self.dayLabel = dayLabel
        self.itemCount = itemCount
    }
}

/// Minimal shape the scrubber needs from a loaded row, independent of `HistoryRowModel` (a
/// `Murmur`-target type) so this stays testable from MurmurCore alone.
public protocol HistoryScrubbable {
    var scrubberID: Int64 { get }
    var scrubberCreatedAt: Date { get }
    var scrubberTimeLabel: String { get }
    var scrubberFirstLine: String { get }
    var scrubberAppBundleID: String? { get }
}

/// Pure bucketing + active-tick logic for the History scrubber (a Claude.ai-chat-outline-style
/// tick column — see `.claude/DECISIONS.md`, 2026-09-26 "History scrubber bucketing"). Kept
/// entirely free of SwiftUI/AppKit so it's unit-testable and so the view layer (`HistoryScrubber`
/// in the `Murmur` target) stays thin scroll-position glue on top.
public enum HistoryScrubberModel {
    /// Below this many loaded items, every item gets its own tick — at this scale (a handful of
    /// pages) per-item ticks stay readable and cheap to lay out.
    public static let itemTickThreshold = 120
    /// Between `itemTickThreshold` and this many items, one tick per *run* (consecutive
    /// same-app group) instead of per item — collapses noisy bursts (e.g. 30 dictations into
    /// the same app) into one tick each, while staying proportional to actual usage variety.
    public static let runTickThreshold = 1_000
    /// Above `runTickThreshold` (i.e. approaching the 20k-row worst case this was built for),
    /// switch to fixed per-day time buckets — a flat, small number of ticks regardless of how
    /// many rows are loaded, so a 20k-row history never asks SwiftUI to lay out thousands of
    /// tick views. Bucketing by day (rather than a fixed count of ticks) keeps the day-boundary
    /// labels meaningful at this scale too.
    public static let dayBucketThreshold = 20_000

    /// Builds the scrubber's tick list from already-loaded, newest-first items. `calendar` is
    /// injectable for tests; production callers use `.current`.
    ///
    /// Bucketing rule (documented here and in `.claude/DECISIONS.md`):
    /// - `count <= itemTickThreshold` (10): one tick per item.
    /// - `itemTickThreshold < count <= runTickThreshold` (1,000): one tick per run (see
    ///   `HistoryGrouping.runs`), computed per calendar day so a run never spans days.
    /// - `count > runTickThreshold`: one tick per calendar day (a single fixed time bucket per
    ///   day), regardless of how many items or runs that day holds. This keeps tick count
    ///   bounded by the number of distinct days in the loaded window, not by row count, so it
    ///   stays flat even at `dayBucketThreshold` (20,000) and beyond.
    public static func ticks<Item: HistoryScrubbable & Equatable>(
        for items: [Item], calendar: Calendar = .current, now: Date = Date()
    ) -> [HistoryTick] {
        guard !items.isEmpty else { return [] }

        if items.count <= itemTickThreshold {
            return items.enumerated().map { index, item in
                tick(for: item, kind: .item, itemCount: 1, isDayBoundary: isNewDay(items, index, calendar), calendar: calendar, now: now)
            }
        }

        // Group into calendar days first (newest first, matching `items`' own order), since
        // both the run-tick and day-bucket tiers key off day boundaries.
        var dayOrder: [Date] = []
        var byDay: [Date: [Item]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.scrubberCreatedAt)
            if byDay[day] == nil { dayOrder.append(day) }
            byDay[day, default: []].append(item)
        }

        if items.count <= runTickThreshold {
            var result: [HistoryTick] = []
            for day in dayOrder {
                let dayItems = byDay[day] ?? []
                let groupable = dayItems.map { ScrubbableGroupable(item: $0) }
                let runs = HistoryGrouping.runs(from: groupable)
                for (runIndex, run) in runs.enumerated() {
                    guard let first = run.items.first?.item else { continue }
                    result.append(tick(
                        for: first, kind: .run, itemCount: run.items.count,
                        isDayBoundary: runIndex == 0, calendar: calendar, now: now))
                }
            }
            return result
        }

        // Highest-volume tier: one tick per day.
        return dayOrder.map { day in
            let dayItems = byDay[day] ?? []
            let first = dayItems[0]
            return tick(for: first, kind: .bucket, itemCount: dayItems.count, isDayBoundary: true, calendar: calendar, now: now)
        }
    }

    /// Which tick should render as "active" (longer, `Theme.phosphor`-colored) for a given
    /// topmost-visible item id. Falls back to the first tick when `visibleID` isn't found (e.g.
    /// it belongs to a row collapsed into a run/bucket tick that isn't its own anchor) by
    /// matching on the nearest tick whose anchor is not after the visible item.
    public static func activeTickID(ticks: [HistoryTick], visibleID: Int64?, allItemsByID: [Int64: Date]) -> Int64? {
        guard let visibleID, let visibleDate = allItemsByID[visibleID] else { return ticks.first?.id }
        // Ticks are in newest-first order, same as items; the active tick is the last one
        // whose createdAt is >= the visible item's createdAt (i.e. the tick that "contains" or
        // immediately precedes the visible row going down the list).
        var candidate = ticks.first?.id
        for tick in ticks {
            if tick.createdAt >= visibleDate {
                candidate = tick.id
            } else {
                break
            }
        }
        return candidate
    }

    private static func isNewDay<Item: HistoryScrubbable>(_ items: [Item], _ index: Int, _ calendar: Calendar) -> Bool {
        guard index > 0 else { return true }
        return !calendar.isDate(items[index].scrubberCreatedAt, inSameDayAs: items[index - 1].scrubberCreatedAt)
    }

    private static func tick<Item: HistoryScrubbable>(
        for item: Item, kind: HistoryTick.Kind, itemCount: Int, isDayBoundary: Bool, calendar: Calendar, now: Date
    ) -> HistoryTick {
        HistoryTick(
            id: item.scrubberID, kind: kind, anchorID: item.scrubberID, createdAt: item.scrubberCreatedAt,
            timeLabel: item.scrubberTimeLabel, firstLine: item.scrubberFirstLine,
            isDayBoundary: isDayBoundary,
            dayLabel: isDayBoundary ? dayLabel(for: item.scrubberCreatedAt, calendar: calendar, now: now) : nil,
            itemCount: itemCount)
    }

    /// Shared today/yesterday/formatted-date labeling, factored out so both the scrubber and
    /// `HistoryDayHeader` (in `HistoryListContent.swift`) use the same rule instead of
    /// duplicating the calendar checks.
    public static func dayLabel(for date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// Bridges a `HistoryScrubbable` item into `HistoryGroupable` so `HistoryGrouping.runs` can be
/// reused for the scrubber's run-tier bucketing without duplicating the break-rule logic.
private struct ScrubbableGroupable<Item: HistoryScrubbable>: HistoryGroupable, Equatable {
    let item: Item
    var groupID: Int64 { item.scrubberID }
    var groupCreatedAt: Date { item.scrubberCreatedAt }
    var groupAppBundleID: String? { item.scrubberAppBundleID }

    static func == (lhs: ScrubbableGroupable<Item>, rhs: ScrubbableGroupable<Item>) -> Bool {
        lhs.item.scrubberID == rhs.item.scrubberID
    }
}
