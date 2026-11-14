import Foundation
import Testing
@testable import MurmurCore

/// Fixtures hand-built from the documented Graph `event` resource / `calendarView` response —
/// no real calendar data.
@Suite("Microsoft Graph parser and reader")
struct MicrosoftGraphParserTests {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let nextLink = "https://graph.microsoft.com/v1.0/me/calendarView?startDateTime=2026-09-28T00:00:00Z&endDateTime=2026-10-01T00:00:00Z&$top=250&$skip=250"

    static let page1 = """
    {
      "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users('me')/calendarView",
      "@odata.nextLink": "\(nextLink)",
      "value": [
        {
          "id": "AAMk-utc", "iCalUId": "040000008200E00074C5B7101A82E0080000000001", "subject": "Planning",
          "type": "occurrence", "seriesMasterId": "AAMk-master", "isAllDay": false, "isCancelled": false, "isOrganizer": false,
          "start": {"dateTime": "2026-09-28T16:00:00.0000000", "timeZone": "UTC"},
          "end": {"dateTime": "2026-09-28T16:45:00.0000000", "timeZone": "UTC"},
          "responseStatus": {"response": "tentativelyAccepted", "time": "0001-01-01T00:00:00Z"},
          "location": {"displayName": "Conf Room B"},
          "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/xyz"},
          "organizer": {"emailAddress": {"name": "Pat Organizer", "address": "pat@example.com"}},
          "attendees": [
            {"type": "required", "status": {"response": "notResponded"}, "emailAddress": {"name": "Me Person", "address": "Me@Example.com"}},
            {"type": "required", "status": {"response": "accepted"}, "emailAddress": {"name": "Sam", "address": "sam@example.com"}},
            {"type": "optional", "status": {"response": "none"}, "emailAddress": {"name": "", "address": "ana@example.com"}},
            {"type": "resource", "status": {"response": "accepted"}, "emailAddress": {"name": "Room B", "address": "roomb@example.com"}}
          ]
        },
        {
          "id": "AAMk-la", "iCalUId": "uid-la", "subject": "West coast sync", "type": "singleInstance",
          "isAllDay": false, "isCancelled": false,
          "start": {"dateTime": "2026-09-28T09:00:00.0000000", "timeZone": "America/Los_Angeles"},
          "end": {"dateTime": "2026-09-28T09:30:00.0000000", "timeZone": "America/Los_Angeles"},
          "responseStatus": {"response": "declined"},
          "onlineMeetingUrl": "https://teams.microsoft.com/l/meetup-join/abc",
          "attendees": [{"type": "required", "status": {"response": "accepted"}, "emailAddress": {"name": "Kai", "address": "kai@example.com"}}]
        },
        {
          "id": "AAMk-cancelled", "subject": "Cancelled", "isCancelled": true,
          "start": {"dateTime": "2026-09-28T10:00:00.0000000", "timeZone": "UTC"},
          "end": {"dateTime": "2026-09-28T11:00:00.0000000", "timeZone": "UTC"}
        },
        {
          "id": "AAMk-master", "subject": "Series master", "type": "seriesMaster",
          "start": {"dateTime": "2026-01-01T10:00:00.0000000", "timeZone": "UTC"},
          "end": {"dateTime": "2026-01-01T11:00:00.0000000", "timeZone": "UTC"}
        },
        {
          "id": "AAMk-allday", "subject": "Holiday", "isAllDay": true, "type": "singleInstance",
          "start": {"dateTime": "2026-09-29T00:00:00.0000000", "timeZone": "UTC"},
          "end": {"dateTime": "2026-09-30T00:00:00.0000000", "timeZone": "UTC"},
          "responseStatus": {"response": "organizer"}, "isOrganizer": true,
          "organizer": {"emailAddress": {"name": "Me Person", "address": "me@example.com"}}
        },
        {
          "id": "AAMk-windows-tz", "subject": "Windows zone", "type": "singleInstance",
          "start": {"dateTime": "2026-09-28T18:00:00.0000000", "timeZone": "Pacific Standard Time"},
          "end": {"dateTime": "2026-09-28T18:30:00.0000000", "timeZone": "Pacific Standard Time"},
          "responseStatus": {"response": "organizer"}
        },
        {"id": "AAMk-bad", "subject": "Bad date", "start": {"dateTime": "2026-13-45T99:00:00.0000000", "timeZone": "UTC"},
         "end": {"dateTime": "2026-09-28T18:30:00.0000000", "timeZone": "UTC"}}
      ]
    }
    """

    @Test("parses UTC and zoned 7-digit dateTimes, maps statuses, skips cancelled/seriesMaster/bad")
    func parsesPage() throws {
        let page = try MicrosoftGraphCalendarReader.parseEvents(Data(Self.page1.utf8), accountEmail: "me@example.com", timeZone: Self.berlin)
        #expect(page.nextLink == Self.nextLink)
        #expect(page.events.map(\.eventIdentifier) == ["AAMk-utc", "AAMk-la", "AAMk-allday", "AAMk-windows-tz"])

        let planning = page.events[0]
        #expect(planning.start == Date(timeIntervalSince1970: 1_790_611_200))
        #expect(planning.end.timeIntervalSince(planning.start) == 45 * 60)
        #expect(planning.source == .microsoft && planning.iCalUID == "040000008200E00074C5B7101A82E0080000000001")
        #expect(planning.locationAndURL == "Conf Room B https://teams.microsoft.com/l/meetup-join/xyz")
        // Self matched by address (case-insensitively) carries the event's own response.
        #expect(planning.attendees.map(\.name) == ["Me Person", "Sam", "ana@example.com", "Pat Organizer"])
        #expect(planning.attendees.map(\.status) == [.tentative, .accepted, .pending, .accepted])
        #expect(planning.attendees.map(\.isCurrentUser) == [true, false, false, false])
        #expect(planning.currentUserStatus == .tentative && planning.looksLikeMeeting)

        let westCoast = page.events[1]
        #expect(westCoast.start == Date(timeIntervalSince1970: 1_790_611_200))  // 09:00 PDT = 16:00Z
        #expect(westCoast.locationAndURL == "https://teams.microsoft.com/l/meetup-join/abc")
        // No self attendee listed → a synthetic one carries `responseStatus`.
        #expect(westCoast.currentUserStatus == .declined && !westCoast.looksLikeMeeting)
        #expect(westCoast.otherAttendees.map(\.name) == ["Kai"])

        let holiday = page.events[2]
        var berlinCalendar = Calendar(identifier: .gregorian)
        berlinCalendar.timeZone = Self.berlin
        #expect(holiday.isAllDay && holiday.start == berlinCalendar.date(from: DateComponents(year: 2026, month: 9, day: 29)))
        #expect(holiday.otherAttendees.isEmpty)

        let windows = page.events[3]
        #expect(windows.start == Date(timeIntervalSince1970: 1_790_611_200 + 7200))  // unknown zone → UTC
        #expect(windows.otherAttendees.isEmpty && !windows.looksLikeMeeting)
    }

    @Test("organizer is added as another attendee when the user is only an invitee")
    func organizerAdded() throws {
        let json = """
        {"value":[{"id":"x","subject":"1:1","start":{"dateTime":"2026-09-28T16:00:00.0000000","timeZone":"UTC"},
          "end":{"dateTime":"2026-09-28T16:30:00.0000000","timeZone":"UTC"},"responseStatus":{"response":"accepted"},
          "organizer":{"emailAddress":{"name":"Dana","address":"dana@example.com"}},
          "attendees":[{"status":{"response":"accepted"},"emailAddress":{"name":"Me","address":"me@example.com"}}]}]}
        """
        let event = try #require(try MicrosoftGraphCalendarReader.parseEvents(Data(json.utf8), accountEmail: "me@example.com").events.first)
        #expect(event.otherAttendees.map(\.name) == ["Dana"] && event.looksLikeMeeting)
    }

    @Test("reader sends Prefer UTC + Bearer, follows @odata.nextLink verbatim")
    func readerPaginates() async throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let transport = RecordingTransport { request in
            request.url.absoluteString == Self.nextLink ? .json(#"{"value":[]}"#) : .json(Self.page1)
        }
        let session = ConnectorFixtures.session(ConnectorFixtures.microsoft, transport: transport, store: store, accountEmail: "me@example.com")
        try store.save(ConnectorFixtures.tokens(expiresIn: 3600), for: session.account)
        let reader = MicrosoftGraphCalendarReader(session: session, transport: transport)
        let from = Date(timeIntervalSince1970: 1_790_553_600)
        let events = try await reader.events(from: from, to: from.addingTimeInterval(3 * 86400))
        #expect(events.count == 4)

        let sent = await transport.requests
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.headers["Prefer"] == #"outlook.timezone="UTC""# && $0.headers["Authorization"] == "Bearer access-1" })
        #expect(sent[0].url.host == "graph.microsoft.com" && sent[0].url.path == "/v1.0/me/calendarView")
        let query = sent[0].queryItems
        #expect(query["startDateTime"] == "2026-09-28T00:00:00Z" && query["endDateTime"] == "2026-10-01T00:00:00Z")
        #expect(query["$top"] == "250" && query["$select"]?.hasPrefix("id,iCalUId,subject,start,end,isAllDay,isCancelled") == true)
        #expect(sent[1].url.absoluteString == Self.nextLink)
    }

    @Test("a nextLink pointing anywhere but Graph over HTTPS is refused", arguments: [
        "https://evil.example/v1.0/me/calendarView?$skip=250",
        "http://graph.microsoft.com/v1.0/me/calendarView?$skip=250",
        "https://graph.microsoft.com.evil.example/v1.0/me/calendarView",
        "https://user@graph.microsoft.com/v1.0/me/calendarView",
        "https://graph.microsoft.com:8443/v1.0/me/calendarView",
        "https://graph.microsoft.com/beta/me/calendarView",
        "not a url",
    ])
    func untrustedNextLink(link: String) async throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let body = #"{"value":[],"@odata.nextLink":"\#(link)"}"#
        let transport = RecordingTransport { _ in .json(body) }
        let session = ConnectorFixtures.session(ConnectorFixtures.microsoft, transport: transport, store: store)
        try store.save(ConnectorFixtures.tokens(expiresIn: 3600), for: session.account)
        await #expect(throws: CalendarConnectorError.untrustedNextLink) {
            try await MicrosoftGraphCalendarReader(session: session, transport: transport).events(from: .distantPast, to: .distantFuture)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("non-2xx other than 401 surfaces as httpStatus")
    func httpError() async throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let transport = RecordingTransport { _ in HTTPResponse(statusCode: 429) }
        let session = ConnectorFixtures.session(ConnectorFixtures.microsoft, transport: transport, store: store)
        try store.save(ConnectorFixtures.tokens(expiresIn: 3600), for: session.account)
        await #expect(throws: CalendarConnectorError.httpStatus(429)) {
            try await MicrosoftGraphCalendarReader(session: session, transport: transport).events(from: .distantPast, to: .distantFuture)
        }
    }

    @Test("status mapping")
    func statuses() {
        #expect(MicrosoftGraphCalendarReader.mapStatus("notResponded") == .pending)
        #expect(MicrosoftGraphCalendarReader.mapStatus("none") == .pending)
        #expect(MicrosoftGraphCalendarReader.mapStatus("tentativelyAccepted") == .tentative)
        #expect(MicrosoftGraphCalendarReader.mapStatus("organizer") == .accepted)
        #expect(MicrosoftGraphCalendarReader.mapStatus("declined") == .declined)
        #expect(MicrosoftGraphCalendarReader.mapStatus(nil) == .unknown)
    }
}
