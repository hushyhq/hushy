import Foundation
import GRDB

/// One person on the calendar event a note was recorded from, kept so meetings can be linked by
/// who was in them and which company they work for (meeting memory). Only the name, whether it is
/// the user, and the company part of the address are kept: the address itself is never stored,
/// and a personal mail domain (gmail.com and the like) is dropped, because it names no company.
/// Deleted with the note. Personal data: never log it or put it in metrics.
public struct NoteAttendee: Codable, Sendable, Equatable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "note_attendee"

    public var noteId: Int64
    public var ordinal: Int
    public var name: String
    /// "acme.com"; nil for a personal domain or an attendee without an address.
    public var companyDomain: String?
    public var isSelf: Bool
    /// Where the row came from. Names read from a meeting app's window are never attendee rows (decision #13);
    /// they are scored guesses in `speaker_assignment`.
    public var source: AttendeeSource

    public init(noteId: Int64, ordinal: Int, name: String, companyDomain: String?, isSelf: Bool, source: AttendeeSource = .calendar) {
        self.noteId = noteId
        self.ordinal = ordinal
        self.name = name
        self.companyDomain = companyDomain
        self.isSelf = isSelf
        self.source = source
    }
}

public enum AttendeeSource: String, Codable, Sendable, CaseIterable {
    /// From the calendar event the note was started from.
    case calendar
    /// Added by hand.
    case user
}

/// The company part of an email address, or nil when the domain is a personal mail provider.
public enum CompanyDomain {
    public static let personal: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com",
        "live.com", "msn.com", "yahoo.com", "ymail.com", "aol.com", "proton.me", "protonmail.com",
        "pm.me", "gmx.com", "gmx.de", "mail.com", "fastmail.com", "zoho.com", "hey.com", "yandex.com",
    ]

    public static func of(email: String?) -> String? {
        guard let email, let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard domain.contains("."), !personal.contains(domain) else { return nil }
        return domain
    }
}

extension Store {
    /// The attendees stored for `noteId`, in invite order.
    public func attendees(forNote noteId: Int64) throws -> [NoteAttendee] {
        try writer.read { db in
            try NoteAttendee.filter(Column("noteId") == noteId).order(Column("ordinal")).fetchAll(db)
        }
    }
}
