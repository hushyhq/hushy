import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// Naming and linking a note from its calendar meeting (task 84): the store half (additive v17
/// migration, compare-and-set title, cascade delete, attendee-name suggestions) and the lookup
/// half (`NoteCalendarLinker`: no access means no read, a failed or slow reader means no match).
/// Everything runs against `StaticCalendarReader` and the in-memory store; no EventKit.
@Suite("Note calendar link")
struct NoteCalendarLinkTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let defaultTitle = "Note · 9:00 AM"

    private func meeting(
        _ id: String = "sync", title: String = "Weekly sync", startIn: TimeInterval = 0,
        duration: TimeInterval = 30 * 60, others: [CalendarAttendee] = [CalendarAttendee(name: "Dana Kim", status: .accepted)],
        location: String = ""
    ) -> CalendarEvent {
        let me = CalendarAttendee(name: "Me", email: "me@example.com", isCurrentUser: true, status: .accepted)
        let start = epoch.addingTimeInterval(startIn)
        return CalendarEvent(
            eventIdentifier: id, title: title, start: start, end: start.addingTimeInterval(duration),
            attendees: [me] + others, locationAndURL: location)
    }

    private func makeNote(_ store: Store, title: String? = nil) throws -> Int64 {
        let note = try store.save(Note(title: title ?? defaultTitle, createdAt: epoch, status: .recording))
        return try #require(note.id)
    }

    // MARK: - Migration

    @Test("migration v17 appends after v16 and creates both tables")
    func migration() throws {
        let store = try Store()
        let applied = try store.writer.read { db in try Store.migrator.appliedIdentifiers(db) }
        #expect(applied.contains("v17-note-calendar"))
        let ids = Store.migrator.migrations
        #expect(ids.firstIndex(of: "v16-dictation-edit-observations")! < ids.firstIndex(of: "v17-note-calendar")!)
        let tables = try store.writer.read { db in
            (try db.tableExists("note_calendar_link"), try db.tableExists("note_name_suggestion"))
        }
        #expect(tables == (true, true))
    }

    // MARK: - Applying a match

    @Test("applying a match titles the note and stores the link and attendee names")
    func applyTitlesAndLinks() throws {
        let store = try Store()
        let id = try makeNote(store)
        let event = meeting(others: [
            CalendarAttendee(name: "Dana Kim", status: .accepted), CalendarAttendee(name: "Sam Ortiz", status: .tentative),
        ])
        let match = try #require(NoteCalendarMatch(event: event))

        let titled = try store.applyCalendarMatch(match, toNote: id, replacingTitle: defaultTitle)

        #expect(titled)
        #expect(try store.note(id: id)?.title == "Weekly sync")
        let link = try #require(try store.calendarLink(forNote: id))
        #expect(link.eventIdentifier == "sync")
        #expect(link.eventTitle == "Weekly sync")
        #expect(link.eventStart == event.start)
        #expect(link.eventEnd == event.end)
        #expect(try store.nameSuggestions(forNote: id) == ["Dana Kim", "Sam Ortiz"])
    }

    @Test("a hand-edited title is never overwritten, but the link and names are still kept")
    func handEditedTitleSurvives() throws {
        let store = try Store()
        let id = try makeNote(store, title: "Budget thoughts")
        let match = try #require(NoteCalendarMatch(event: meeting()))

        let titled = try store.applyCalendarMatch(match, toNote: id, replacingTitle: defaultTitle)

        #expect(!titled)
        #expect(try store.note(id: id)?.title == "Budget thoughts")
        #expect(try store.calendarLink(forNote: id)?.eventIdentifier == "sync")
        #expect(try store.nameSuggestions(forNote: id) == ["Dana Kim"])
    }

    @Test("applying twice replaces the suggestions instead of duplicating them")
    func applyIsIdempotent() throws {
        let store = try Store()
        let id = try makeNote(store)
        let first = try #require(NoteCalendarMatch(event: meeting(others: [CalendarAttendee(name: "Dana Kim")])))
        let second = try #require(NoteCalendarMatch(event: meeting(others: [CalendarAttendee(name: "Lee Park")])))
        _ = try store.applyCalendarMatch(first, toNote: id, replacingTitle: defaultTitle)
        _ = try store.applyCalendarMatch(second, toNote: id, replacingTitle: "Weekly sync")
        #expect(try store.nameSuggestions(forNote: id) == ["Lee Park"])
    }

    @Test("a note with no link has no link and no suggestions")
    func unlinkedNote() throws {
        let store = try Store()
        let id = try makeNote(store)
        #expect(try store.calendarLink(forNote: id) == nil)
        #expect(try store.nameSuggestions(forNote: id).isEmpty)
    }

    @Test("applying to a note that does not exist stores nothing and does not throw")
    func missingNote() throws {
        let store = try Store()
        let match = try #require(NoteCalendarMatch(event: meeting()))
        #expect(try store.applyCalendarMatch(match, toNote: 9_999, replacingTitle: defaultTitle) == false)
        #expect(try store.calendarLink(forNote: 9_999) == nil)
    }

    @Test("deleting the note deletes its link and suggestions")
    func cascadeOnDelete() throws {
        let store = try Store()
        let id = try makeNote(store)
        let match = try #require(NoteCalendarMatch(event: meeting()))
        _ = try store.applyCalendarMatch(match, toNote: id, replacingTitle: defaultTitle)

        try store.deleteNote(id: id)

        let counts = try store.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_calendar_link") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_name_suggestion") ?? -1)
        }
        #expect(counts == (0, 0))
    }

    // MARK: - Building a match

    @Test("suggestions drop the user, decliners, bare email addresses and duplicates")
    func suggestionFiltering() throws {
        let event = meeting(others: [
            CalendarAttendee(name: "Dana Kim", email: "dana@example.com", status: .accepted),
            CalendarAttendee(name: "dana kim", status: .accepted),
            CalendarAttendee(name: "", email: "noname@example.com", status: .accepted),
            CalendarAttendee(name: "sam@example.com", email: "sam@example.com", status: .accepted),
            CalendarAttendee(name: "Ghost", status: .declined),
            CalendarAttendee(name: "Lee Park", status: .pending),
        ])
        let match = try #require(NoteCalendarMatch(event: event))
        #expect(match.suggestions == ["Dana Kim", "Lee Park"])
    }

    @Test("a long invite list is capped")
    func suggestionCap() throws {
        let many = (0..<200).map { CalendarAttendee(name: "Person \($0)", status: .accepted) }
        let match = try #require(NoteCalendarMatch(event: meeting(others: many)))
        #expect(match.suggestions.count == NoteCalendarMatch.maxSuggestions)
        #expect(match.suggestions.first == "Person 0")
    }

    @Test("an untitled meeting produces no match, so the note keeps today's title")
    func untitledEvent() {
        #expect(NoteCalendarMatch(event: meeting(title: "  ")) == nil)
        #expect(NoteCalendarMatch(event: meeting(title: "New Event")) == nil)
    }

    // MARK: - Lookup

    @Test("a meeting in progress at the start time is found")
    func findsMeetingInProgress() async throws {
        let reader = StaticCalendarReader(events: [meeting(startIn: -10 * 60)])
        let match = await NoteCalendarLinker.match(startedAt: epoch, reader: reader)
        #expect(match?.title == "Weekly sync")
    }

    @Test("a meeting starting within the early-start tolerance is found; a later one is not")
    func earlyStart() async {
        let soon = StaticCalendarReader(events: [meeting(startIn: 4 * 60)])
        #expect(await NoteCalendarLinker.match(startedAt: epoch, reader: soon) != nil)
        let later = StaticCalendarReader(events: [meeting(startIn: 20 * 60)])
        #expect(await NoteCalendarLinker.match(startedAt: epoch, reader: later) == nil)
    }

    @Test("a focus block, an ended meeting and an empty calendar produce no match")
    func noMatch() async {
        let focus = meeting(title: "Focus time", others: [])
        let ended = meeting(startIn: -3_600)
        let reader = StaticCalendarReader(events: [focus, ended])
        #expect(await NoteCalendarLinker.match(startedAt: epoch, reader: reader) == nil)
        #expect(await NoteCalendarLinker.match(startedAt: epoch, reader: StaticCalendarReader()) == nil)
    }

    @Test("without calendar access nothing is read and the permission prompt is never shown")
    func noAccessNeverReadsOrPrompts() async {
        for status in [CalendarAuthorization.notDetermined, .denied, .restricted, .writeOnly] {
            let reader = StaticCalendarReader(authorization: status, events: [meeting()])
            let match = await NoteCalendarLinker.match(startedAt: epoch, reader: reader)
            #expect(match == nil)
            #expect(await reader.requestCount == 0)
            #expect(await reader.eventQueryCount == 0)
        }
    }

    @Test("a reader that throws leaves the note exactly as today")
    func failingReader() async {
        let match = await NoteCalendarLinker.match(startedAt: epoch, reader: ThrowingReader())
        #expect(match == nil)
    }

    @Test("a reader that never answers is given up on after the timeout")
    func slowReader() async {
        let began = Date()
        let match = await NoteCalendarLinker.match(startedAt: epoch, reader: HangingReader(), timeout: 0.2)
        #expect(match == nil)
        // The reader sleeps for 30 s; the bound only has to show the linker did not wait for it.
        // It is loose because the timer task can be scheduled seconds late under a full-suite run.
        #expect(Date().timeIntervalSince(began) < 15)
    }

    @Test("a quick reader beats the timeout")
    func quickReaderWins() async {
        let reader = StaticCalendarReader(events: [meeting()])
        let match = await NoteCalendarLinker.match(startedAt: epoch, reader: reader, timeout: 5)
        #expect(match?.eventIdentifier == "sync")
    }
}

private struct ThrowingReader: CalendarReading {
    func authorization() async -> CalendarAuthorization { .fullAccess }
    func requestAccess() async -> CalendarAuthorization { .fullAccess }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { throw CalendarReadError.notAuthorized(.denied) }
}

private struct HangingReader: CalendarReading {
    func authorization() async -> CalendarAuthorization { .fullAccess }
    func requestAccess() async -> CalendarAuthorization { .fullAccess }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return []
    }
}
