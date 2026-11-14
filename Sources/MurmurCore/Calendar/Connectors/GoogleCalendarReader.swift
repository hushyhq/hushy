import Foundation

/// Reads the signed-in user's Google Calendar directly with a read-only token
/// (`calendar.events.readonly`; `docs/product/CONNECTORS.md` §6.4). Same `CalendarReading`
/// contract as the EventKit reader, so the reminder/auto-title logic doesn't care which path an
/// event came from.
public struct GoogleCalendarReader: CalendarReading {
    static let skippedEventTypes: Set<String> = ["workingLocation", "outOfOffice", "focusTime", "birthday"]

    private let session: OAuthSession
    private let transport: any HTTPTransport
    private let calendarIDs: [String]
    private let timeZone: TimeZone

    public init(
        session: OAuthSession, transport: any HTTPTransport, calendarIDs: [String] = ["primary"],
        timeZone: TimeZone = .current
    ) {
        self.session = session
        self.transport = transport
        self.calendarIDs = calendarIDs
        self.timeZone = timeZone
    }

    public func authorization() async -> CalendarAuthorization {
        await session.hasTokens() ? .fullAccess : .notDetermined
    }

    /// Sign-in is the connect flow, not a permission prompt.
    public func requestAccess() async -> CalendarAuthorization {
        await authorization()
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        for calendarID in calendarIDs {
            var pageToken: String?
            var seenTokens: Set<String> = []
            for _ in 0..<ConnectorRequest.maxPages {
                let url = try Self.eventsURL(calendarID: calendarID, from: from, to: to, pageToken: pageToken)
                let data = try await ConnectorRequest.get(url, session: session, transport: transport)
                let page = try Self.parseEvents(data, calendarID: calendarID, timeZone: timeZone)
                events += page.events
                guard let next = page.nextPageToken, seenTokens.insert(next).inserted else { break }
                pageToken = next
            }
        }
        return events.sorted { $0.start < $1.start }
    }

    static func eventsURL(calendarID: String, from: Date, to: Date, pageToken: String?) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.percentEncodedPath = "/calendar/v3/calendars/\(HTTPRequest.percentEncode(calendarID))/events"
        var items = [
            URLQueryItem(name: "timeMin", value: ConnectorRequest.rfc3339(from)),
            URLQueryItem(name: "timeMax", value: ConnectorRequest.rfc3339(to)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250"),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.percentEncodedQuery = items
            .map { "\($0.name)=\(HTTPRequest.percentEncode($0.value ?? ""))" }
            .joined(separator: "&")
        guard let url = components.url else { throw CalendarConnectorError.malformedResponse }
        return url
    }

    /// Parses one `events.list` page. Tolerant of missing optional fields; an item without a
    /// usable start/end is skipped rather than failing the page.
    public static func parseEvents(
        _ data: Data, calendarID: String = "primary", timeZone: TimeZone = .current
    ) throws -> (events: [CalendarEvent], nextPageToken: String?) {
        let root = try ConnectorRequest.jsonObject(data)
        let items = root["items"] as? [[String: Any]] ?? []
        let events = items.compactMap { parseEvent($0, calendarID: calendarID, timeZone: timeZone) }
        let next = (root["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (events, next)
    }

    static func parseEvent(_ item: [String: Any], calendarID: String, timeZone: TimeZone) -> CalendarEvent? {
        guard let id = item["id"] as? String, !id.isEmpty else { return nil }
        if (item["status"] as? String) == "cancelled" { return nil }
        if let type = item["eventType"] as? String, skippedEventTypes.contains(type) { return nil }
        guard let start = item["start"] as? [String: Any], let end = item["end"] as? [String: Any] else { return nil }

        let isAllDay: Bool
        let startDate: Date, endDate: Date
        if let startDay = start["date"] as? String, let endDay = end["date"] as? String {
            guard let s = ConnectorRequest.allDayDate(startDay, timeZone: timeZone),
                  let e = ConnectorRequest.allDayDate(endDay, timeZone: timeZone) else { return nil }
            (isAllDay, startDate, endDate) = (true, s, e)
        } else if let s = (start["dateTime"] as? String).flatMap(parseDateTime),
                  let e = (end["dateTime"] as? String).flatMap(parseDateTime) {
            (isAllDay, startDate, endDate) = (false, s, e)
        } else {
            return nil
        }
        guard endDate >= startDate else { return nil }

        let attendees = (item["attendees"] as? [[String: Any]] ?? []).compactMap(parseAttendee)
        let entryPoints = ((item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? [])
            .map { $0["uri"] as? String }
        let location = ConnectorRequest.joinedLocation([item["location"] as? String, item["hangoutLink"] as? String] + entryPoints)

        return CalendarEvent(
            eventIdentifier: id,
            title: item["summary"] as? String ?? "",
            start: startDate, end: endDate, isAllDay: isAllDay,
            attendees: attendees, locationAndURL: location, calendarTitle: calendarID,
            iCalUID: (item["iCalUID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            source: .google)
    }

    static func parseAttendee(_ raw: [String: Any]) -> CalendarAttendee? {
        // Rooms and equipment are not people; they must not make an event "a meeting".
        if (raw["resource"] as? Bool) == true { return nil }
        let email = (raw["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = (raw["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? email
        guard let name else { return nil }
        let status: CalendarAttendee.ParticipantStatus = switch raw["responseStatus"] as? String {
        case "needsAction": .pending
        case "declined": .declined
        case "tentative": .tentative
        case "accepted": .accepted
        default: .unknown
        }
        return CalendarAttendee(name: name, email: email, isCurrentUser: (raw["self"] as? Bool) == true, status: status)
    }

    /// RFC 3339 with an offset or `Z`, with or without fractional seconds.
    static func parseDateTime(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
