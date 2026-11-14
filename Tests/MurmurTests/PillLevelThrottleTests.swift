import Foundation
import Testing
@testable import Murmur

@Suite("Pill levels — at most one bar update per update interval of the reading's time")
@MainActor
struct PillLevelThrottleTests {
    private let start = Date(timeIntervalSinceReferenceDate: 812_932_200)

    @Test("readings closer than the update interval after the last update are smoothed in but move no bar")
    func closeReadingsAreThrottled() {
        let pill = PillModel()
        pill.push(rms: 0.05, now: start)
        pill.push(rms: 0.05, now: start.addingTimeInterval(0.01))
        pill.push(rms: 0.05, now: start.addingTimeInterval(PillModel.levelUpdateInterval - 0.001))
        #expect(pill.levelsUpdatedAt == start)
    }

    @Test("readings spaced wider than the update interval each move the bars")
    func spacedReadingsLand() {
        let pill = PillModel()
        for index in 0..<PillModel.barCount {
            pill.push(rms: 0.05, now: start.addingTimeInterval(Double(index) * 2 * PillModel.levelUpdateInterval))
        }
        #expect(pill.levelsUpdatedAt == start.addingTimeInterval(Double(PillModel.barCount - 1) * 2 * PillModel.levelUpdateInterval))
    }
}
