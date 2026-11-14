import Foundation
import Testing
@testable import MurmurCore

@Suite("Calendar aggregate + dedupe")
struct CalendarDedupeTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_611_200)

    private func event(
        _ id: String, title: String = "Sync", at offset: TimeInterval = 0, minutes: Double = 30,
        uid: String? = "abc@google.com", source: CalendarSourceKind, others: Int = 1
    ) -> CalendarEvent {
        let start = t0.addingTimeInterval(offset)
        let attendees = [CalendarAttendee(name: "Me", isCurrentUser: true, status: .accepted)]
            + (0..<others).map { CalendarAttendee(name: "P\($0)", status: .accepted) }
        return CalendarEvent(
            eventIdentifier: id, title: title, start: start, end: start.addingTimeInterval(minutes * 60),
            attendees: attendees, iCalUID: uid, source: source)
    }

    @Test("same iCalUID via EventKit and Google → one event, EventKit kept on a tie")
    func tieGoesToEventKit() {
        let merged = CalendarEventDeduplicator.merge([
            event("g", uid: "ABC@google.com", source: .google), event("ek", uid: "abc", source: .eventKit),
        ])
        #expect(merged.map(\.eventIdentifier) == ["ek"])
    }

    @Test("Google copy kept when it has more attendees")
    func richerWins() {
        let merged = CalendarEventDeduplicator.merge([
            event("ek", source: .eventKit, others: 1), event("g", source: .google, others: 3),
        ])
        #expect(merged.map(\.eventIdentifier) == ["g"])
    }

    @Test("a synthetic self attendee doesn't outrank EventKit")
    func selfOnlyDoesNotCount() {
        var bare = event("ek", source: .eventKit, others: 0)
        bare = CalendarEvent(eventIdentifier: bare.eventIdentifier, title: bare.title, start: bare.start, end: bare.end, iCalUID: bare.iCalUID, source: .eventKit)
        let graph = event("m", source: .microsoft, others: 0)
        #expect(CalendarEventDeduplicator.merge([graph, bare]).map(\.eventIdentifier) == ["m"])  // 1 attendee vs 0
        #expect(CalendarEventDeduplicator.merge([event("ek2", source: .eventKit, others: 0), graph]).map(\.eventIdentifier) == ["ek2"])
    }

    @Test("equal richness and neither is EventKit → earlier reader wins")
    func earlierWins() {
        #expect(CalendarEventDeduplicator.merge([event("m", source: .microsoft), event("g", source: .google)]).map(\.eventIdentifier) == ["m"])
    }

    @Test("different occurrences of one recurring UID are distinct")
    func recurringOccurrences() {
        let merged = CalendarEventDeduplicator.merge([
            event("g1", at: 0, source: .google), event("g2", at: 7 * 86400, source: .google),
            event("ek1", at: 0, source: .eventKit), event("ek2", at: 7 * 86400, source: .eventKit),
        ])
        #expect(merged.map(\.eventIdentifier) == ["ek1", "ek2"])
    }

    @Test("nil UID falls back to title+start+end (case/whitespace-insensitive)")
    func titleFallback() {
        let merged = CalendarEventDeduplicator.merge([
            event("m", title: "  Weekly   SYNC ", uid: nil, source: .microsoft),
            event("ek", title: "weekly sync", uid: nil, source: .eventKit),
        ])
        #expect(merged.map(\.eventIdentifier) == ["ek"])
        // Same title, different end → different events.
        #expect(CalendarEventDeduplicator.merge([
            event("a", uid: nil, source: .eventKit), event("b", minutes: 60, uid: nil, source: .google),
        ]).count == 2)
    }

    @Test("cross-source copies with different UIDs merge on title+time; same-source never do")
    func crossSourceUIDMismatch() {
        #expect(CalendarEventDeduplicator.merge([
            event("m", uid: "040000008200E0", source: .microsoft), event("ek", uid: "exchange-ek-id", source: .eventKit),
        ]).map(\.eventIdentifier) == ["ek"])
        #expect(CalendarEventDeduplicator.merge([
            event("g1", uid: "one@google.com", source: .google), event("g2", uid: "two@google.com", source: .google),
        ]).count == 2)
    }

    @Test("sub-minute start differences still match; unrelated events untouched; output sorted")
    func sortedAndUntouched() {
        let merged = CalendarEventDeduplicator.merge([
            event("late", title: "Late", at: 3600, uid: "late", source: .google),
            event("g", at: 10, source: .google),
            event("ek", at: 0, source: .eventKit),
            event("early", title: "Early", at: -3600, uid: nil, source: .eventKit),
        ])
        #expect(merged.map(\.eventIdentifier) == ["early", "ek", "late"])
        #expect(CalendarEventDeduplicator.merge([]).isEmpty)
    }

    @Test("aggregate: queries readers, tolerates one failure, dedupes")
    func aggregate() async throws {
        let eventKit = StaticCalendarReader(events: [event("ek", source: .eventKit)])
        let google = StaticCalendarReader(events: [event("g", source: .google, others: 4), event("solo", title: "Solo", at: 7200, uid: "solo", source: .google)])
        let broken = FailingReader()
        let aggregate = AggregateCalendarReader(readers: [eventKit, broken, google])
        #expect(await aggregate.authorization() == .fullAccess)
        let events = try await aggregate.events(from: t0.addingTimeInterval(-86400), to: t0.addingTimeInterval(86400))
        #expect(events.map(\.eventIdentifier) == ["g", "solo"])
        #expect(await aggregate.lastFailures.keys.sorted() == [1])
    }

    @Test("aggregate: skips unauthorized readers; throws when nothing can read")
    func aggregateUnauthorized() async throws {
        let off = StaticCalendarReader(authorization: .notDetermined, events: [event("x", source: .google)])
        let on = StaticCalendarReader(events: [event("ek", source: .eventKit)])
        #expect(try await AggregateCalendarReader(readers: [off, on]).events(from: .distantPast, to: .distantFuture).map(\.eventIdentifier) == ["ek"])
        #expect(await off.eventQueryCount == 0)

        let none = AggregateCalendarReader(readers: [off])
        #expect(await none.authorization() == .notDetermined)
        await #expect(throws: CalendarReadError.notAuthorized(.notDetermined)) {
            try await none.events(from: .distantPast, to: .distantFuture)
        }
        await #expect(throws: CalendarConnectorError.httpStatus(500)) {
            try await AggregateCalendarReader(readers: [FailingReader()]).events(from: .distantPast, to: .distantFuture)
        }
    }

    @Test("existing call sites default to EventKit with no UID")
    func defaults() {
        let plain = CalendarEvent(eventIdentifier: "x", title: "t", start: t0, end: t0)
        #expect(plain.source == .eventKit && plain.iCalUID == nil)
    }
}

private struct FailingReader: CalendarReading {
    func authorization() async -> CalendarAuthorization { .fullAccess }
    func requestAccess() async -> CalendarAuthorization { .fullAccess }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { throw CalendarConnectorError.httpStatus(500) }
}
