import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The recorder-side half of "name a note from its meeting": the setting gates the lookup, a
/// match titles the note exactly once through one atomic store write, and a hand edit, a missing
/// meeting or a failed read leaves the note as it is today. No real calendar, no real recorder.
@Suite("Note calendar namer")
@MainActor
struct NoteCalendarNamerTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let defaultTitle = "Note · 9:00 AM"

    private func meeting(title: String = "Design review") -> CalendarEvent {
        let me = CalendarAttendee(name: "Me", isCurrentUser: true, status: .accepted)
        let dana = CalendarAttendee(name: "Dana Kim", status: .accepted)
        return CalendarEvent(
            eventIdentifier: "evt-1", title: title, start: epoch.addingTimeInterval(-60),
            end: epoch.addingTimeInterval(29 * 60), attendees: [me, dana])
    }

    private func makeNote(_ store: Store, title: String? = nil) throws -> Int64 {
        try #require(try store.save(Note(title: title ?? defaultTitle, createdAt: epoch, status: .recording)).id)
    }

    private func namer(_ reader: any CalendarReading, _ store: Store, enabled: Bool = true) -> NoteCalendarNamer {
        NoteCalendarNamer(reader: reader, store: store, isEnabled: { enabled })
    }

    @Test("a matching meeting titles the note, links it, and reports the new title once")
    func titlesNote() async throws {
        let store = try Store()
        let id = try makeNote(store)
        var reported: [String] = []

        await namer(StaticCalendarReader(events: [meeting()]), store)
            .begin(noteID: id, startedAt: epoch, defaultTitle: defaultTitle) { reported.append($0) }.value

        #expect(reported == ["Design review"])
        #expect(try store.note(id: id)?.title == "Design review")
        #expect(try store.calendarLink(forNote: id)?.eventIdentifier == "evt-1")
        #expect(try store.nameSuggestions(forNote: id) == ["Dana Kim"])
    }

    @Test("with the setting off the calendar is not even asked")
    func settingOff() async throws {
        let store = try Store()
        let id = try makeNote(store)
        let reader = StaticCalendarReader(events: [meeting()])
        var reported: [String] = []

        await namer(reader, store, enabled: false)
            .begin(noteID: id, startedAt: epoch, defaultTitle: defaultTitle) { reported.append($0) }.value

        #expect(reported.isEmpty)
        #expect(await reader.eventQueryCount == 0)
        #expect(try store.note(id: id)?.title == defaultTitle)
    }

    @Test("a title edited before the lookup finished is kept and not reported")
    func handEditSurvives() async throws {
        let store = try Store()
        let id = try makeNote(store, title: "My own name")
        var reported: [String] = []

        await namer(StaticCalendarReader(events: [meeting()]), store)
            .begin(noteID: id, startedAt: epoch, defaultTitle: defaultTitle) { reported.append($0) }.value

        #expect(reported.isEmpty)
        #expect(try store.note(id: id)?.title == "My own name")
    }

    @Test("no meeting, no access, or a deleted note leaves everything as today")
    func nothingToDo() async throws {
        let store = try Store()
        let id = try makeNote(store)
        var reported: [String] = []
        let record: @MainActor (String) -> Void = { reported.append($0) }

        await namer(StaticCalendarReader(events: []), store)
            .begin(noteID: id, startedAt: epoch, defaultTitle: defaultTitle, onTitled: record).value
        await namer(StaticCalendarReader(authorization: .denied, events: [meeting()]), store)
            .begin(noteID: id, startedAt: epoch, defaultTitle: defaultTitle, onTitled: record).value
        try store.deleteNote(id: id)
        await namer(StaticCalendarReader(events: [meeting()]), store)
            .begin(noteID: id, startedAt: epoch, defaultTitle: defaultTitle, onTitled: record).value

        #expect(reported.isEmpty)
        #expect(try store.calendarLink(forNote: id) == nil)
    }

    @Test("begin returns at once even when the calendar never answers")
    func beginDoesNotBlock() async throws {
        let store = try Store()
        let id = try makeNote(store)
        let began = Date()
        let task = NoteCalendarNamer(reader: SilentReader(), store: store, isEnabled: { true }, timeout: 0.2)
            .begin(noteID: id, startedAt: epoch, defaultTitle: defaultTitle) { _ in }
        #expect(Date().timeIntervalSince(began) < 0.1)
        await task.value
        #expect(try store.note(id: id)?.title == defaultTitle)
    }
}

private struct SilentReader: CalendarReading {
    func authorization() async -> CalendarAuthorization { .fullAccess }
    func requestAccess() async -> CalendarAuthorization { .fullAccess }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return []
    }
}
