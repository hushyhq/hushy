import Foundation
import Testing
@testable import MurmurCore

/// A stored time that is not a real number of seconds (NaN, infinite, past Int) must not crash the
/// meeting page or an answer's link.
@Suite("Meeting times that are not numbers")
struct MeetingTimeGuardTests {
    private func quote(at seconds: Double?) -> MemoryQuote {
        MemoryQuote(noteId: 7, ordinal: 0, speaker: nil, startSeconds: seconds, text: "We ship Friday")
    }

    @Test("a quote links to its second when the time is real")
    func realTime() {
        #expect(quote(at: 125.9).link.absoluteString == "hushy://note/7?t=125")
        #expect(quote(at: nil).link.absoluteString == "hushy://note/7")
    }

    @Test("a quote whose time is not a usable number links to the meeting itself", arguments: [
        Double.nan, .infinity, -.infinity, 1e300, -4,
    ])
    func unusableTime(seconds: Double) {
        #expect(quote(at: seconds).link.absoluteString == "hushy://note/7")
    }

    @Test("the moment label reads 0:00 for a time that is not a usable number", arguments: [
        Double.nan, .infinity, -.infinity, 1e300, -4,
    ])
    func unusableClock(seconds: Double) {
        #expect(MeetingMoment.clock(seconds) == "0:00")
        #expect(MeetingMoment(seconds: seconds, lineIndex: nil, speaker: nil).label == "0:00")
    }

    @Test("real times still read as a clock")
    func realClock() {
        #expect(MeetingMoment.clock(3_725.4) == "1:02:05")
        #expect(MeetingMoment.clock(0) == "0:00")
    }
}
