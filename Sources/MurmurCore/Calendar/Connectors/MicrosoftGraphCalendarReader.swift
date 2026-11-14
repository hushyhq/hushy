import Foundation

/// Reads the signed-in user's Outlook calendar through Microsoft Graph `calendarView` with a
/// read-only token (`Calendars.Read`; `docs/product/CONNECTORS.md` §6.5).
public struct MicrosoftGraphCalendarReader: CalendarReading {
    static let host = "graph.microsoft.com"
    static let selectFields = "id,iCalUId,subject,start,end,isAllDay,isCancelled,isOrganizer,attendees,organizer,responseStatus,onlineMeeting,onlineMeetingUrl,location,seriesMasterId,type,showAs"
    static let preferUTC = "outlook.timezone=\"UTC\""

    private let session: OAuthSession
    private let transport: any HTTPTransport
    private let timeZone: TimeZone

    public init(session: OAuthSession, transport: any HTTPTransport, timeZone: TimeZone = .current) {
        self.session = session
        self.transport = transport
        self.timeZone = timeZone
    }

    public func authorization() async -> CalendarAuthorization {
        await session.hasTokens() ? .fullAccess : .notDetermined
    }

    public func requestAccess() async -> CalendarAuthorization {
        await authorization()
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        var url = Self.calendarViewURL(from: from, to: to)
        var seen: Set<String> = []
        for _ in 0..<ConnectorRequest.maxPages {
            let data = try await ConnectorRequest.get(
                url, extraHeaders: ["Prefer": Self.preferUTC], session: session, transport: transport)
            let page = try Self.parseEvents(data, accountEmail: session.accountEmail, timeZone: timeZone)
            events += page.events
            guard let next = page.nextLink, seen.insert(next).inserted else { break }
            url = try Self.trustedNextLink(next)
        }
        return events.sorted { $0.start < $1.start }
    }

    static func calendarViewURL(from: Date, to: Date) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/v1.0/me/calendarView"
        components.percentEncodedQuery = [
            ("startDateTime", ConnectorRequest.rfc3339(from)),
            ("endDateTime", ConnectorRequest.rfc3339(to)),
            ("$top", "250"),
            ("$select", selectFields),
        ].map { "\($0.0)=\(HTTPRequest.percentEncode($0.1))" }.joined(separator: "&")
        // Force-unwrap is safe: every component is a constant or percent-encoded.
        return components.url!
    }

    /// `@odata.nextLink` is followed verbatim, but only if it is Graph over HTTPS — the bearer
    /// token must never be sent to a host a response body named.
    static func trustedNextLink(_ link: String) throws -> URL {
        guard let url = URL(string: link), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host, url.port == nil || url.port == 443,
              url.user == nil, url.path.hasPrefix("/v1.0/")
        else { throw CalendarConnectorError.untrustedNextLink }
        return url
    }

    public static func parseEvents(
        _ data: Data, accountEmail: String? = nil, timeZone: TimeZone = .current
    ) throws -> (events: [CalendarEvent], nextLink: String?) {
        let root = try ConnectorRequest.jsonObject(data)
        let items = root["value"] as? [[String: Any]] ?? []
        let events = items.compactMap { parseEvent($0, accountEmail: accountEmail, timeZone: timeZone) }
        return (events, (root["@odata.nextLink"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    static func parseEvent(_ item: [String: Any], accountEmail: String?, timeZone: TimeZone) -> CalendarEvent? {
        guard let id = item["id"] as? String, !id.isEmpty else { return nil }
        if (item["isCancelled"] as? Bool) == true { return nil }
        if (item["type"] as? String) == "seriesMaster" { return nil }
        let isAllDay = (item["isAllDay"] as? Bool) == true
        guard let start = parseDate(item["start"], allDay: isAllDay, localTimeZone: timeZone),
              let end = parseDate(item["end"], allDay: isAllDay, localTimeZone: timeZone),
              end >= start
        else { return nil }

        let selfAddress = accountEmail?.lowercased()
        let selfStatus = mapStatus((item["responseStatus"] as? [String: Any])?["response"] as? String)
        var attendees: [CalendarAttendee] = []
        var addresses: Set<String> = []
        var sawSelf = false
        for raw in item["attendees"] as? [[String: Any]] ?? [] {
            if (raw["type"] as? String) == "resource" { continue }
            guard let parsed = parsePerson(raw["emailAddress"]) else { continue }
            let isSelf = parsed.address != nil && parsed.address == selfAddress
            sawSelf = sawSelf || isSelf
            if let address = parsed.address { addresses.insert(address) }
            let status = isSelf ? selfStatus : mapStatus((raw["status"] as? [String: Any])?["response"] as? String)
            attendees.append(CalendarAttendee(name: parsed.name, email: parsed.displayEmail, isCurrentUser: isSelf, status: status))
        }
        // Graph lists invitees but not the organizer; a 1:1 invite from Dana would otherwise
        // show only the user and not look like a meeting.
        // Skipped when the user is the organizer (their own "Dentist" entry is not a meeting).
        let userIsOrganizer = (item["isOrganizer"] as? Bool) == true
            || ((item["responseStatus"] as? [String: Any])?["response"] as? String) == "organizer"
        if !userIsOrganizer,
           let organizer = parsePerson((item["organizer"] as? [String: Any])?["emailAddress"]),
           let address = organizer.address, !addresses.contains(address), address != selfAddress {
            attendees.append(CalendarAttendee(name: organizer.name, email: organizer.displayEmail, status: .accepted))
        }
        // Graph doesn't flag "self" on attendees; carry the user's own response so
        // `currentUserStatus` (declined → not a meeting) works.
        if !sawSelf {
            attendees.insert(CalendarAttendee(name: "Me", email: accountEmail, isCurrentUser: true, status: selfStatus), at: 0)
        }

        let online = (item["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String
        let location = ConnectorRequest.joinedLocation([
            (item["location"] as? [String: Any])?["displayName"] as? String, online, item["onlineMeetingUrl"] as? String,
        ])
        return CalendarEvent(
            eventIdentifier: id,
            title: item["subject"] as? String ?? "",
            start: start, end: end, isAllDay: isAllDay,
            attendees: attendees, locationAndURL: location,
            calendarTitle: CalendarProvider.microsoft.displayName,
            iCalUID: (item["iCalUId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            source: .microsoft)
    }

    static func parsePerson(_ raw: Any?) -> (name: String, address: String?, displayEmail: String?)? {
        guard let raw = raw as? [String: Any] else { return nil }
        let email = (raw["address"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let name = (raw["name"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? email else { return nil }
        return (name, email?.lowercased(), email)
    }

    static func mapStatus(_ response: String?) -> CalendarAttendee.ParticipantStatus {
        switch response {
        case "notResponded", "none": .pending
        case "tentativelyAccepted": .tentative
        case "accepted", "organizer": .accepted
        case "declined": .declined
        default: .unknown
        }
    }

    /// Graph `dateTimeTimeZone`: `yyyy-MM-dd'T'HH:mm:ss(.fffffff)` with no offset, in `timeZone`
    /// (IANA id; `UTC`, unknown and Windows names fall back to UTC — we ask for UTC anyway via
    /// `Prefer`). All-day events are floating dates and map to local midnight, like EventKit.
    static func parseDate(_ raw: Any?, allDay: Bool, localTimeZone: TimeZone) -> Date? {
        guard let raw = raw as? [String: Any], let text = raw["dateTime"] as? String, text.count >= 19 else { return nil }
        if allDay { return ConnectorRequest.allDayDate(text, timeZone: localTimeZone) }
        let zoneName = raw["timeZone"] as? String ?? "UTC"
        let zone = TimeZone(identifier: zoneName) ?? TimeZone(identifier: "UTC")!
        let head = Array(text.prefix(19))
        guard head[4] == "-", head[7] == "-", head[10] == "T", head[13] == ":", head[16] == ":" else { return nil }
        func number(_ range: Range<Int>) -> Int? { Int(String(head[range])) }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }
}
