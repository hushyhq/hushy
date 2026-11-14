import Foundation
import GRDB

/// The calendar meeting a note was started from (task 84): enough to say which event it was and
/// when, nothing more. The event's attendees are *not* stored here; only their names live on, as
/// naming suggestions (`note_name_suggestion`), and both rows are deleted with the note.
/// Event titles and names are personal data: never log them, never put them in metrics.
public struct NoteCalendarLink: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "note_calendar_link"

    public var noteId: Int64
    /// `EKEvent.eventIdentifier` at the time the note started.
    public var eventIdentifier: String
    public var eventTitle: String
    public var eventStart: Date
    public var eventEnd: Date
    /// The identity every occurrence of a recurring event shares (the iCalendar UID, else the
    /// EventKit identifier), so "Weekly sync with Acme" links its meetings. Nil before v26.
    public var seriesKey: String?

    public init(noteId: Int64, eventIdentifier: String, eventTitle: String, eventStart: Date, eventEnd: Date, seriesKey: String? = nil) {
        self.noteId = noteId
        self.eventIdentifier = eventIdentifier
        self.eventTitle = eventTitle
        self.eventStart = eventStart
        self.eventEnd = eventEnd
        self.seriesKey = seriesKey
    }
}

/// One attendee name offered as a speaker name for a note. A suggestion only: attendee is not the
/// same as speaker, so nothing assigns it automatically.
struct NoteNameSuggestion: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "note_name_suggestion"
    var noteId: Int64
    var ordinal: Int
    var name: String
}

/// What a calendar lookup found for a new note: the meeting's identity, the title to give the
/// note, and the attendee names to suggest. Built from a `CalendarEvent` and handed to
/// `Store.applyCalendarMatch`.
public struct NoteCalendarMatch: Sendable, Equatable {
    /// A 200-person all-hands should not become 200 rows; the first invitees are the useful ones.
    public static let maxSuggestions = 50
    static let maxNameLength = 80

    public let eventIdentifier: String
    public let title: String
    public let start: Date
    public let end: Date
    public let suggestions: [String]
    public let seriesKey: String
    /// Everyone on the invite who did not decline, the user included, for meeting memory.
    public let attendees: [Attendee]

    public struct Attendee: Sendable, Equatable {
        public let name: String
        public let companyDomain: String?
        public let isSelf: Bool
    }

    /// `nil` when the event has no usable title (untitled, or Calendar.app's "New Event"): there
    /// is nothing to name the note after, so it keeps today's title.
    public init?(event: CalendarEvent) {
        guard let title = event.usableTitle else { return nil }
        self.eventIdentifier = event.eventIdentifier
        self.title = title
        self.start = event.start
        self.end = event.end
        self.suggestions = CalendarEventMatcher.speakerNameSuggestions(for: event)
            .filter { !Self.looksLikeEmailAddress($0) }
            .map { String($0.prefix(Self.maxNameLength)) }
            .prefix(Self.maxSuggestions)
            .map { $0 }
        self.seriesKey = event.iCalUID ?? event.eventIdentifier
        self.attendees = event.attendees
            .filter { $0.status != .declined }
            .prefix(Self.maxSuggestions)
            .compactMap { attendee in
                // An invitee known only by address still says which company was in the meeting;
                // the address itself is not kept, so the name stays empty.
                let raw = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = Self.looksLikeEmailAddress(raw) ? "" : String(raw.prefix(Self.maxNameLength))
                let domain = CompanyDomain.of(email: attendee.email ?? (raw.isEmpty ? nil : raw))
                guard !name.isEmpty || domain != nil else { return nil }
                return Attendee(name: name, companyDomain: domain, isSelf: attendee.isCurrentUser)
            }
    }

    /// EventKit hands back the address as the name when an invitee has no display name; a bare
    /// address is not a name worth offering.
    static func looksLikeEmailAddress(_ text: String) -> Bool {
        text.contains("@") && !text.contains(where: \.isWhitespace)
    }
}

enum NoteCalendarSchema {
    static func migrate(_ db: Database) throws {
        try db.create(table: NoteCalendarLink.databaseTableName) { t in
            t.column("noteId", .integer).primaryKey().references("note", onDelete: .cascade)
            t.column("eventIdentifier", .text).notNull()
            t.column("eventTitle", .text).notNull()
            t.column("eventStart", .datetime).notNull()
            t.column("eventEnd", .datetime).notNull()
        }
        try db.create(table: NoteNameSuggestion.databaseTableName) { t in
            t.column("noteId", .integer).notNull().references("note", onDelete: .cascade)
            t.column("ordinal", .integer).notNull()
            t.column("name", .text).notNull()
            t.primaryKey(["noteId", "ordinal"])
        }
    }
}

extension Store {
    /// Records the meeting a note came from and, when the note still has the title it was created
    /// with, renames it after the meeting. One transaction, so the title can never be overwritten
    /// by a lookup that lost a race with a rename: the title only changes if the stored title is
    /// still exactly `expectedTitle`. The link and attendee names are kept either way.
    /// Returns whether the title was changed; `false` too when the note no longer exists.
    @discardableResult
    public func applyCalendarMatch(_ match: NoteCalendarMatch, toNote noteId: Int64, replacingTitle expectedTitle: String) throws -> Bool {
        try writer.write { db in
            guard let stored = try String.fetchOne(db, sql: "SELECT title FROM note WHERE id = ?", arguments: [noteId]) else {
                return false
            }
            let renamed = stored == expectedTitle
            if renamed {
                try db.execute(
                    sql: "UPDATE note SET title = ?, updatedAt = ? WHERE id = ?",
                    arguments: [match.title, Date(), noteId])
            }
            try NoteCalendarLink(
                noteId: noteId, eventIdentifier: match.eventIdentifier, eventTitle: match.title,
                eventStart: match.start, eventEnd: match.end, seriesKey: match.seriesKey
            ).save(db)
            try NoteAttendee.filter(Column("noteId") == noteId).deleteAll(db)
            for (ordinal, attendee) in match.attendees.enumerated() {
                try NoteAttendee(
                    noteId: noteId, ordinal: ordinal, name: attendee.name,
                    companyDomain: attendee.companyDomain, isSelf: attendee.isSelf
                ).insert(db)
            }
            try NoteNameSuggestion.filter(Column("noteId") == noteId).deleteAll(db)
            for (ordinal, name) in match.suggestions.enumerated() {
                try NoteNameSuggestion(noteId: noteId, ordinal: ordinal, name: name).insert(db)
            }
            return renamed
        }
    }

    public func calendarLink(forNote noteId: Int64) throws -> NoteCalendarLink? {
        try writer.read { db in try NoteCalendarLink.fetchOne(db, key: noteId) }
    }

    /// Attendee names to offer when labelling this note's speakers, in invite order. Empty for a
    /// note that was not linked to a meeting.
    public func nameSuggestions(forNote noteId: Int64) throws -> [String] {
        try writer.read { db in
            try NoteNameSuggestion
                .filter(Column("noteId") == noteId)
                .order(Column("ordinal"))
                .fetchAll(db)
                .map(\.name)
        }
    }
}
