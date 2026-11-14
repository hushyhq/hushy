import Foundation
import Testing
@testable import MurmurCore

/// Spoken date phrases `NSDataDetector` dropped (the tools eval found reminders losing their
/// date: "in 3 hours", "at 4 15", "on the 10th", "by eod", "day after tomorrow", Indian-English
/// forms), resolved by `RelativeDateParser` against a fixed `DateContext`.
@Suite("RelativeDateParser")
struct RelativeDateParserTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let phrase: String
        /// ISO-8601 start in the context's zone; nil = no date.
        let start: String?
        var end: String?
        var testDescription: String { "\"\(phrase)\" → \(start ?? "nil")" }
    }

    /// Thursday 2027-02-11 15:20 in Chicago (CST, no DST change nearby), en_US.
    static let thursdayAfternoon = DateContext(
        now: date("2027-02-11T15:20:00-06:00"), timeZone: TimeZone(identifier: "America/Chicago")!, locale: Locale(identifier: "en_US"))

    static let relativeCases: [Case] = [
        Case(phrase: "in 3 hours", start: "2027-02-11T18:20:00-06:00"),
        Case(phrase: "in 10 minutes", start: "2027-02-11T15:30:00-06:00"),
        Case(phrase: "in an hour", start: "2027-02-11T16:20:00-06:00"),
        Case(phrase: "in half an hour", start: "2027-02-11T15:50:00-06:00"),
        Case(phrase: "in 90 minutes", start: "2027-02-11T16:50:00-06:00"),
        Case(phrase: "in a couple of hours", start: "2027-02-11T17:20:00-06:00"),
        Case(phrase: "in 2 and a half hours", start: "2027-02-11T17:50:00-06:00"),
        Case(phrase: "in twenty five minutes", start: "2027-02-11T15:45:00-06:00"),
        Case(phrase: "an hour from now", start: "2027-02-11T16:20:00-06:00"),
        Case(phrase: "after 2 hours", start: "2027-02-11T17:20:00-06:00"),
        Case(phrase: "in 2 days", start: "2027-02-13T09:00:00-06:00"),
    ]

    static let clockCases: [Case] = [
        Case(phrase: "at 4 15", start: "2027-02-11T16:15:00-06:00"),
        Case(phrase: "at four fifteen", start: "2027-02-11T16:15:00-06:00"),
        Case(phrase: "at 4", start: "2027-02-11T16:00:00-06:00"),
        // Past today → the next one: "at 9" is 9 am tomorrow, "at 3" 3 pm tomorrow.
        Case(phrase: "at 9", start: "2027-02-12T09:00:00-06:00"),
        Case(phrase: "at 3", start: "2027-02-12T15:00:00-06:00"),
        Case(phrase: "at 11 am", start: "2027-02-12T11:00:00-06:00"),
        Case(phrase: "at 5 pm", start: "2027-02-11T17:00:00-06:00"),
        Case(phrase: "at 5 p.m.", start: "2027-02-11T17:00:00-06:00"),
        // "today" said: the other half of the day.
        Case(phrase: "today at 9", start: "2027-02-11T21:00:00-06:00"),
        Case(phrase: "at half past 6", start: "2027-02-11T18:30:00-06:00"),
        Case(phrase: "quarter to 5", start: "2027-02-11T16:45:00-06:00"),
        Case(phrase: "at 8 30 tonight", start: "2027-02-11T20:30:00-06:00"),
        Case(phrase: "3:30pm tomorrow", start: "2027-02-12T15:30:00-06:00"),
        Case(phrase: "7 am tomorrow", start: "2027-02-12T07:00:00-06:00"),
        Case(phrase: "12 30 tomorrow", start: "2027-02-12T12:30:00-06:00"),
        Case(phrase: "tomorrow at noon", start: "2027-02-12T12:00:00-06:00"),
        Case(phrase: "tomorrow at nine", start: "2027-02-12T09:00:00-06:00"),
        Case(phrase: "tomorrow at 2", start: "2027-02-12T14:00:00-06:00"),
        Case(phrase: "at 5 o clock", start: "2027-02-11T17:00:00-06:00"),
        Case(phrase: "sunday at 6 40 am", start: "2027-02-14T06:40:00-06:00"),
        Case(phrase: "tomorrow 6 to 7 am", start: "2027-02-12T06:00:00-06:00", end: "2027-02-12T07:00:00-06:00"),
        Case(phrase: "2 to 3 pm tomorrow", start: "2027-02-12T14:00:00-06:00", end: "2027-02-12T15:00:00-06:00"),
    ]

    static let dayCases: [Case] = [
        Case(phrase: "tomorrow", start: "2027-02-12T09:00:00-06:00"),
        Case(phrase: "day after tomorrow", start: "2027-02-13T09:00:00-06:00"),
        Case(phrase: "tomorrow itself", start: "2027-02-12T09:00:00-06:00"),
        // "friday", "on friday" and "next friday" are the next Friday after today.
        Case(phrase: "on friday", start: "2027-02-12T09:00:00-06:00"),
        Case(phrase: "next friday", start: "2027-02-12T09:00:00-06:00"),
        Case(phrase: "thursday", start: "2027-02-18T09:00:00-06:00"),
        Case(phrase: "friday after next", start: "2027-02-19T09:00:00-06:00"),
        Case(phrase: "monday morning", start: "2027-02-15T09:00:00-06:00"),
        Case(phrase: "sunday evening", start: "2027-02-14T18:00:00-06:00"),
        Case(phrase: "next week", start: "2027-02-15T09:00:00-06:00"),
        Case(phrase: "this weekend", start: "2027-02-13T09:00:00-06:00"),
        Case(phrase: "end of day", start: "2027-02-11T17:00:00-06:00"),
        Case(phrase: "by eod", start: "2027-02-11T17:00:00-06:00"),
        Case(phrase: "end of day friday", start: "2027-02-12T17:00:00-06:00"),
        Case(phrase: "end of the week", start: "2027-02-12T17:00:00-06:00"),
        Case(phrase: "tonight", start: "2027-02-11T20:00:00-06:00"),
        Case(phrase: "before bed", start: "2027-02-11T22:00:00-06:00"),
        Case(phrase: "first thing tomorrow", start: "2027-02-12T09:00:00-06:00"),
        Case(phrase: "first thing in the morning", start: "2027-02-12T09:00:00-06:00"),
        Case(phrase: "on the twenty first", start: "2027-02-21T09:00:00-06:00"),
        // A part of today that already passed becomes the next half hour.
        Case(phrase: "after lunch", start: "2027-02-11T15:30:00-06:00"),
        Case(phrase: "on the 20th", start: "2027-02-20T09:00:00-06:00"),
        Case(phrase: "on the 5th", start: "2027-03-05T09:00:00-06:00"),
        Case(phrase: "on the 30th", start: "2027-03-30T09:00:00-05:00"),
        Case(phrase: "the 13th", start: "2027-02-13T09:00:00-06:00"),
        Case(phrase: "october 20th", start: "2027-10-20T09:00:00-05:00"),
        Case(phrase: "on 3rd november", start: "2027-11-03T09:00:00-05:00"),
        Case(phrase: "the 7th of march", start: "2027-03-07T09:00:00-06:00"),
        Case(phrase: "january 5", start: "2028-01-05T09:00:00-06:00"),
        Case(phrase: "on 8th march at 7 pm", start: "2027-03-08T19:00:00-06:00"),
        Case(phrase: "december 3rd 2027 at 5:45pm", start: "2027-12-03T17:45:00-06:00"),
    ]

    /// Indian-English order and words.
    static let indianEnglishCases: [Case] = [
        Case(phrase: "evening 7", start: "2027-02-11T19:00:00-06:00"),
        Case(phrase: "morning 9", start: "2027-02-12T09:00:00-06:00"),
        Case(phrase: "today night 10 o clock", start: "2027-02-11T22:00:00-06:00"),
        Case(phrase: "at 5 in the evening", start: "2027-02-11T17:00:00-06:00"),
        Case(phrase: "7 in the evening", start: "2027-02-11T19:00:00-06:00"),
        Case(phrase: "30th march", start: "2027-03-30T09:00:00-05:00"),
        Case(phrase: "after 10 minutes", start: "2027-02-11T15:30:00-06:00"),
    ]

    /// Self-corrections keep the corrected value.
    static let correctionCases: [Case] = [
        Case(phrase: "remind me to call dana at 3 no 4", start: "2027-02-11T16:00:00-06:00"),
        Case(phrase: "remind me tomorrow at 8 i mean 9 to call the vet", start: "2027-02-12T09:00:00-06:00"),
        Case(phrase: "schedule it for tuesday sorry wednesday at 11", start: "2027-02-17T11:00:00-06:00"),
        Case(phrase: "remind me in 30 minutes no an hour", start: "2027-02-11T16:20:00-06:00"),
        Case(phrase: "monday at 10 actually make it tuesday same time", start: "2027-02-16T10:00:00-06:00"),
    ]

    /// Numbers and words that are not dates.
    static let noDateCases: [Case] = [
        Case(phrase: "buy 2 dozen eggs", start: nil),
        Case(phrase: "book the 2nd floor room", start: nil),
        Case(phrase: "good morning everyone", start: nil),
        Case(phrase: "we offer 24/7 support", start: nil),
        Case(phrase: "call the 3 kids", start: nil),
        Case(phrase: "set up a 1 on 1 with omar", start: nil),
        Case(phrase: "i may call her", start: nil),
        Case(phrase: "the first draft", start: nil),
        Case(phrase: "", start: nil),
    ]

    @Test("relative spans", arguments: relativeCases)
    func relative(_ item: Case) { check(item) }

    @Test("clock times", arguments: clockCases)
    func clock(_ item: Case) { check(item) }

    @Test("days", arguments: dayCases)
    func days(_ item: Case) { check(item) }

    @Test("Indian-English forms", arguments: indianEnglishCases)
    func indianEnglish(_ item: Case) { check(item) }

    @Test("self-corrections", arguments: correctionCases)
    func corrections(_ item: Case) { check(item) }

    @Test("not dates", arguments: noDateCases)
    func noDate(_ item: Case) { check(item) }

    @Test("numeric dates follow the locale: en_IN and en_GB day-first, en_US month-first")
    func numericDatesFollowLocale() {
        let now = Self.date("2027-02-11T15:20:00+05:30")
        let india = DateContext(now: now, timeZone: TimeZone(identifier: "Asia/Kolkata")!, locale: Locale(identifier: "en_IN"))
        let us = DateContext(now: now, timeZone: TimeZone(identifier: "Asia/Kolkata")!, locale: Locale(identifier: "en_US"))
        let uk = DateContext(now: now, timeZone: TimeZone(identifier: "Europe/London")!, locale: Locale(identifier: "en_GB"))
        #expect(india.prefersDayFirst)
        #expect(uk.prefersDayFirst)
        #expect(!us.prefersDayFirst)
        #expect(start("12/10 at 10 am", india) == Self.date("2027-10-12T10:00:00+05:30"))
        #expect(start("on 12/10", us) == Self.date("2027-12-10T09:00:00+05:30"))
        // A number above 12 can only be the day, whatever the locale.
        #expect(start("on 25/10", us) == Self.date("2027-10-25T09:00:00+05:30"))
        #expect(start("on 3/4", uk) == Self.date("2027-04-03T09:00:00+01:00"))
    }

    @Test("the source phrase is the words the date came from")
    func sourcePhrase() {
        let context = Self.thursdayAfternoon
        #expect(DateAnchor.firstDate(in: "remind me to call the plumber tomorrow at 9", context: context)?.sourcePhrase == "tomorrow at 9")
        #expect(DateAnchor.firstDate(in: "add lunch with ben on friday at 1 at toit", context: context)?.sourcePhrase == "on friday at 1")
        // A time and a day said apart are joined.
        let apart = DateAnchor.firstDate(in: "remind me at 5 to call mom tomorrow", context: context)
        #expect(apart?.sourcePhrase == "at 5 tomorrow")
        #expect(apart?.start == Self.date("2027-02-12T17:00:00-06:00"))
        // "tonight" already names the day; a later weekday belongs to another request.
        #expect(start("take out the trash tonight and call grandma sunday", context) == Self.date("2027-02-11T20:00:00-06:00"))
    }

    @Test("the same words mean the same wall-clock time in every zone")
    func zones() {
        let now = Self.date("2027-02-11T12:00:00Z")
        let kolkata = DateContext(now: now, timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        let losAngeles = DateContext(now: now, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(start("tomorrow at 9", kolkata) == Self.date("2027-02-12T09:00:00+05:30"))
        #expect(start("tomorrow at 9", losAngeles) == Self.date("2027-02-12T09:00:00-08:00"))
    }

    // MARK: Helpers

    private func check(_ item: Case, sourceLocation: SourceLocation = #_sourceLocation) {
        let anchor = DateAnchor.firstDate(in: item.phrase, context: Self.thursdayAfternoon)
        guard let expected = item.start else {
            #expect(anchor == nil, "found \(anchor.map { iso($0.start) } ?? "") in \"\(item.phrase)\"", sourceLocation: sourceLocation)
            return
        }
        #expect(anchor.map { iso($0.start) } == iso(Self.date(expected)), sourceLocation: sourceLocation)
        if let end = item.end {
            #expect(anchor?.end.map(iso) == iso(Self.date(end)), sourceLocation: sourceLocation)
        }
    }

    private func start(_ phrase: String, _ context: DateContext) -> Date? {
        DateAnchor.firstDate(in: phrase, context: context)?.start
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = Self.thursdayAfternoon.timeZone
        return formatter.string(from: date)
    }

    static func date(_ iso: String) -> Date {
        guard let date = ProposalFields.parseISO8601(iso) else { fatalError("bad test date \(iso)") }
        return date
    }
}
