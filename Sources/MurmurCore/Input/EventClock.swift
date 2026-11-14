import Darwin
import Foundation

/// When an input event happened, read from the time stamp the system put on it, so a press and its
/// release are told apart by when they happened and not by when some thread got round to them.
///
/// `CGEvent.timestamp` is documented as nanoseconds of uptime, but on Apple silicon it is mach
/// ticks (one tick is 125/3 ns). Both count the same uptime clock, so a stamp is read in whichever
/// unit puts it nearer the clock's reading now. On Intel the two units are the same.
public enum EventClock {
    /// The clocks, read together once at the moment an event is looked at.
    public struct Reading: Sendable, Equatable {
        public let date: Date
        public let uptimeNanoseconds: UInt64
        public let machTicks: UInt64

        public init(date: Date, uptimeNanoseconds: UInt64, machTicks: UInt64) {
            self.date = date
            self.uptimeNanoseconds = uptimeNanoseconds
            self.machTicks = machTicks
        }

        public static func now() -> Reading {
            Reading(date: Date(), uptimeNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                    machTicks: mach_absolute_time())
        }
    }

    /// A stamp further than this from the reading in both units is no uptime stamp (a synthetic
    /// event carries 0), and the event is taken to have happened at the reading.
    public static let plausibleAge: TimeInterval = 10

    /// Nanoseconds per mach tick, as numerator and denominator.
    public static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// How long before `reading` the stamped event happened, in nanoseconds; nil when the stamp
    /// is in neither unit. Never negative: a stamp a hair after the reading happened at it.
    public static func ageNanoseconds(ofStamp stamp: UInt64, at reading: Reading,
                                      timebase: (numer: UInt64, denom: UInt64) = timebase) -> Double? {
        let asNanoseconds = Double(reading.uptimeNanoseconds) - Double(stamp)
        let asTicks = (Double(reading.machTicks) - Double(stamp)) * Double(timebase.numer) / Double(timebase.denom)
        let age = abs(asTicks) < abs(asNanoseconds) ? asTicks : asNanoseconds
        guard abs(age) <= plausibleAge * 1e9 else { return nil }
        return max(0, age)
    }

    /// The wall-clock moment the stamped event happened.
    public static func date(ofStamp stamp: UInt64, at reading: Reading,
                            timebase: (numer: UInt64, denom: UInt64) = timebase) -> Date {
        guard let age = ageNanoseconds(ofStamp: stamp, at: reading, timebase: timebase) else { return reading.date }
        return reading.date.addingTimeInterval(-age / 1e9)
    }

    /// The stamp as seconds of uptime, for recognisers that only compare stamps with each other. A
    /// stamp in neither unit is read as nanoseconds, the documented unit.
    public static func uptimeSeconds(ofStamp stamp: UInt64, at reading: Reading,
                                     timebase: (numer: UInt64, denom: UInt64) = timebase) -> TimeInterval {
        guard let age = ageNanoseconds(ofStamp: stamp, at: reading, timebase: timebase) else { return Double(stamp) / 1e9 }
        return (Double(reading.uptimeNanoseconds) - age) / 1e9
    }
}
