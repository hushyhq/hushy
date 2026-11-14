import Foundation
import Testing
@testable import MurmurCore

/// The day rule across daylight-saving changes: the calendar day in the Mac's time zone at the
/// moment of the event, so a 23-hour or 25-hour day is still one day.
@Suite("Usage metrics: day rule and daylight saving")
struct UsageMetricsDayRuleTests {
    typealias F = UsageMetricsFixtures

    private let newYork: TimeZone = TimeZone(identifier: "America/New_York") ?? .gmt

    private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return try #require(calendar.date(from: parts))
    }

    private func batchesByDay(recording dates: [Date], closeAt now: Date) async throws -> [String: Int] {
        let directory = try F.tempDirectory()
        let zone = newYork
        let svc = UsageMetricsService(
            directory: directory, appBuild: 412, firstRunDay: nil, environment: F.environment,
            timeZone: { zone }, gate: MetricsSwitch(isOn: true))
        for date in dates { await svc.record(.dictation(F.dictation()), at: date) }
        _ = await svc.closeDays(now: now)
        let queued = try await svc.queue.nextBatchesToSend(limit: 20, now: now)
        return Dictionary(uniqueKeysWithValues: queued.map { ($0.day.isoString, $0.combinedDictations.count) })
    }

    @Test("spring forward (a 23-hour day): events before and after the jump, and late evening, stay on their local day")
    func springForward() async throws {
        let dates = [
            try local(2026, 3, 8, 1, 30),     // EST, before the clocks jump
            try local(2026, 3, 8, 3, 30),     // EDT, an hour of the clock later but 1 real hour after
            try local(2026, 3, 8, 23, 59),    // 03:59 UTC on the 9th, still the 8th here
            try local(2026, 3, 9, 0, 30),
        ]
        let days = try await batchesByDay(recording: dates, closeAt: try local(2026, 3, 10, 9, 0))
        #expect(days == ["2026-03-08": 3, "2026-03-09": 1])
    }

    @Test("fall back (a 25-hour day): both 1:30 am events, the evening one and the next morning land on the right days")
    func fallBack() async throws {
        let firstHalfPastOne = try local(2026, 11, 1, 1, 30)   // the first 1:30 (EDT)
        let dates = [
            try local(2026, 11, 1, 0, 30),
            firstHalfPastOne,
            firstHalfPastOne.addingTimeInterval(3_600),        // the second 1:30 (EST)
            try local(2026, 11, 1, 23, 30),
            try local(2026, 11, 2, 0, 30),
        ]
        let days = try await batchesByDay(recording: dates, closeAt: try local(2026, 11, 3, 9, 0))
        #expect(days == ["2026-11-01": 4, "2026-11-02": 1])
    }

    @Test("an event just after local midnight is the new day, even though UTC is still the old one")
    func localMidnightNotUTC() async throws {
        let days = try await batchesByDay(
            recording: [try local(2026, 10, 3, 23, 50), try local(2026, 10, 4, 0, 10)], closeAt: try local(2026, 10, 6, 9, 0))
        #expect(days == ["2026-10-03": 1, "2026-10-04": 1])
    }
}
