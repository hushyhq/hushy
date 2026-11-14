import Foundation
import Testing
@testable import MurmurCore

/// `DateAnchor` resolves only against the injected `DateContext`. The old version shifted
/// `NSDataDetector`'s answer (resolved against the real clock) by (fixed now − real now), which
/// put weekday phrases on the wrong day whenever the two fell on different weekdays. These tests
/// pin "now" to fixed dates years away from the real clock, across every weekday, month and year
/// ends, a leap day, and both DST changes.
@Suite("DateAnchor")
struct DateAnchorTests {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    private static func context(_ iso: String, _ zone: TimeZone, locale: String = "en_US") -> DateContext {
        DateContext(now: RelativeDateParserTests.date(iso), timeZone: zone, locale: Locale(identifier: locale))
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    // MARK: Basics (kept from the NSDataDetector version)

    @Test("resolves a simple time phrase")
    func resolvesTime() {
        #expect(DateAnchor.firstDate(in: "let's meet at 3pm", context: Self.context("2031-06-04T10:00:00Z", Self.utc)) != nil)
    }

    @Test("returns nil for text with no date or time")
    func returnsNilForNoDate() {
        #expect(DateAnchor.firstDate(in: "buy milk and eggs", context: Self.context("2031-06-04T10:00:00Z", Self.utc)) == nil)
    }

    @Test("applies the default 30-minute length when none is stated")
    func defaultDuration() throws {
        let anchor = try #require(DateAnchor.firstDate(in: "dentist tomorrow at 3pm", context: Self.context("2031-06-04T10:00:00Z", Self.utc)))
        #expect(anchor.end.map { $0.timeIntervalSince(anchor.start) } == DateAnchor.defaultDurationSeconds)
    }

    @Test("empty text returns nil")
    func emptyText() {
        #expect(DateAnchor.firstDate(in: "  ", context: Self.context("2031-06-04T10:00:00Z", Self.utc)) == nil)
    }

    // MARK: Weekdays from every weekday (the injected-clock bug)

    /// Monday 2031-06-02 … Sunday 2031-06-08, 10:00 in Kolkata.
    static let week = (2...8).map { String(format: "2031-06-%02dT10:00:00+05:30", $0) }

    @Test("\"on friday\" is the next Friday after today, whatever weekday today is", arguments: week)
    func nextFriday(_ now: String) throws {
        let context = Self.context(now, Self.kolkata, locale: "en_IN")
        let calendar = Self.calendar(Self.kolkata)
        let today = calendar.startOfDay(for: context.now)
        for phrase in ["on friday", "friday", "next friday", "remind me friday to call amma"] {
            let anchor = try #require(DateAnchor.firstDate(in: phrase, context: context))
            #expect(calendar.component(.weekday, from: anchor.start) == 6, "\(phrase) from \(now)")
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: anchor.start)).day ?? -1
            #expect((1...7).contains(days), "\(phrase) from \(now) is \(days) days ahead")
        }
    }

    @Test("\"this sunday\" counts today; \"sunday\" does not", arguments: week)
    func thisSunday(_ now: String) throws {
        let context = Self.context(now, Self.kolkata)
        let calendar = Self.calendar(Self.kolkata)
        let today = calendar.startOfDay(for: context.now)
        let this = try #require(DateAnchor.firstDate(in: "this sunday at 6 pm", context: context))
        let bare = try #require(DateAnchor.firstDate(in: "sunday at 6 pm", context: context))
        let thisDays = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: this.start)).day ?? -1
        let bareDays = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: bare.start)).day ?? -1
        #expect((0...6).contains(thisDays))
        #expect((1...7).contains(bareDays))
        #expect(calendar.component(.hour, from: bare.start) == 18)
    }

    @Test("the model's anchor hint names the injected day, not the real one")
    func anchorHintUsesContext() {
        let context = Self.context("2031-06-04T10:00:00+05:30", Self.kolkata)  // a Wednesday
        let anchor = DateAnchor.firstDate(in: "tomorrow at 9", context: context)
        #expect(ActionExtractor.anchorHint(anchor, context: context).contains("Thursday, June 5, 2031 at 9:00 AM"))
    }

    // MARK: Month and year ends

    @Test("month ends, year ends and leap days")
    func monthEnds() {
        func start(_ phrase: String, _ now: String, _ zone: TimeZone = Self.utc) -> Date? {
            DateAnchor.firstDate(in: phrase, context: Self.context(now, zone))?.start
        }
        let date = RelativeDateParserTests.date
        #expect(start("tomorrow at 9", "2027-01-31T10:00:00Z") == date("2027-02-01T09:00:00Z"))
        #expect(start("in 2 days", "2027-01-31T10:00:00Z") == date("2027-02-02T09:00:00Z"))
        // February has no 30th: the next one is in March.
        #expect(start("on the 30th", "2027-02-01T10:00:00Z") == date("2027-03-30T09:00:00Z"))
        #expect(start("on the 29th", "2027-02-10T10:00:00Z") == date("2027-03-29T09:00:00Z"))
        #expect(start("tomorrow", "2028-02-28T12:00:00Z") == date("2028-02-29T09:00:00Z"))
        #expect(start("on the 1st", "2027-12-15T12:00:00Z") == date("2028-01-01T09:00:00Z"))
        #expect(start("tomorrow at 9", "2027-12-31T22:00:00-05:00", Self.newYork) == date("2028-01-01T09:00:00-05:00"))
        #expect(start("next week", "2027-12-31T22:00:00-05:00", Self.newYork) == date("2028-01-03T09:00:00-05:00"))
    }

    // MARK: Daylight saving time (America/New_York)

    @Test("day phrases keep the wall-clock time across the fall-back change")
    func fallBack() {
        let context = Self.context("2026-10-31T20:00:00-04:00", Self.newYork)
        #expect(DateAnchor.firstDate(in: "tomorrow at 9", context: context)?.start == RelativeDateParserTests.date("2026-11-01T09:00:00-05:00"))
        #expect(DateAnchor.firstDate(in: "sunday at 9 am", context: context)?.start == RelativeDateParserTests.date("2026-11-01T09:00:00-05:00"))
    }

    @Test("elapsed spans are real elapsed time across both changes")
    func elapsedAcrossDST() {
        let fall = Self.context("2026-11-01T00:30:00-04:00", Self.newYork)
        #expect(DateAnchor.firstDate(in: "in 3 hours", context: fall)?.start == RelativeDateParserTests.date("2026-11-01T02:30:00-05:00"))
        let spring = Self.context("2027-03-14T00:30:00-05:00", Self.newYork)
        #expect(DateAnchor.firstDate(in: "in 3 hours", context: spring)?.start == RelativeDateParserTests.date("2027-03-14T04:30:00-04:00"))
    }

    @Test("spring forward: day phrases land on the new offset; a skipped time moves forward, not back a day")
    func springForward() throws {
        let context = Self.context("2027-03-13T21:00:00-05:00", Self.newYork)
        #expect(DateAnchor.firstDate(in: "tomorrow at 9", context: context)?.start == RelativeDateParserTests.date("2027-03-14T09:00:00-04:00"))
        let skipped = try #require(DateAnchor.firstDate(in: "tomorrow at 2:30 am", context: context))
        let calendar = Self.calendar(Self.newYork)
        #expect(calendar.component(.day, from: skipped.start) == 14)
        #expect(calendar.component(.hour, from: skipped.start) == 3)
    }

    // MARK: NSDataDetector fallback

    @Test("the detector fallback only takes absolute dates and rebuilds them in the context")
    func detectorFallbackIsAbsoluteOnly() {
        let context = Self.context("2031-06-04T10:00:00Z", Self.utc)
        // A relative phrase would come back anchored to the real clock: never used.
        #expect(DateAnchor.detectedAbsoluteDate(in: "tomorrow at 9", context: context) == nil)
        let absolute = DateAnchor.detectedAbsoluteDate(in: "the launch is on July 20, 2031 at 4pm", context: context)
        #expect(absolute?.start == RelativeDateParserTests.date("2031-07-20T16:00:00Z"))
    }
}
