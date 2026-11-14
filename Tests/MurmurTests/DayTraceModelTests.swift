import Foundation
import Testing
@testable import Murmur

/// Home's Today trace bucketing: 20-minute slots from the waking day's start to midnight.
@Suite("Day trace — today's speech as a trace")
struct DayTraceModelTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 27) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test("an empty day starts at 6 AM, has 54 slots, and nothing lit")
    func emptyDay() {
        let model = DayTraceModel(spoken: [], now: at(14, 30), calendar: calendar)
        #expect(model.startHour == 6)
        #expect(model.buckets.count == 54)
        #expect(model.buckets.allSatisfy { $0 == 0 })
        #expect(model.latestActiveIndex == nil)
        #expect(model.accessibilitySummary.contains("nothing said yet"))
    }

    @Test("speech lands in its 20-minute slot; the newest slot is the afterglow")
    func bucketing() {
        let spoken = [(at: at(9, 5), seconds: 30.0), (at: at(9, 15), seconds: 10.0), (at: at(14, 45), seconds: 10.0)]
        let model = DayTraceModel(spoken: spoken, now: at(15, 0), calendar: calendar)
        #expect(model.buckets[9] == 1) // 9:00–9:20 → (9-6)*3 = 9, 40 s is the peak
        #expect(model.buckets[26] == (10.0 / 40.0).squareRoot()) // 14:40–15:00
        #expect(model.latestActiveIndex == 26)
        #expect(model.nowIndex == 27)
        #expect(model.totalSeconds == 50)
    }

    @Test("an early start widens the window; other days are ignored")
    func earlyStartAndOtherDays() {
        let spoken = [(at: at(4, 10), seconds: 5.0), (at: at(10, 0, day: 26), seconds: 99.0)]
        let model = DayTraceModel(spoken: spoken, now: at(8, 0), calendar: calendar)
        #expect(model.startHour == 4)
        #expect(model.buckets.count == 60)
        #expect(model.buckets[0] == 1)
        #expect(model.totalSeconds == 5)
    }

    @Test("hour marks sit strictly inside the window")
    func hourMarks() {
        let model = DayTraceModel(spoken: [], now: at(12), calendar: calendar)
        #expect(model.hourMarks == [9, 12, 15, 18, 21])
        #expect(model.fraction(ofHour: 15) == 0.5)
    }
}
