import Foundation
import Testing
@testable import MurmurCore

/// Fixtures are hand-built from the documented `events.list` / Event resource schema — no real
/// calendar data.
@Suite("Google Calendar parser and reader")
struct GoogleCalendarParserTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    static let page1 = """
    {
      "kind": "calendar#events",
      "nextPageToken": "page-2-token",
      "items": [
        {
          "id": "evt1", "status": "confirmed", "summary": "Design review", "iCalUID": "evt1uid@google.com",
          "start": {"dateTime": "2026-09-28T09:00:00-07:00", "timeZone": "America/Los_Angeles"},
          "end": {"dateTime": "2026-09-28T09:30:00-07:00"},
          "location": "Room 4",
          "hangoutLink": "https://meet.google.com/abc-defg-hij",
          "conferenceData": {"entryPoints": [
            {"entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"},
            {"entryPointType": "phone", "uri": "tel:+1-555-0100"}
          ]},
          "attendees": [
            {"email": "me@example.com", "self": true, "responseStatus": "accepted"},
            {"email": "dana@example.com", "displayName": "Dana Kim", "responseStatus": "needsAction", "organizer": true},
            {"email": "room@resource.calendar.google.com", "displayName": "Room 4", "resource": true, "responseStatus": "accepted"},
            {"email": "lee@example.com", "responseStatus": "tentative"}
          ]
        },
        {
          "id": "evt2", "status": "confirmed", "summary": "Offsite", "iCalUID": "evt2uid@google.com",
          "start": {"date": "2026-09-29"}, "end": {"date": "2026-09-30"}
        },
        {"id": "evt3", "status": "cancelled", "summary": "Gone",
         "start": {"dateTime": "2026-09-28T10:00:00Z"}, "end": {"dateTime": "2026-09-28T11:00:00Z"}},
        {"id": "evt4", "status": "confirmed", "eventType": "focusTime", "summary": "Focus",
         "start": {"dateTime": "2026-09-28T12:00:00Z"}, "end": {"dateTime": "2026-09-28T14:00:00Z"}},
        {"id": "evt5", "eventType": "outOfOffice", "start": {"dateTime": "2026-09-28T12:00:00Z"}, "end": {"dateTime": "2026-09-28T14:00:00Z"}},
        {"id": "evt6", "eventType": "workingLocation", "start": {"date": "2026-09-28"}, "end": {"date": "2026-09-29"}},
        {
          "id": "series_20260928T150000Z", "recurringEventId": "series", "summary": "1:1",
          "iCalUID": "series@google.com",
          "originalStartTime": {"dateTime": "2026-09-28T15:00:00Z"},
          "start": {"dateTime": "2026-09-28T15:00:00.000Z"}, "end": {"dateTime": "2026-09-28T15:30:00.000Z"},
          "attendees": [
            {"email": "me@example.com", "self": true, "responseStatus": "declined"},
            {"email": "boss@example.com", "responseStatus": "accepted"}
          ]
        },
        {"id": "broken", "summary": "No start"},
        {"id": "bad-date", "start": {"dateTime": "yesterday"}, "end": {"dateTime": "2026-09-28T15:30:00Z"}}
      ]
    }
    """

    @Test("parses timed, all-day, recurring; skips cancelled/focus/OOO/working-location/broken")
    func parsesPage() throws {
        let page = try GoogleCalendarReader.parseEvents(Data(Self.page1.utf8), calendarID: "primary", timeZone: Self.berlin)
        #expect(page.nextPageToken == "page-2-token")
        #expect(page.events.map(\.eventIdentifier) == ["evt1", "evt2", "series_20260928T150000Z"])

        let review = page.events[0]
        #expect(review.title == "Design review")
        #expect(review.start == Date(timeIntervalSince1970: 1_790_611_200))  // 2026-09-28T16:00Z
        #expect(review.end.timeIntervalSince(review.start) == 1800)
        #expect(!review.isAllDay)
        #expect(review.source == .google && review.iCalUID == "evt1uid@google.com" && review.calendarTitle == "primary")
        #expect(review.attendees.map(\.name) == ["me@example.com", "Dana Kim", "lee@example.com"])
        #expect(review.attendees.map(\.status) == [.accepted, .pending, .tentative])
        #expect(review.attendees[0].isCurrentUser && !review.attendees[1].isCurrentUser)
        #expect(review.currentUserStatus == .accepted)
        #expect(review.locationAndURL == "Room 4 https://meet.google.com/abc-defg-hij https://meet.google.com/abc-defg-hij tel:+1-555-0100")
        #expect(review.looksLikeMeeting)

        let offsite = page.events[1]
        #expect(offsite.isAllDay && !offsite.looksLikeMeeting)
        var berlinCalendar = Calendar(identifier: .gregorian)
        berlinCalendar.timeZone = Self.berlin
        #expect(offsite.start == berlinCalendar.date(from: DateComponents(year: 2026, month: 9, day: 29)))
        #expect(offsite.end.timeIntervalSince(offsite.start) == 86400)

        let declined = page.events[2]
        #expect(declined.start == Date(timeIntervalSince1970: 1_790_607_600))  // 15:00Z
        #expect(declined.currentUserStatus == .declined && !declined.looksLikeMeeting)
    }

    @Test("empty page, missing items, and non-JSON")
    func edgeCases() throws {
        #expect(try GoogleCalendarReader.parseEvents(Data(#"{"items":[]}"#.utf8)).events.isEmpty)
        #expect(try GoogleCalendarReader.parseEvents(Data(#"{}"#.utf8)).nextPageToken == nil)
        #expect(throws: CalendarConnectorError.malformedResponse) { try GoogleCalendarReader.parseEvents(Data("<html>".utf8)) }
        #expect(throws: CalendarConnectorError.malformedResponse) { try GoogleCalendarReader.parseEvents(Data("[]".utf8)) }
    }

    @Test("reader follows nextPageToken, sends Bearer, and builds the documented query")
    func readerPaginates() async throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let transport = RecordingTransport { request in
            if request.queryItems["pageToken"] == "page-2-token" {
                return .json(#"{"items":[{"id":"p2","summary":"Later","start":{"dateTime":"2026-09-28T20:00:00Z"},"end":{"dateTime":"2026-09-28T21:00:00Z"}}]}"#)
            }
            return .json(Self.page1)
        }
        let session = ConnectorFixtures.session(transport: transport, store: store)
        try store.save(ConnectorFixtures.tokens(expiresIn: 3600), for: session.account)
        let reader = GoogleCalendarReader(session: session, transport: transport, timeZone: Self.utc)
        #expect(await reader.authorization() == .fullAccess)

        let from = Date(timeIntervalSince1970: 1_790_553_600), to = from.addingTimeInterval(86400 * 3)
        let events = try await reader.events(from: from, to: to)
        #expect(events.map(\.eventIdentifier).contains("p2"))
        #expect(events.count == 4)
        #expect(events == events.sorted { $0.start < $1.start })

        let sent = await transport.requests
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.headers["Authorization"] == "Bearer access-1" && $0.method == .get })
        #expect(sent[0].url.host == "www.googleapis.com" && sent[0].url.path == "/calendar/v3/calendars/primary/events")
        #expect(sent[0].queryItems == [
            "timeMin": "2026-09-28T00:00:00Z", "timeMax": "2026-10-01T00:00:00Z", "singleEvents": "true",
            "orderBy": "startTime", "maxResults": "250",
        ])
        #expect(sent[1].queryItems["pageToken"] == "page-2-token")
    }

    @Test("a repeating page token stops pagination")
    func repeatingToken() async throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let transport = RecordingTransport { _ in .json(#"{"items":[],"nextPageToken":"same"}"#) }
        let session = ConnectorFixtures.session(transport: transport, store: store)
        try store.save(ConnectorFixtures.tokens(expiresIn: 3600), for: session.account)
        _ = try await GoogleCalendarReader(session: session, transport: transport).events(from: .distantPast, to: .distantFuture)
        #expect(await transport.requests.count == 2)
    }

    @Test("401 → one refresh and retry; second 401 → reauthorization")
    func unauthorizedRetry() async throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let transport = RecordingTransport { request in
            if request.url.host == "oauth2.googleapis.com" { return ConnectorFixtures.tokenJSON(access: "access-2") }
            return request.headers["Authorization"] == "Bearer access-2" ? .json(#"{"items":[]}"#) : HTTPResponse(statusCode: 401)
        }
        let session = ConnectorFixtures.session(transport: transport, store: store)
        try store.save(ConnectorFixtures.tokens(expiresIn: 3600), for: session.account)
        _ = try await GoogleCalendarReader(session: session, transport: transport).events(from: .distantPast, to: .distantFuture)
        #expect(await transport.requests.count == 3)
        #expect(await session.refreshCount == 1)

        let alwaysDenied = RecordingTransport { request in
            request.url.host == "oauth2.googleapis.com" ? ConnectorFixtures.tokenJSON(access: "access-3") : HTTPResponse(statusCode: 401)
        }
        let session2 = ConnectorFixtures.session(transport: alwaysDenied, store: store)
        await #expect(throws: OAuthError.reauthorizationRequired) {
            try await GoogleCalendarReader(session: session2, transport: alwaysDenied).events(from: .distantPast, to: .distantFuture)
        }
        #expect(await alwaysDenied.requests.count == 3)
    }

    @Test("no tokens → notDetermined, and requestAccess doesn't change it")
    func notConnected() async {
        let transport = RecordingTransport { _ in HTTPResponse(statusCode: 500) }
        let session = ConnectorFixtures.session(transport: transport, store: OAuthTokenStore(keyStore: InMemoryKeyStore()))
        let reader = GoogleCalendarReader(session: session, transport: transport)
        #expect(await reader.authorization() == .notDetermined)
        #expect(await reader.requestAccess() == .notDetermined)
        #expect(await transport.requests.isEmpty)
    }

    @Test("calendar ids are percent-encoded into the path")
    func calendarIDEncoding() throws {
        let url = try GoogleCalendarReader.eventsURL(calendarID: "team/x@group.calendar.google.com", from: .distantPast, to: .distantFuture, pageToken: "a+b/c")
        #expect(url.absoluteString.contains("/calendars/team%2Fx%40group.calendar.google.com/events"))
        #expect(url.absoluteString.contains("pageToken=a%2Bb%2Fc"))
    }
}
