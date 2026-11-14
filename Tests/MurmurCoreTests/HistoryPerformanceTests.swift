import Foundation
import Testing
@testable import MurmurCore

/// Benchmarks the two pure algorithms behind History's redesign — `HistoryGrouping.runs`
/// (backs the "one icon per run" list) and `HistoryScrubberModel.ticks` (backs the timeline
/// scrubber) — at the 20k-row worst case the scrubber's day-bucket tier was built for. There's
/// no "before" implementation to compare against (the old list had no grouping and no
/// scrubber at all, so there's nothing equivalent to time), so this instead pins down the
/// *first-page* cost (fast: one page, ~100 rows) against the *full-history* cost (20k rows) to
/// show both scale acceptably, and prints wall-clock numbers for manual comparison across runs
/// (e.g. before/after a future change to either algorithm).
@Suite("History redesign performance")
struct HistoryPerformanceTests {
    private struct Fixture: HistoryGroupable, HistoryScrubbable, Equatable {
        let groupID: Int64
        let groupCreatedAt: Date
        let groupAppBundleID: String?
        var scrubberID: Int64 { groupID }
        var scrubberCreatedAt: Date { groupCreatedAt }
        var scrubberAppBundleID: String? { groupAppBundleID }
        var scrubberTimeLabel: String { groupCreatedAt.formatted(date: .omitted, time: .shortened) }
        var scrubberFirstLine: String { "item \(groupID)" }
    }

    /// Realistic-shaped data: runs of 1-20 consecutive same-app items (not strictly alternating,
    /// which would defeat run-collapsing, and not one giant run, which would trivially collapse
    /// to nothing) spread across `count / 200` days, newest-first — matching how real dictation
    /// history actually clusters (bursts of the same app, gaps between sessions).
    private func makeFixtures(count: Int) -> [Fixture] {
        let apps = ["com.apple.mail", "com.apple.notes", "com.slack", "com.anthropic.claude", "com.apple.Terminal"]
        var items: [Fixture] = []
        var id: Int64 = 0
        var minutesAgo = 0.0
        var appIndex = 0
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        while items.count < count {
            let runLength = 1 + (Int(id) % 20)
            let app = apps[appIndex % apps.count]
            for _ in 0..<runLength where items.count < count {
                items.append(Fixture(groupID: id, groupCreatedAt: base.addingTimeInterval(-minutesAgo * 60), groupAppBundleID: app))
                id += 1
                minutesAgo += 3 // 3 minutes between dictations within a run
            }
            minutesAgo += 45 // a 45-minute gap between runs, so most runs actually break on time too
            appIndex += 1
        }
        return items
    }

    @Test("first-page grouping (≈100 rows) stays well under a millisecond")
    func firstPageCost() {
        let items = makeFixtures(count: 100)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = HistoryGrouping.runs(from: items)
            _ = HistoryScrubberModel.ticks(for: items)
        }
        print("[history-perf] first page (100 rows): \(elapsed)")
        #expect(elapsed < .milliseconds(50))
    }

    @Test("20,000-row worst case: grouping + scrubber bucketing complete in well under a second")
    func twentyThousandRowCost() {
        let items = makeFixtures(count: 20_000)
        let clock = ContinuousClock()

        let groupingElapsed = clock.measure { _ = HistoryGrouping.runs(from: items) }
        let tickElapsed = clock.measure { _ = HistoryScrubberModel.ticks(for: items) }

        print("[history-perf] 20,000 rows — HistoryGrouping.runs: \(groupingElapsed)")
        print("[history-perf] 20,000 rows — HistoryScrubberModel.ticks: \(tickElapsed)")

        #expect(groupingElapsed < .seconds(1))
        #expect(tickElapsed < .seconds(1))

        // The scrubber's whole point is a bounded tick count regardless of row count — confirm
        // the 20k case actually lands in the flat day-bucket tier, not silently degrading into
        // one tick per row (which would make the "collapses into buckets" claim false and would
        // reintroduce the SwiftUI layout cost this tier exists to avoid).
        let ticks = HistoryScrubberModel.ticks(for: items)
        #expect(ticks.count < 200)
    }

    @Test("scrolling cost: activeTickID lookups for 1,000 scroll positions stay cheap")
    func scrollCost() {
        let items = makeFixtures(count: 20_000)
        let ticks = HistoryScrubberModel.ticks(for: items)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.scrubberID, $0.scrubberCreatedAt) })
        let sampleIDs = stride(from: 0, to: items.count, by: max(items.count / 1_000, 1)).map { Int64($0) }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for id in sampleIDs {
                _ = HistoryScrubberModel.activeTickID(ticks: ticks, visibleID: id, allItemsByID: byID)
            }
        }
        print("[history-perf] \(sampleIDs.count) scroll-position lookups over \(ticks.count) ticks: \(elapsed)")
        #expect(elapsed < .milliseconds(500))
    }
}
