import Foundation

/// One person on a calendar event, as EventKit reports it. Names and emails are read for the
/// duration of a lookup and never persisted by Hushy (see `docs/product/CONNECTORS.md` §2.1):
/// the only calendar-derived value a note stores is its title.
public struct CalendarAttendee: Sendable, Equatable, Hashable {
    public let name: String
    public let email: String?
    /// The event's own "this is me" flag (`EKParticipant.isCurrentUser`), so attendee-name
    /// suggestions and the "has other people" test never depend on knowing the user's address.
    public let isCurrentUser: Bool
    public let status: ParticipantStatus

    public enum ParticipantStatus: String, Sendable, Equatable, Codable {
        case unknown, pending, accepted, declined, tentative
    }

    public init(name: String, email: String? = nil, isCurrentUser: Bool = false, status: ParticipantStatus = .unknown) {
        self.name = name
        self.email = email
        self.isCurrentUser = isCurrentUser
        self.status = status
    }
}

/// Where a `CalendarEvent` copy came from: the macOS calendar store, or one of the direct
/// read-only connectors (`docs/product/CONNECTORS.md` §1.1).
public enum CalendarSourceKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case eventKit, google, microsoft
}

/// A calendar event as Hushy's reminder/title logic sees it — a plain value copied out of
/// EventKit (or built by hand in tests) so nothing below the adapter holds an `EKEvent`.
public struct CalendarEvent: Sendable, Equatable, Hashable, Identifiable {
    /// `EKEvent.eventIdentifier` plus the occurrence start for recurring events, so each
    /// occurrence of "Weekly sync" is reminded about exactly once.
    public struct OccurrenceID: Sendable, Equatable, Hashable {
        public let eventIdentifier: String
        public let start: Date

        public init(eventIdentifier: String, start: Date) {
            self.eventIdentifier = eventIdentifier
            self.start = start
        }
    }

    public let eventIdentifier: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let attendees: [CalendarAttendee]
    /// `EKEvent.location` and `EKEvent.url` joined; only ever inspected for a video-call link.
    public let locationAndURL: String
    public let calendarTitle: String
    /// The RFC 5545 UID shared by every copy of this meeting (EventKit's
    /// `calendarItemExternalIdentifier`, Google's `iCalUID`, Graph's `iCalUId`). Used only to
    /// collapse the same meeting read through two paths; nil when the source doesn't say.
    public let iCalUID: String?
    /// Which reader produced this copy (dedupe prefers EventKit on a tie).
    public let source: CalendarSourceKind

    public init(
        eventIdentifier: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        attendees: [CalendarAttendee] = [],
        locationAndURL: String = "",
        calendarTitle: String = "",
        iCalUID: String? = nil,
        source: CalendarSourceKind = .eventKit
    ) {
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.locationAndURL = locationAndURL
        self.calendarTitle = calendarTitle
        self.iCalUID = iCalUID
        self.source = source
    }

    public var id: OccurrenceID { OccurrenceID(eventIdentifier: eventIdentifier, start: start) }

    /// Everyone on the invite except the user, in invite order.
    public var otherAttendees: [CalendarAttendee] {
        attendees.filter { !$0.isCurrentUser }
    }

    /// The user's own reply, if they are listed as a participant. `nil` for events the user
    /// created without invitees (EventKit lists no attendees at all for those).
    public var currentUserStatus: CalendarAttendee.ParticipantStatus? {
        attendees.first(where: \.isCurrentUser)?.status
    }

    /// Hosts whose presence in the location/URL marks an event as a video call even when the
    /// user is the only listed attendee (a personal "Zoom with the dentist" entry).
    static let videoCallHosts: [String] = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
        "facetime.apple.com", "whereby.com", "around.co", "meet.jit.si", "discord.gg",
    ]

    public var hasVideoLink: Bool {
        let haystack = locationAndURL.lowercased()
        return Self.videoCallHosts.contains { haystack.contains($0) }
    }

    /// The reminder/title rule from `CONNECTORS.md` §2.1: a meeting is a timed event with someone
    /// else on it or a video link, that the user has not declined.
    public var looksLikeMeeting: Bool {
        guard !isAllDay, end > start else { return false }
        guard currentUserStatus != .declined else { return false }
        return !otherAttendees.isEmpty || hasVideoLink
    }

    /// Title with surrounding whitespace removed, or `nil` when the event has no usable title
    /// (EventKit hands back "" for untitled events, and "New Event" is Calendar.app's placeholder).
    public var usableTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("New Event") != .orderedSame else { return nil }
        return trimmed
    }

    public func contains(_ instant: Date) -> Bool {
        start <= instant && instant < end
    }
}

/// Mirrors `EKAuthorizationStatus` for calendars without importing EventKit into MurmurCore.
/// macOS 14+ has no read-only calendar grant, so "connected" means `.fullAccess` — the same
/// grant the Calendar voice action already uses.
public enum CalendarAuthorization: String, Sendable, Equatable {
    case notDetermined, denied, restricted, writeOnly, fullAccess

    /// Whether reads will succeed right now.
    public var canRead: Bool { self == .fullAccess }

    /// Whether clicking Connect could still change the answer (only the first ask shows the
    /// system prompt; after a denial the user has to flip it in System Settings).
    public var canPrompt: Bool { self == .notDetermined }
}

/// The calendar as Hushy reads it — implemented for real by `EventKitCalendarReader` (Murmur
/// target, since it needs EventKit and the app's TCC usage description) and by
/// `StaticCalendarReader` in tests and snapshot renders. Reads only; every write path stays a
/// confirmed voice action through `CalendarActionBackend`.
public protocol CalendarReading: Sendable {
    /// Never shows the system prompt; see `requestAccess`.
    func authorization() async -> CalendarAuthorization
    /// Shows the system prompt on first use (only ever called from the Connectors pane's Connect
    /// button) and returns the resulting state.
    func requestAccess() async -> CalendarAuthorization
    /// Events overlapping `[from, to)` across every enabled calendar account.
    func events(from: Date, to: Date) async throws -> [CalendarEvent]
}

/// In-memory reader for tests and snapshots: a fixed authorization and a fixed event list,
/// filtered by overlap like the real store. Counts `requestAccess` calls so tests can prove the
/// system prompt is never triggered by a poll.
public actor StaticCalendarReader: CalendarReading {
    private var status: CalendarAuthorization
    private let allEvents: [CalendarEvent]
    private let grantsOnRequest: Bool
    public private(set) var requestCount = 0
    public private(set) var eventQueryCount = 0

    public init(authorization: CalendarAuthorization = .fullAccess, events: [CalendarEvent] = [], grantsOnRequest: Bool = true) {
        self.status = authorization
        self.allEvents = events
        self.grantsOnRequest = grantsOnRequest
    }

    public func authorization() async -> CalendarAuthorization { status }

    public func requestAccess() async -> CalendarAuthorization {
        requestCount += 1
        if status == .notDetermined {
            status = grantsOnRequest ? .fullAccess : .denied
        }
        return status
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        eventQueryCount += 1
        guard status.canRead else { throw CalendarReadError.notAuthorized(status) }
        return allEvents
            .filter { $0.start < to && $0.end > from }
            .sorted { $0.start < $1.start }
    }
}

public enum CalendarReadError: Error, Sendable, Equatable {
    case notAuthorized(CalendarAuthorization)
}
