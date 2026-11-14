import Foundation
import GRDB

/// A decision, action item, open question or change from a meeting (migration v29). Check-offs address a fact by its
/// `uuid`, never by an array index. Legacy notes got theirs from `actionItems`, the summary's `Decided:` lines and
/// `!` jots (`origin == .legacy` or `.jot`); those legacy columns stay as they were, read-only.
public struct MeetingFact: Codable, Sendable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "meeting_fact"

    public enum Kind: String, Codable, Sendable, CaseIterable { case decision, action, openQuestion, change }
    public enum Status: String, Codable, Sendable, CaseIterable { case open, done, dismissed }
    public enum Grounding: String, Codable, Sendable { case verified, unsupported, unchecked }
    public enum Origin: String, Codable, Sendable { case model, user, jot, legacy }

    public static let maxTextScalars = LegacyFactBackfill.maxTextScalars

    public var id: Int64?
    public var uuid: String
    public var noteId: Int64
    public var kind: Kind
    /// Transcript order within the note.
    public var ordinal: Int
    public var text: String
    /// As shown; nil means unassigned.
    public var ownerText: String?
    public var ownerSpeakerId: Int64?
    public var ownerAttendeeOrdinal: Int?
    /// The extractor's owner before grounding. Never shown; for the scorecard.
    public var ownerClaim: String?
    /// As said ("by Friday").
    public var due: String?
    /// "yyyy-MM-dd" when a date is known.
    public var dueDate: String?
    public var status: Status
    public var statusAt: Date?
    /// Verbatim from one turn.
    public var quote: String?
    /// A cache, re-resolved from `quote` and `t0` after any re-assembly.
    public var evidenceTurnId: Int64?
    /// UTF-16 offsets into the turn's text.
    public var evidenceStart: Int?
    public var evidenceEnd: Int?
    public var t0: Double?
    public var t1: Double?
    public var jotId: Int64?
    public var grounding: Grounding
    public var origin: Origin
    /// "r10d+meeting-extract-v1c/p1", "summary/v1", "legacy", "user".
    public var extractor: String
    public var supersededBy: Int64?
    public var userEdited: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil, uuid: String = UUID().uuidString, noteId: Int64, kind: Kind, ordinal: Int, text: String,
        ownerText: String? = nil, ownerSpeakerId: Int64? = nil, ownerAttendeeOrdinal: Int? = nil, ownerClaim: String? = nil,
        due: String? = nil, dueDate: String? = nil, status: Status = .open, statusAt: Date? = nil, quote: String? = nil,
        evidenceTurnId: Int64? = nil, evidenceStart: Int? = nil, evidenceEnd: Int? = nil, t0: Double? = nil, t1: Double? = nil,
        jotId: Int64? = nil, grounding: Grounding, origin: Origin, extractor: String, supersededBy: Int64? = nil,
        userEdited: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.uuid = uuid
        self.noteId = noteId
        self.kind = kind
        self.ordinal = ordinal
        self.text = text
        self.ownerText = ownerText
        self.ownerSpeakerId = ownerSpeakerId
        self.ownerAttendeeOrdinal = ownerAttendeeOrdinal
        self.ownerClaim = ownerClaim
        self.due = due
        self.dueDate = dueDate
        self.status = status
        self.statusAt = statusAt
        self.quote = quote
        self.evidenceTurnId = evidenceTurnId
        self.evidenceStart = evidenceStart
        self.evidenceEnd = evidenceEnd
        self.t0 = t0
        self.t1 = t1
        self.jotId = jotId
        self.grounding = grounding
        self.origin = origin
        self.extractor = extractor
        self.supersededBy = supersededBy
        self.userEdited = userEdited
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// What the UI, export and MCP show: not replaced, not dismissed, and either verified against the transcript or
    /// written by the person (or kept from before facts existed). An unsupported model fact is stored but hidden.
    public var isVisible: Bool {
        supersededBy == nil && status != .dismissed && (grounding == .verified || origin != .model)
    }

    /// `isVisible` as SQL.
    public static var visible: SQL {
        SQL(sql: "supersededBy IS NULL AND status <> 'dismissed' AND (grounding = 'verified' OR origin IN ('user','jot','legacy'))")
    }
}

extension Store {
    /// The note's facts, grouped by kind in transcript order. By default only what `MeetingFact.isVisible` shows.
    public func facts(noteId: Int64, visibleOnly: Bool = true) throws -> [MeetingFact] {
        try writer.read { db in
            var request = MeetingFact.filter(Column("noteId") == noteId)
            if visibleOnly { request = request.filter(MeetingFact.visible) }
            return try request.order(Column("kind"), Column("ordinal"), Column("id")).fetchAll(db)
        }
    }

    /// Replaces the model's facts for a note with a new extraction, in one transaction. Earlier model facts the
    /// person has not touched (open, not edited) are deleted; ones they edited or checked off stay, and a new fact
    /// quoting the same words as one of those is dropped instead of shown twice. Returns the facts inserted.
    @discardableResult
    public func replaceModelFacts(noteId: Int64, extractor: String, facts: [MeetingFact], now: Date = Date()) throws -> [MeetingFact] {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM meeting_fact WHERE noteId = ? AND origin = 'model' AND userEdited = 0 AND status = 'open'
                """, arguments: [noteId])
            let kept = Set(try String.fetchAll(db, sql: """
                SELECT quote FROM meeting_fact WHERE noteId = ? AND origin = 'model' AND quote IS NOT NULL
                """, arguments: [noteId]).map(Self.quoteKey))
            var inserted: [MeetingFact] = []
            for fact in facts where !(fact.quote.map { kept.contains(Self.quoteKey($0)) } ?? false) {
                var row = fact
                row.id = nil
                row.noteId = noteId
                row.origin = .model
                row.extractor = extractor
                row.createdAt = now
                row.updatedAt = now
                try row.insert(db)
                inserted.append(row)
            }
            return inserted
        }
    }

    /// Checks a fact off, reopens it, or dismisses it. Returns false when no fact has that uuid.
    @discardableResult
    public func setFactStatus(uuid: String, status: MeetingFact.Status, at now: Date = Date()) throws -> Bool {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE meeting_fact SET status = ?, statusAt = ?, updatedAt = ? WHERE uuid = ?",
                arguments: [status.rawValue, status == .open ? nil : now, now, uuid])
            return db.changesCount == 1
        }
    }

    private static func quoteKey(_ quote: String) -> String {
        quote.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).joined(separator: " ")
    }
}
