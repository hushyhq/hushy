import Foundation
import GRDB

/// A line the person typed during (or after) a meeting, Granola style: their own words, kept as
/// the spine of the page and never rewritten by the model. `atSeconds` is the recording time the
/// line was typed at, so it opens the transcript at that moment; `nil` for a line added once the
/// recording had ended. Deleted with its note.
public struct MeetingJot: Codable, Sendable, Equatable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "meeting_jot"

    public var id: Int64?
    public var noteId: Int64
    public var atSeconds: Double?
    public var text: String
    public var createdAt: Date

    public init(id: Int64? = nil, noteId: Int64, atSeconds: Double?, text: String, createdAt: Date = Date()) {
        self.id = id
        self.noteId = noteId
        self.atSeconds = atSeconds
        self.text = text
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// A typed line is stored trimmed; an empty one is not stored at all.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxLength))
    }

    public static let maxLength = 2_000

    /// "? does it include the EU team" or "does it include the EU team?": a question in the
    /// person's own words. The leading mark is dropped from the shown text.
    public var isQuestion: Bool { text.hasPrefix("?") || text.hasSuffix("?") }
    public var isDecision: Bool { text.hasPrefix("!") }
    public var shownText: String {
        isQuestion && text.hasPrefix("?") || isDecision ? text.dropFirst().trimmingCharacters(in: .whitespaces) : text
    }
}

extension Store {
    /// Adds one typed line to a note. Returns nil, and stores nothing, for a blank line.
    @discardableResult
    public func addJot(noteId: Int64, text: String, atSeconds: Double?, now: Date = Date()) throws -> MeetingJot? {
        guard let clean = MeetingJot.normalized(text) else { return nil }
        return try writer.write { db in
            var jot = MeetingJot(noteId: noteId, atSeconds: atSeconds.map { max(0, $0) }, text: clean, createdAt: now)
            try jot.insert(db)
            return jot
        }
    }

    /// A note's typed lines in the order they happened: timed lines by time, untimed ones after.
    public func jots(noteId: Int64) throws -> [MeetingJot] {
        try writer.read { db in
            try MeetingJot.filter(Column("noteId") == noteId).fetchAll(db)
        }
        .sorted(by: MeetingJot.isBefore)
    }

    /// Replaces a line's words; a blank edit deletes the line.
    public func updateJot(id: Int64, text: String) throws {
        try writer.write { db in
            guard let clean = MeetingJot.normalized(text) else {
                _ = try MeetingJot.deleteOne(db, key: id)
                return
            }
            try db.execute(sql: "UPDATE meeting_jot SET text = ? WHERE id = ?", arguments: [clean, id])
        }
    }

    public func deleteJot(id: Int64) throws {
        discardPreMeetingsBackup()
        _ = try writer.write { db in try MeetingJot.deleteOne(db, key: id) }
    }
}

extension MeetingJot {
    static func isBefore(_ lhs: MeetingJot, _ rhs: MeetingJot) -> Bool {
        switch (lhs.atSeconds, rhs.atSeconds) {
        case let (l?, r?) where l != r: l < r
        case (.some, nil): true
        case (nil, .some): false
        default: lhs.createdAt < rhs.createdAt
        }
    }
}
