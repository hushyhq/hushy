import Testing
@testable import MurmurCore

/// When the recogniser re-reads a recording that is still going (`EarlyPassSchedule`).
@Suite("Early cleanup: when the recogniser takes another pass")
struct EarlyPassScheduleTests {
    private func starts(_ schedule: inout EarlyPassSchedule, upTo end: Double, passSeconds: Double = 0.1) -> [Double] {
        var out: [Double] = []
        var busyUntil = 0.0
        for t in stride(from: 2.0, through: end, by: 2.0) {
            if schedule.isRunning, busyUntil <= t { schedule.finished() }
            if schedule.start(at: t) {
                out.append(t)
                busyUntil = t + passSeconds
            }
        }
        return out
    }

    @Test("nothing runs before the first-pass time, so a short dictation costs nothing")
    func nothingEarly() {
        var schedule = EarlyPassSchedule(first: 10, gap: 2, stretch: 0)
        #expect(starts(&schedule, upTo: 8).isEmpty)
        #expect(schedule.passes == 0)
    }

    @Test("with no stretch a pass runs at every tick from the first-pass time")
    func everyTick() {
        var schedule = EarlyPassSchedule(first: 10, gap: 2, stretch: 0)
        #expect(starts(&schedule, upTo: 16) == [10, 12, 14, 16])
        #expect(schedule.passes == 4)
    }

    @Test("passes spread out as the recording grows")
    func stretched() {
        var schedule = EarlyPassSchedule(first: 10, gap: 2, stretch: 0.25)
        #expect(starts(&schedule, upTo: 60) == [10, 14, 18, 24, 30, 38, 48, 60])
    }

    @Test("a pass does not start while the one before it is still running")
    func neverTwoAtOnce() {
        var schedule = EarlyPassSchedule(first: 10, gap: 2, stretch: 0)
        #expect(starts(&schedule, upTo: 18, passSeconds: 2.5) == [10, 14, 18])
    }

    @Test("the defaults: first pass at ten seconds, two seconds apart, a tenth of the length once that is longer")
    func defaults() {
        let schedule = EarlyPassSchedule()
        #expect(schedule.first == 10)
        #expect(schedule.gap == 2)
        #expect(schedule.stretch == 0.1)
    }
}
