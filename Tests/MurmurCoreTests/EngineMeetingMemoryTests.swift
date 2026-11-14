import Foundation
import Testing
@testable import MurmurCore

/// The Meetings screens read the cross-meeting rows through `EngineMeetingMemory`: meetings stored
/// as the app stores them (`MeetingMemoryTests.store`), then read the way the overview, the person
/// page, prep and "Ask your meetings" read them.
@Suite("Meetings screens on the memory rows")
struct EngineMeetingMemoryTests {
    private let me = ["Sam Lee"]
    private let now = MeetingMemoryTests.context("2026-10-27T09:00:00-07:00")
    private let next = CalendarEvent(
        eventIdentifier: "acme-weekly", title: "Acme pricing review", start: MeetingMemoryTests.date("2026-10-27T10:00:00-07:00"),
        end: MeetingMemoryTests.date("2026-10-27T10:30:00-07:00"), attendees: [MeetingMemoryTests.me, MeetingMemoryTests.priya],
        iCalUID: "acme-weekly")

    private func memory(jots: [(meeting: Int, text: String)] = []) throws -> (EngineMeetingMemory, [Int64]) {
        let store = try MeetingMemoryTests.store(MeetingMemoryTests.acmeSeries)
        let ids = try store.notes().sorted { $0.createdAt < $1.createdAt }.compactMap(\.id)
        for jot in jots { try store.addJot(noteId: ids[jot.meeting], text: jot.text, atSeconds: 30) }
        return (try EngineMeetingMemory.build(store: store, myNames: me, upcoming: [next], context: now), ids)
    }

    @Test("what I owe and what I'm owed leave out what I ticked off and what I said was done later")
    func commitments() throws {
        let (memory, ids) = try memory()
        let owed = try memory.commitments(myNames: me)
        #expect(owed.iOwe.isEmpty, "the quote was sent in the next meeting and the workshop was ticked off")
        #expect(owed.owedToMe.map(\.detail.task) == ["Share the security questionnaire"])
        #expect(owed.owedToMe.first?.noteId == ids[0])
        #expect(owed.owedToMe.first?.itemIndex == 1, "the index the note page ticks off")
    }

    @Test("people and companies come from the invites, and a person's timeline is newest first")
    func peopleCompaniesTimeline() throws {
        let (memory, _) = try memory()
        let priya = try #require(try memory.people(limit: 10, myNames: me).first { $0.name == "Priya Raman" })
        #expect(priya.meetingCount == 2)
        #expect(try memory.people(limit: 10, myNames: me).allSatisfy { $0.name != "Sam Lee" })
        let acme = try #require(try memory.companies(limit: 8).first)
        #expect(acme.people == ["Priya Raman"])
        #expect(acme.meetingCount == 2)
        let timeline = try memory.timeline(for: .person("Priya Raman"), myNames: me)
        #expect(timeline.map(\.date) == [MeetingMemoryTests.date("2026-10-20T10:00:00-07:00"), MeetingMemoryTests.date("2026-10-13T10:00:00-07:00")])
        #expect(timeline.last?.decisions == ["Price is $45 per seat (changed later)"])
        #expect(try memory.timeline(for: .person("Priya"), myNames: me).count == 2, "a first name finds them too")
        #expect(try memory.timeline(for: .company(acme.name), myNames: me).count == 2)
    }

    @Test("prep brings last time, what is still open and last time's typed question")
    func prep() throws {
        let (memory, _) = try memory(jots: [(1, "? do they need SSO")])
        let prep = try memory.prep(for: next, myNames: me)
        #expect(prep.attendees == ["Priya Raman"])
        #expect(prep.lastTime.first?.date == MeetingMemoryTests.date("2026-10-20T10:00:00-07:00"))
        #expect(prep.stillOpen.map(\.detail.task) == ["Share the security questionnaire"])
        #expect(prep.talkingPoints.first?.hasSuffix(": Share the security questionnaire") == true)
        #expect(prep.talkingPoints.contains("Still open: do they need SSO"))
        #expect(!prep.isFirstMeeting)
    }

    @Test("the person's typed decision is kept and the model's restatement of it dropped")
    func typedDecisionWins() throws {
        let (memory, _) = try memory(jots: [(1, "! price: 40/seat for 200 seats")])
        let latest = try #require(try memory.timeline(for: .person("Priya Raman"), myNames: me).first)
        #expect(latest.decisions == ["price: 40/seat for 200 seats"])
    }

    @Test("every answer line keeps its meeting and the link to the moment the memory cites")
    func askKeepsCitations() throws {
        let (memory, ids) = try memory()
        let answer = try memory.ask("What does Priya owe me?", myNames: me)
        let line = try #require(answer.lines.first)
        #expect(answer.heading != nil)
        #expect(line.kind == .item)
        #expect(line.noteId == ids[0])
        #expect(line.quote == "And I'll share the security questionnaire tomorrow.")
        let engineLine = try #require(memory.engine.ask("What does Priya owe me?", context: now, upcoming: [next]).lines.first)
        #expect(line.link == engineLine.quote?.link)
        #expect(line.link.absoluteString == "hushy://note/\(ids[0])?t=40")
    }

    @Test("an honest no comes back as the reason, not a blank")
    func askDeclines() throws {
        let (memory, _) = try memory()
        let answer = try memory.ask("What do I still owe Priya?", myNames: me)
        #expect(answer.lines.isEmpty)
        #expect(answer.emptyReason?.hasPrefix("Nothing open") == true)
    }

    @Test("a line's link never traps on a moment that is not a number of seconds")
    func linkWithoutValidSeconds() {
        let line = MeetingAnswer.Line(noteId: 7, noteTitle: "", noteDate: .distantPast, kind: .quote, text: "", atSeconds: .infinity)
        #expect(line.link.absoluteString == "hushy://note/7")
    }
}
