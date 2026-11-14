import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// Meeting memory as a person uses it: meetings stored the way the app stores them, then asked.
@Suite("Meeting memory across meetings")
struct MeetingMemoryTests {
    static let zone = TimeZone(identifier: "America/Los_Angeles")!

    static func date(_ text: String) -> Date { ProposalFields.parseISO8601(text)! }

    static func context(_ now: String) -> DateContext { DateContext(now: date(now), timeZone: zone) }

    struct Meeting {
        var title: String
        var start: String
        var series: String?
        var attendees: [CalendarAttendee] = []
        var turns: [(String, String)]
        var decisions: [String] = []
        var items: [ActionItemDetail] = []
        var done: [Int] = []
    }

    static let me = CalendarAttendee(name: "Sam Lee", email: "sam@brightloop.example", isCurrentUser: true, status: .accepted)
    static let priya = CalendarAttendee(name: "Priya Raman", email: "priya@acme.com", status: .accepted)

    /// Writes meetings into an in-memory store exactly as the app does: note, summary lines, item
    /// fields, ticks, calendar match and speaker turns.
    static func store(_ meetings: [Meeting]) throws -> Store {
        let store = try Store()
        for meeting in meetings {
            let start = date(meeting.start)
            var note = Note(title: meeting.title, createdAt: start, updatedAt: start, durationSeconds: 1_800,
                            transcript: meeting.turns.map(\.1).joined(separator: " "),
                            summary: meeting.decisions.map { "- Decided: \($0)" }.joined(separator: "\n"), status: .ready)
            note.setActionItems(meeting.items.map(\.line), details: meeting.items)
            let id = try #require(try store.save(note).id)
            for index in meeting.done { try store.setActionItemDone(noteId: id, itemIndex: index, isDone: true) }
            if !meeting.attendees.isEmpty {
                let event = CalendarEvent(eventIdentifier: meeting.series ?? "one-off-\(id)", title: meeting.title, start: start,
                                          end: start.addingTimeInterval(1_800), attendees: meeting.attendees, iCalUID: meeting.series)
                try store.applyCalendarMatch(try #require(NoteCalendarMatch(event: event)), toNote: id, replacingTitle: meeting.title)
            }
            let names = meeting.turns.map(\.0).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            try store.replaceSpeakerSegments(
                noteId: id, speakers: names.enumerated().map { NoteSpeaker(noteId: id, label: "Speaker \($0.offset + 1)", displayName: $0.element) },
                segments: meeting.turns.enumerated().map { index, turn in
                    (names.firstIndex(of: turn.0), AlignedSegment(speakerLabel: turn.0, start: Double(index * 20), end: Double(index * 20 + 20), text: turn.1))
                })
        }
        return store
    }

    static let acmeSeries: [Meeting] = [
        Meeting(title: "Acme pricing review", start: "2026-10-13T10:00:00-07:00", series: "acme-weekly", attendees: [me, priya],
                turns: [("Priya", "We can do forty-five dollars a seat."),
                        ("Sam", "Forty-five a seat works. I'll send the revised quote by Friday."),
                        ("Priya", "And I'll share the security questionnaire tomorrow."),
                        ("Sam", "I'll also book the onboarding workshop.")],
                decisions: ["Price is $45 per seat"],
                items: [ActionItemDetail(owner: "Sam", task: "Send the revised quote", due: "by Friday"),
                        ActionItemDetail(owner: "Priya", task: "Share the security questionnaire", due: "tomorrow"),
                        ActionItemDetail(owner: "Sam", task: "Book the onboarding workshop")],
                done: [2]),
        Meeting(title: "Acme pricing review", start: "2026-10-20T10:00:00-07:00", series: "acme-weekly", attendees: [me, priya],
                turns: [("Sam", "I sent the revised quote on Tuesday."),
                        ("Priya", "Thanks. Our budget moved, so we need forty dollars a seat."),
                        ("Sam", "Forty a seat is fine for two hundred seats.")],
                decisions: ["Price is now $40 per seat for 200 seats"]),
    ]

    @Test("what I owe someone leaves out what I ticked off and what I said was done in a later meeting")
    func openCommitments() throws {
        let memory = try MeetingMemory.build(from: try Self.store(Self.acmeSeries), selfNames: ["Sam Lee"])
        let mine = memory.ask("What do I still owe Priya?", context: Self.context("2026-10-27T09:00:00-07:00"))
        #expect(mine.isDecline)
        #expect(mine.heading.hasPrefix("Nothing open"))
        let theirs = memory.ask("What does Priya owe me?", context: Self.context("2026-10-27T09:00:00-07:00"))
        #expect(theirs.lines.map(\.text) == ["Priya Raman: Share the security questionnaire — tomorrow"])
        #expect(theirs.lines.first?.quote?.text == "And I'll share the security questionnaire tomorrow.")
        #expect(theirs.lines.first?.quote?.link.absoluteString.hasPrefix("hushy://note/") == true)
    }

    @Test("a company known only from attendee emails, with the later price replacing the earlier one")
    func decisionsByCompanyOverTime() throws {
        let memory = try MeetingMemory.build(from: try Self.store(Self.acmeSeries), selfNames: ["Sam Lee"])
        let now = Self.context("2026-10-27T09:00:00-07:00")
        let current = memory.ask("What did we decide with Acme?", context: now)
        #expect(current.lines.map(\.text) == ["Price is now $40 per seat for 200 seats (replaces what was decided Oct 13)"])
        let lastWeek = memory.ask("What did we decide with Acme last week?", context: now)
        #expect(lastWeek.lines.count == 1)
        #expect(lastWeek.lines.first?.meeting.start == Self.date("2026-10-20T10:00:00-07:00"))
        let changes = memory.ask("What changed at the last Acme pricing review?", context: now)
        #expect(changes.lines.map(\.text).prefix(2) == ["Now: Price is now $40 per seat for 200 seats (was: Price is $45 per seat, Oct 13)",
                                                       "Before: Price is $45 per seat"])
        #expect(Set(changes.lines.prefix(2).map(\.meeting.start)).count == 2)
        #expect(changes.lines.contains { $0.text == "You: Send the revised quote — done" })
    }

    @Test("no meetings with a company the memory has never seen is a plain no")
    func unknownCompanyDeclines() throws {
        let memory = try MeetingMemory.build(from: try Self.store(Self.acmeSeries), selfNames: ["Sam Lee"])
        let answer = memory.ask("What did we decide with Zephyr?", context: Self.context("2026-10-27T09:00:00-07:00"))
        #expect(answer.isDecline)
        #expect(answer.lines.isEmpty)
    }

    @Test("a look-alike company and a same-name person at it stay apart")
    func lookAlikesStayApart() throws {
        let freight = Meeting(title: "Acme Freight intro call", start: "2026-10-21T09:00:00-07:00",
                              turns: [("Priya", "Hi Sam, Priya Okafor from Acme Freight."),
                                      ("Priya", "I'll send our dock data by Monday.")],
                              decisions: ["Start with dock scheduling"],
                              items: [ActionItemDetail(owner: "Priya", task: "Send the dock data", due: "by Monday")])
        let memory = try MeetingMemory.build(from: try Self.store(Self.acmeSeries + [freight]), selfNames: ["Sam Lee"])
        let now = Self.context("2026-10-27T09:00:00-07:00")
        let acme = memory.ask("What did we decide with Acme last week?", context: now)
        #expect(acme.lines.map(\.meeting.title) == ["Acme pricing review"])
        let freightAnswer = memory.ask("What did we decide with Acme Freight?", context: now)
        #expect(freightAnswer.lines.map(\.text) == ["Start with dock scheduling"])
        let priyaRaman = memory.ask("What does Priya Raman owe me?", context: now)
        #expect(!priyaRaman.lines.contains { $0.text.contains("dock") })
    }

    @Test("a topic said only in the transcript is found by its rare words, with the reply after it")
    func searchFindsTurnsByRareWords() throws {
        let call = Meeting(title: "Call with Hollis", start: "2026-10-21T09:00:00-07:00",
                           turns: [("Hollis", "For outdoor use I'd add a UV stabilizer to the resin."),
                                   ("Sam", "Good, add it. Twelve cents a part is fine.")])
        let memory = try MeetingMemory.build(from: try Self.store(Self.acmeSeries + [call]), selfNames: ["Sam Lee"])
        let answer = memory.ask("Did anyone bring up UV or sun fading?", context: Self.context("2026-10-27T09:00:00-07:00"))
        #expect(!answer.isDecline)
        #expect(answer.lines.map(\.text) == ["Hollis: For outdoor use I'd add a UV stabilizer to the resin.",
                                             "Sam: Good, add it. Twelve cents a part is fine."])
        #expect(answer.lines.allSatisfy { $0.quote != nil })
    }

    @Test("a company is found by the start of its domain, and a question naming someone's open item is about commitments")
    func entitiesAndIntentFromRows() throws {
        let gardens = CalendarAttendee(name: "Calum Brewer", email: "calum@rootstockgardens.example", status: .accepted)
        let pilot = Meeting(title: "Pilot sync", start: "2026-10-15T10:00:00-07:00", series: "pilot", attendees: [Self.me, gardens],
                            turns: [("Calum", "Twenty stores for the pilot."), ("Calum", "I'll send the store list Monday.")],
                            decisions: ["Pilot runs in 20 stores"],
                            items: [ActionItemDetail(owner: "Calum", task: "Send the store list", due: "Monday")])
        let memory = try MeetingMemory.build(from: try Self.store(Self.acmeSeries + [pilot]), selfNames: ["Sam Lee"])
        let now = Self.context("2026-10-27T09:00:00-07:00")
        let agreed = memory.ask("What have we agreed with Rootstock so far?", context: now)
        #expect(agreed.lines.map(\.text) == ["Pilot runs in 20 stores"])
        let owed = memory.ask("what's Calum still got to send me?", context: now)
        #expect(owed.kind == .commitments)
        #expect(owed.lines.map(\.text) == ["Calum Brewer: Send the store list — Monday"])
    }

    @Test("a change said only in the transcript is quoted with both values")
    func changeStatedInTurns() throws {
        let weekly = [
            Meeting(title: "Ledgerly weekly", start: "2026-10-28T10:00:00-07:00", series: "ledgerly", attendees: [Self.me, Self.priya],
                    turns: [("Priya", "For the handoff, let's do iOS first, then Android.")]),
            Meeting(title: "Ledgerly weekly", start: "2026-11-04T10:00:00-08:00", series: "ledgerly", attendees: [Self.me, Self.priya],
                    turns: [("Priya", "Most testers are on Android. Do Android first for the handoff, not iOS.")]),
        ]
        let memory = try MeetingMemory.build(from: try Self.store(weekly), selfNames: ["Sam Lee"])
        let answer = memory.ask("What changed at the last Ledgerly weekly?", context: Self.context("2026-11-05T09:00:00-08:00"))
        #expect(answer.lines.first?.text == "Said: Priya: Most testers are on Android. Do Android first for the handoff, not iOS.")
        #expect(answer.lines.first?.quote?.ordinal == 0)
    }

    @Test("the brief before the next meeting with the same people")
    func prepBrief() throws {
        let memory = try MeetingMemory.build(from: try Self.store(Self.acmeSeries), selfNames: ["Sam Lee"])
        let next = CalendarEvent(eventIdentifier: "acme-weekly", title: "Acme pricing review", start: Self.date("2026-10-27T10:00:00-07:00"),
                                 end: Self.date("2026-10-27T10:30:00-07:00"), attendees: [Self.me, Self.priya], iCalUID: "acme-weekly")
        let brief = memory.ask("Prep me for my next call with Priya", context: Self.context("2026-10-27T09:00:00-07:00"), upcoming: [next])
        #expect(brief.kind == .prep)
        #expect(brief.sections.map(\.title) == ["Last time", "Decided recently", "They owe you", "Closed last time"])
        #expect(brief.lines.first?.text == "Last met Oct 20: Acme pricing review")
    }

    @Test("attendees keep their name and company domain, never the address or a personal domain, and go with the note")
    func attendeeStorage() throws {
        let store = try Store()
        let id = try #require(try store.save(Note(title: "Call", status: .ready)).id)
        let event = CalendarEvent(eventIdentifier: "e", title: "Call", start: Date(), end: Date(), attendees: [
            Self.me, Self.priya, CalendarAttendee(name: "Dana", email: "dana@gmail.com"),
            CalendarAttendee(name: "lee@acme.com", email: "lee@acme.com"),
        ], iCalUID: "uid-1")
        try store.applyCalendarMatch(try #require(NoteCalendarMatch(event: event)), toNote: id, replacingTitle: "Call")
        let rows = try store.attendees(forNote: id)
        #expect(rows.map(\.name) == ["Sam Lee", "Priya Raman", "Dana", ""])
        #expect(rows.map(\.companyDomain) == ["brightloop.example", "acme.com", nil, "acme.com"])
        #expect(rows.map(\.isSelf) == [true, false, false, false])
        #expect(try store.calendarLink(forNote: id)?.seriesKey == "uid-1")
        try store.deleteNote(id: id)
        #expect(try store.attendees(forNote: id).isEmpty)
    }

    @Test("a reworded line that names a number its row does not have keeps the row's text")
    func phrasingCannotAddFacts() async throws {
        let memory = try MeetingMemory.build(from: try Self.store(Self.acmeSeries), selfNames: ["Sam Lee"])
        let context = Self.context("2026-10-27T09:00:00-07:00")
        let answer = memory.ask("What did we decide with Acme?", context: context)
        let model = CannedModel(json: #"{"lead":"Here is what you decided with Acme.","lines":[{"n":1,"text":"The price is $35 a seat."},{"n":2,"text":"Extra line"}]}"#)
        let phrased = await MemoryPhraser(model: model).phrase(answer, question: "What did we decide with Acme?", context: context)
        #expect(phrased.answer.lines.map(\.text) == answer.lines.map(\.text))
        #expect(phrased.invented == 2)
        #expect(phrased.answer.heading == "Here is what you decided with Acme.")
        #expect(phrased.answer.lines.map(\.quote) == answer.lines.map(\.quote))
    }

    @Test("the MCP helper answers Hushy's Assistant from the same rows, read-only, and no external app")
    func mcpTools() throws {
        let store = try Self.store(Self.acmeSeries)
        let server = MCPServer(reader: store.writer, scope: .notes, now: { Self.date("2026-10-27T09:00:00-07:00") },
                               timeZone: Self.zone, exposesNotes: true)
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"meeting_memory","arguments":{"question":"What does Priya owe me?"}}}"#
        let response = try #require(server.handle(line: request))
        #expect(response.contains("Share the security questionnaire"))
        #expect(response.contains("hushy://note/"))
        #expect(!response.contains("revised quote"))
        let rows = try #require(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"meeting_rows","arguments":{}}}"#))
        #expect(rows.contains("actionItems") && rows.contains("acme.com"))
        #expect(!MCPServer.toolNames(for: .all, exposesNotes: false).contains("meeting_memory"))
        #expect(!MCPServer.toolNames(for: .all, exposesNotes: true).contains("meeting_memory"))
    }
}

/// Answers every structured call with the same JSON.
private final class CannedModel: LanguageModel {
    let json: String
    init(json: String) { self.json = json }
    var identifier: String { "canned" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String { json }
}
