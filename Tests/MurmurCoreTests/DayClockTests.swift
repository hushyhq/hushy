import Foundation
import Observation
import Testing
@testable import MurmurCore

@MainActor
@Suite("Day clock")
struct DayClockTests {
    private static let zone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        DateComponents(calendar: calendar, timeZone: zone, year: 2026, month: 10, day: day, hour: hour, minute: minute).date ?? Date()
    }

    /// A clock whose "now" the test moves by hand.
    private final class Hand: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeClock(_ hand: Hand, center: NotificationCenter = NotificationCenter(), name: Notification.Name = .init("test.tick"))
        -> DayClock {
        DayClock(sources: [.init(center: center, name: name)], now: { hand.now }, calendar: { Self.calendar })
    }

    /// Notification delivery is queued on the main queue; give it a bounded number of turns.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("starts on the day of the injected clock")
    func startsOnToday() {
        let clock = makeClock(Hand(Self.date(5, 12, 30)))
        #expect(clock.day == Self.calendar.startOfDay(for: Self.date(5, 12, 30)))
        #expect(clock.now == Self.date(5, 12, 30))
    }

    @Test("refresh across midnight moves the day")
    func refreshAcrossMidnight() {
        let hand = Hand(Self.date(5, 23, 59))
        let clock = makeClock(hand)
        hand.now = Self.date(6, 0, 1)
        clock.refresh()
        #expect(clock.day == Self.calendar.startOfDay(for: Self.date(6, 0, 1)))
    }

    @Test("refresh within the same day updates now but not the day")
    func refreshSameDay() {
        let hand = Hand(Self.date(5, 9, 0))
        let clock = makeClock(hand)
        let day = clock.day
        hand.now = Self.date(5, 15, 0)
        clock.refresh()
        #expect(clock.day == day)
        #expect(clock.now == Self.date(5, 15, 0))
    }

    @Test("a time zone change moves the day without the instant changing")
    func timeZoneChange() {
        let hand = Hand(Self.date(5, 22, 0))
        var zone = Self.zone
        let clock = DayClock(
            sources: [], now: { hand.now },
            calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                return calendar
            })
        let before = clock.day
        zone = TimeZone(identifier: "Pacific/Auckland") ?? .gmt
        clock.refresh()
        #expect(clock.day != before)
    }

    @Test("a posted notification refreshes the clock")
    func notificationRefreshes() async {
        let center = NotificationCenter()
        let name = Notification.Name("test.dayChanged")
        let hand = Hand(Self.date(5, 23, 59))
        let clock = makeClock(hand, center: center, name: name)
        hand.now = Self.date(6, 0, 1)
        center.post(name: name, object: nil)
        await settle { clock.day == Self.calendar.startOfDay(for: Self.date(6, 0, 1)) }
        #expect(clock.day == Self.calendar.startOfDay(for: Self.date(6, 0, 1)))
    }

    @Test("onDayChange runs once per new day, not on a same-day refresh")
    func dayChangeHook() {
        let hand = Hand(Self.date(5, 23, 59))
        let clock = makeClock(hand, center: NotificationCenter(), name: Notification.Name("test.hook"))
        var calls = 0
        clock.onDayChange = { calls += 1 }
        clock.refresh()
        #expect(calls == 0)
        hand.now = Self.date(6, 0, 1)
        clock.refresh()
        clock.refresh()
        #expect(calls == 1)
    }

    @Test("observers of the day are told when it changes")
    func observationFires() async {
        let center = NotificationCenter()
        let name = Notification.Name("test.wake")
        let hand = Hand(Self.date(5, 23, 59))
        let clock = makeClock(hand, center: center, name: name)
        let fired = Flag()
        withObservationTracking { _ = clock.day } onChange: { fired.value = true }
        hand.now = Self.date(6, 0, 1)
        center.post(name: name, object: nil)
        await settle { fired.value }
        #expect(fired.value)
    }
}

/// A flag the (Sendable) observation callback can set. Only the main actor reads it.
private final class Flag: @unchecked Sendable {
    nonisolated(unsafe) var value = false
}
