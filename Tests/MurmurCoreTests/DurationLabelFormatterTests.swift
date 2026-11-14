import Testing
@testable import MurmurCore

@Suite("Duration label formatting")
struct DurationLabelFormatterTests {
    @Test("Under a minute shows seconds")
    func seconds() {
        #expect(DurationLabelFormatter.label(seconds: 45) == "45 s")
        #expect(DurationLabelFormatter.label(seconds: 0) == "0 s")
        #expect(DurationLabelFormatter.label(seconds: 1) == "1 s")
        #expect(DurationLabelFormatter.label(seconds: 59) == "59 s")
    }

    @Test("Fractional seconds round to the nearest whole second")
    func fractionalSeconds() {
        #expect(DurationLabelFormatter.label(seconds: 44.4) == "44 s")
        #expect(DurationLabelFormatter.label(seconds: 44.6) == "45 s")
    }

    @Test("A minute and over shows minutes, never a clock-style 10:12")
    func minutes() {
        #expect(DurationLabelFormatter.label(seconds: 60) == "1 min")
        #expect(DurationLabelFormatter.label(seconds: 600) == "10 min")
        #expect(DurationLabelFormatter.label(seconds: 35 * 60) == "35 min")
    }

    @Test("59.6 seconds rounds up to 1 min rather than showing 60 s")
    func roundsUpToAMinute() {
        #expect(DurationLabelFormatter.label(seconds: 59.6) == "1 min")
    }

    @Test("59.98 minutes rounds up to 1 h rather than showing 60 min")
    func roundsUpToAnHour() {
        #expect(DurationLabelFormatter.label(seconds: 3599) == "1 h")
    }

    @Test("An hour and over shows hours and minutes")
    func hoursAndMinutes() {
        #expect(DurationLabelFormatter.label(seconds: 3600) == "1 h")
        #expect(DurationLabelFormatter.label(seconds: 3600 + 5 * 60) == "1 h 5 min")
        #expect(DurationLabelFormatter.label(seconds: 2 * 3600) == "2 h")
    }

    @Test("Minutes roll over into a new hour")
    func minutesRollOverIntoHour() {
        // 59 min 45 s rounds to 60 min, which should read as "1 h", not "60 min".
        #expect(DurationLabelFormatter.label(seconds: 59 * 60 + 45) == "1 h")
    }

    @Test("Negative input clamps to zero")
    func negativeClampsToZero() {
        #expect(DurationLabelFormatter.label(seconds: -5) == "0 s")
    }
}
