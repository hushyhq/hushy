import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

/// Tolerance rules for tool arguments (`ToolArgumentMatcher`, `SpokenDuration`).
@Suite("Tool argument tolerance rules")
struct ToolArgumentMatcherTests {
    // Monday 2026-10-05 10:15 in Kolkata.
    let zone = TimeZone(identifier: "Asia/Kolkata")!
    var now: Date { ProposalFields.parseISO8601("2026-10-05T10:15:00+05:30")! }

    private func dates(_ spoken: [String] = []) -> ToolArgumentMatcher.DateContext {
        ToolArgumentMatcher.DateContext(now: now, timeZone: zone, spoken: spoken)
    }

    private func match(_ expected: ToolArgumentValue, _ got: ToolArgumentValue?, _ kind: VoiceToolParameter.Kind,
                       _ mode: ToolArgumentMatcher.Mode, spoken: [String] = []) -> Bool {
        ToolArgumentMatcher.matches(expected, got, kind: kind, mode: mode, dates: dates(spoken))
    }

    @Test("text: exact ignores case and punctuation; tolerant uses token F1 without fillers")
    func text() {
        #expect(match(.string("call the plumber"), .string("Call the plumber."), .text, .exact))
        #expect(!match(.string("call the plumber"), .string("call plumber"), .text, .exact))
        #expect(match(.string("call the plumber"), .string("call plumber"), .text, .tolerant))
        #expect(match(.string("buy three apples"), .string("buy 3 apples"), .text, .tolerant))
        #expect(!match(.string("call the plumber"), .string("pay the electrician"), .text, .tolerant))
        #expect(!match(.string("call the plumber"), nil, .text, .tolerant))
        #expect(!match(.string("call the plumber"), .string("  "), .text, .tolerant))
    }

    @Test("names: tolerant by token containment, honorifics and list/app words ignored, plurals folded")
    func names() {
        #expect(match(.string("priya"), .string("Priya Sharma"), .name, .tolerant))
        #expect(match(.string("groceries"), .string("grocery list"), .name, .tolerant))
        #expect(match(.string("dr rao"), .string("Rao"), .name, .tolerant))
        #expect(!match(.string("dr rao"), .string("Rao"), .name, .exact))
        #expect(!match(.string("dana"), .string("dan"), .name, .tolerant))
    }

    @Test("enums: exact value, synonyms in tolerant mode")
    func enums() {
        let channel = VoiceToolParameter.Kind.enumeration(["slack", "imessage"])
        #expect(match(.string("imessage"), .string("imessage"), channel, .exact))
        #expect(!match(.string("imessage"), .string("messages"), channel, .exact))
        #expect(match(.string("imessage"), .string("Messages"), channel, .tolerant))
        #expect(!match(.string("slack"), .string("teams"), channel, .tolerant))
    }

    @Test("dates: ISO instants, day-only expectations and expected spoken phrases")
    func datesISOAndPhrases() {
        let nine = ToolArgumentValue.string("2026-10-06T09:00:00+05:30")
        #expect(match(nine, .string("2026-10-06T03:30:00Z"), .dateTime, .exact), "same instant, other offset")
        #expect(!match(nine, .string("2026-10-06T10:00:00+05:30"), .dateTime, .tolerant))
        #expect(match(nine, .string("tomorrow at 9"), .dateTime, .exact, spoken: ["tomorrow at 9"]))
        #expect(match(nine, .string("Tomorrow at 9."), .dateTime, .exact, spoken: ["tomorrow at 9"]))
        #expect(!match(nine, .string("at 9 tomorrow"), .dateTime, .exact, spoken: ["tomorrow at 9"]))
        #expect(match(nine, .string("at 9 tomorrow"), .dateTime, .tolerant, spoken: ["tomorrow at 9"]), "same words, other order")
        let day = ToolArgumentValue.string("2026-10-07")
        #expect(match(day, .string("2026-10-07T18:00:00+05:30"), .dateTime, .exact), "day-only compares the day")
        #expect(!match(day, .string("2026-10-08T18:00:00+05:30"), .dateTime, .exact))
        #expect(match(day, .string("day after tomorrow"), .dateTime, .exact, spoken: ["day after tomorrow"]))
        #expect(!match(day, .string("next week"), .dateTime, .tolerant, spoken: ["day after tomorrow"]))
    }

    @Test("dates: a different phrase that DateAnchor resolves to the same moment passes tolerant only")
    func datesResolved() {
        let three = ToolArgumentValue.string("2026-10-06T15:00:00+05:30")
        #expect(!match(three, .string("tomorrow at 15:00"), .dateTime, .exact, spoken: ["tomorrow at 3 pm"]))
        #expect(match(three, .string("tomorrow at 15:00"), .dateTime, .tolerant, spoken: ["tomorrow at 3 pm"]))
    }

    @Test("durations: phrases and seconds compare by value")
    func durations() {
        #expect(SpokenDuration.seconds(in: "20 minutes") == 1200)
        #expect(SpokenDuration.seconds(in: "twenty five mins") == 1500)
        #expect(SpokenDuration.seconds(in: "an hour and a half") == 5400)
        #expect(SpokenDuration.seconds(in: "one and a half hours") == 5400)
        #expect(SpokenDuration.seconds(in: "half an hour") == 1800)
        #expect(SpokenDuration.seconds(in: "1 hour 30 minutes") == 5400)
        #expect(SpokenDuration.seconds(in: "90 seconds") == 90)
        #expect(SpokenDuration.seconds(in: "2 and a half hours") == 9000)
        #expect(SpokenDuration.seconds(in: "5m") == 300)
        #expect(SpokenDuration.seconds(in: "a minute") == 60)
        #expect(SpokenDuration.seconds(in: "for the pasta") == nil)
        #expect(match(.integer(900), .string("15 minutes"), .duration, .exact))
        #expect(match(.integer(900), .integer(900), .duration, .exact))
        #expect(!match(.integer(900), .string("10 minutes"), .duration, .tolerant))
    }

    @Test("lists: exact is the same set; tolerant splits joined items and pairs one to one")
    func lists() {
        let items = ToolArgumentValue.strings(["eggs", "milk", "bread"])
        #expect(match(items, .strings(["Bread", "eggs", "milk"]), .textList, .exact))
        #expect(!match(items, .strings(["eggs, milk and bread"]), .textList, .exact))
        #expect(match(items, .strings(["eggs, milk and bread"]), .textList, .tolerant))
        #expect(!match(items, .strings(["eggs", "milk"]), .textList, .tolerant), "dropped item")
        #expect(!match(items, .strings(["eggs", "milk", "bread", "jam"]), .textList, .tolerant), "invented item")
        #expect(match(.strings(["salt and pepper"]), .strings(["salt and pepper"]), .textList, .tolerant), "unsplit first")
        #expect(match(.strings(["priya", "dana"]), .strings(["Priya Sharma", "Dana"]), .nameList, .tolerant))
    }

    @Test("call comparison: extra arguments fail exact but not tolerant; accept lists widen a slot")
    func callComparison() {
        let expected = ToolCall(tool: "create_event", arguments: ["title": .string("dentist"), "when": .string("2026-10-06T15:00:00+05:30")])
        let predicted = ToolCall(tool: "create_event", arguments: [
            "title": .string("Dentist"), "when": .string("tomorrow at 3 pm"), "location": .string("downtown"),
        ])
        let result = ToolArgumentMatcher.compare(expected: expected, predicted: predicted, dates: dates(["tomorrow at 3 pm"]))
        #expect(result.extras == ["location"])
        #expect(!result.exact)
        #expect(result.tolerant)
        let widened = ToolArgumentMatcher.compare(
            expected: ToolCall(tool: "open_app", arguments: ["target": .string("youtube.com")]),
            accept: ["target": [.string("youtube dot com")]],
            predicted: ToolCall(tool: "open_app", arguments: ["target": .string("YouTube dot com")]), dates: dates())
        #expect(widened.exact)
    }
}
