import Foundation
import Testing
@testable import MurmurCore

/// An event's moment comes from its own time stamp, in whichever unit the system used: nanoseconds
/// of uptime or Apple silicon mach ticks (125/3 ns each). Readings are scripted; nothing sleeps.
@Suite("Event clock")
struct EventClockTests {
    private let appleSilicon: (numer: UInt64, denom: UInt64) = (125, 3)
    private let intel: (numer: UInt64, denom: UInt64) = (1, 1)
    private let wall = Date(timeIntervalSince1970: 1_000_000)

    /// The clocks 3 days after boot, on a Mac whose ticks are `timebase`.
    private func reading(_ timebase: (numer: UInt64, denom: UInt64), plusNanoseconds extra: UInt64 = 0) -> EventClock.Reading {
        let uptime: UInt64 = 3 * 86_400 * 1_000_000_000 + extra
        return EventClock.Reading(date: wall.addingTimeInterval(Double(extra) / 1e9), uptimeNanoseconds: uptime,
                                  machTicks: uptime * timebase.denom / timebase.numer)
    }

    @Test("a stamp in mach ticks is read as ticks: 80 ms ago is 80 ms ago")
    func ticks() {
        let now = reading(appleSilicon)
        let stamp = now.machTicks - 80_000_000 * 3 / 125
        let date = EventClock.date(ofStamp: stamp, at: now, timebase: appleSilicon)
        #expect(abs(date.timeIntervalSince(wall) + 0.08) < 1e-6)
    }

    @Test("a stamp in nanoseconds is read as nanoseconds on the same Mac")
    func nanoseconds() {
        let now = reading(appleSilicon)
        let date = EventClock.date(ofStamp: now.uptimeNanoseconds - 80_000_000, at: now, timebase: appleSilicon)
        #expect(abs(date.timeIntervalSince(wall) + 0.08) < 1e-6)
    }

    @Test("on Intel the two units agree")
    func intelTicks() {
        let now = reading(intel)
        let date = EventClock.date(ofStamp: now.machTicks - 250_000_000, at: now, timebase: intel)
        #expect(abs(date.timeIntervalSince(wall) + 0.25) < 1e-6)
    }

    @Test("a release read late is still dated when it happened, so a tap stays a tap")
    func lateReadKeepsTheEventTime() {
        let press = reading(appleSilicon)
        let releaseStamp = press.machTicks + 100_000_000 * 3 / 125
        let lateRead = reading(appleSilicon, plusNanoseconds: 400_000_000)
        let held = EventClock.date(ofStamp: releaseStamp, at: lateRead, timebase: appleSilicon)
            .timeIntervalSince(EventClock.date(ofStamp: press.machTicks, at: press, timebase: appleSilicon))
        #expect(abs(held - 0.1) < 1e-6, "held 100 ms, read 400 ms later: still 100 ms")
    }

    @Test("a synthetic stamp of 0, or one far from now, happened at the reading")
    func implausibleStamp() {
        let now = reading(appleSilicon)
        #expect(EventClock.date(ofStamp: 0, at: now, timebase: appleSilicon) == wall)
        #expect(EventClock.date(ofStamp: now.machTicks - 60 * 24_000_000, at: now, timebase: appleSilicon) == wall)
        #expect(EventClock.uptimeSeconds(ofStamp: 2_500_000_000, at: now, timebase: appleSilicon) == 2.5,
                "an implausible stamp keeps the documented unit")
    }

    @Test("a stamp a hair after the reading is dated at the reading, never in the future")
    func futureStamp() {
        let now = reading(appleSilicon)
        #expect(EventClock.date(ofStamp: now.machTicks + 24, at: now, timebase: appleSilicon) == wall)
    }

    @Test("uptime seconds compare a tick stamp and a nanosecond stamp of the same moment as equal")
    func uptimeSeconds() {
        let now = reading(appleSilicon)
        let fromTicks = EventClock.uptimeSeconds(ofStamp: now.machTicks - 2_400_000, at: now, timebase: appleSilicon)
        let fromNanoseconds = EventClock.uptimeSeconds(ofStamp: now.uptimeNanoseconds - 100_000_000, at: now,
                                                       timebase: appleSilicon)
        #expect(abs(fromTicks - fromNanoseconds) < 1e-6)
    }

    @Test("the live reading dates a stamp taken from the live clock to within a millisecond")
    func liveClock() {
        let stamp = mach_absolute_time()
        let date = EventClock.date(ofStamp: stamp, at: .now())
        #expect(abs(date.timeIntervalSinceNow) < 0.001)
    }
}
