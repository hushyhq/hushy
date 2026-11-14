import Foundation
import Testing
@testable import MurmurCore

/// Lightweight fixture conforming to `HistoryGroupable`, so grouping tests don't need to build
/// full `Dictation` rows.
private struct Fixture: HistoryGroupable, Equatable {
    let groupID: Int64
    let groupCreatedAt: Date
    let groupAppBundleID: String?
}

@Suite("HistoryGrouping")
struct HistoryGroupingTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixture(_ id: Int64, offsetSeconds: TimeInterval, app: String?) -> Fixture {
        Fixture(groupID: id, groupCreatedAt: Self.base.addingTimeInterval(offsetSeconds), groupAppBundleID: app)
    }

    @Test("empty input produces no runs")
    func emptyInput() {
        let runs = HistoryGrouping.runs(from: [Fixture]())
        #expect(runs.isEmpty)
    }

    @Test("consecutive same-app items within the gap stay in one run")
    func sameAppStaysTogether() {
        let items = [
            fixture(1, offsetSeconds: 0, app: "com.a"),
            fixture(2, offsetSeconds: 60, app: "com.a"),
            fixture(3, offsetSeconds: 120, app: "com.a"),
        ]
        let runs = HistoryGrouping.runs(from: items)
        #expect(runs.count == 1)
        #expect(runs[0].items.map(\.groupID) == [1, 2, 3])
        #expect(runs[0].appBundleID == "com.a")
    }

    @Test("app change breaks a run")
    func appChangeBreaks() {
        let items = [
            fixture(1, offsetSeconds: 0, app: "com.a"),
            fixture(2, offsetSeconds: 30, app: "com.a"),
            fixture(3, offsetSeconds: 60, app: "com.b"),
            fixture(4, offsetSeconds: 90, app: "com.b"),
        ]
        let runs = HistoryGrouping.runs(from: items)
        #expect(runs.count == 2)
        #expect(runs[0].items.map(\.groupID) == [1, 2])
        #expect(runs[0].appBundleID == "com.a")
        #expect(runs[1].items.map(\.groupID) == [3, 4])
        #expect(runs[1].appBundleID == "com.b")
    }

    @Test("nil app bundle id is treated as its own consistent group")
    func nilBundleIDGroupsTogether() {
        let items = [
            fixture(1, offsetSeconds: 0, app: nil),
            fixture(2, offsetSeconds: 30, app: nil),
        ]
        let runs = HistoryGrouping.runs(from: items)
        #expect(runs.count == 1)
        #expect(runs[0].appBundleID == nil)
    }

    @Test("nil-to-named app bundle id change still breaks a run")
    func nilToNamedBreaks() {
        let items = [
            fixture(1, offsetSeconds: 0, app: nil),
            fixture(2, offsetSeconds: 30, app: "com.a"),
        ]
        let runs = HistoryGrouping.runs(from: items)
        #expect(runs.count == 2)
    }

    @Test("exactly a 30-minute gap does not break a run")
    func exactlyThirtyMinuteGapStaysTogether() {
        let items = [
            fixture(1, offsetSeconds: 0, app: "com.a"),
            fixture(2, offsetSeconds: -1_800, app: "com.a"), // 30:00 before, same as "after" once abs()'d
        ]
        let runs = HistoryGrouping.runs(from: items)
        #expect(runs.count == 1)
    }

    @Test("a 31-minute gap breaks a run")
    func thirtyOneMinuteGapBreaks() {
        let items = [
            fixture(1, offsetSeconds: 0, app: "com.a"),
            fixture(2, offsetSeconds: -1_860, app: "com.a"), // 31:00 gap
        ]
        let runs = HistoryGrouping.runs(from: items)
        #expect(runs.count == 2)
    }

    @Test("a custom maxGap is respected")
    func customMaxGap() {
        let items = [
            fixture(1, offsetSeconds: 0, app: "com.a"),
            fixture(2, offsetSeconds: -300, app: "com.a"), // 5 minutes
        ]
        let runsDefault = HistoryGrouping.runs(from: items)
        #expect(runsDefault.count == 1)
        let runsTight = HistoryGrouping.runs(from: items, maxGap: 60)
        #expect(runsTight.count == 2)
    }

    @Test("a long run of many consecutive same-app items collapses into a single run")
    func longRunCollapses() {
        let items = (0..<30).map { fixture(Int64($0), offsetSeconds: Double($0) * 10, app: "com.claude") }
        let runs = HistoryGrouping.runs(from: items)
        #expect(runs.count == 1)
        #expect(runs[0].items.count == 30)
    }

    @Test("alternating apps produce one run per item")
    func alternatingAppsProduceManyRuns() {
        let items = (0..<6).map { fixture(Int64($0), offsetSeconds: Double($0) * 10, app: $0 % 2 == 0 ? "com.a" : "com.b") }
        let runs = HistoryGrouping.runs(from: items)
        #expect(runs.count == 6)
        for run in runs { #expect(run.items.count == 1) }
    }
}
