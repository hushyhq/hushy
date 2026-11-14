import Foundation
import GRDB

/// A confirmed, executed voice action — the History row for one Calendar event, Reminder, or
/// Shortcut run created via the fn+⌃ action trigger (docs/research/voice-actions.md). Stored
/// separately from `Dictation` (migration "v9-actions") rather than folded into it, since an
/// action's fields (kind, undo token, detail line) don't fit `Dictation`'s text-insertion shape
/// and a single multi-intent utterance can produce more than one `ActionRecord` from one
/// `Dictation` row.
public struct ActionRecord: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable {
        case completed
        case undone
        /// Nothing happened: the action was refused or the backend said no.
        case failed
        /// It may have happened and Hushy cannot tell (a Shortcut that timed out or stopped
        /// partway). Never retried on its own, and the row says so.
        case uncertain
    }

    public var id: Int64?
    public var createdAt: Date
    public var kind: ProposedAction.Kind
    public var title: String
    /// A short human-readable detail line for the History row, e.g. "Tomorrow · 3:00–3:30 PM"
    /// or "Shortcut: Start Focus".
    public var detail: String?
    public var sourceText: String
    public var status: Status
    /// The backend identifier used to undo this action (EventKit only); nil once undone or for
    /// backends with no undo (Shortcuts).
    public var undoBackendID: String?
    /// The `Dictation` row this action was extracted from, if any (nil for actions created
    /// outside a dictation session, e.g. a future retry path).
    public var dictationID: Int64?
    /// When Undo was tried and failed (the item is still there). Nil otherwise. The record stays
    /// `completed` and keeps its undo token, so Undo can be tried again while it is offered.
    public var undoFailedAt: Date?

    public init(
        id: Int64? = nil, createdAt: Date = Date(), kind: ProposedAction.Kind, title: String,
        detail: String? = nil, sourceText: String, status: Status = .completed,
        undoBackendID: String? = nil, dictationID: Int64? = nil, undoFailedAt: Date? = nil
    ) {
        self.undoFailedAt = undoFailedAt
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.title = title
        self.detail = detail
        self.sourceText = sourceText
        self.status = status
        self.undoBackendID = undoBackendID
        self.dictationID = dictationID
    }
}

extension ActionRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "actionRecord"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension ProposedAction.Kind: DatabaseValueConvertible {}

// MARK: - Store CRUD

extension Store {
    @discardableResult
    public func save(_ action: ActionRecord) throws -> ActionRecord {
        try writer.write { db in
            var copy = action
            try copy.save(db)
            return copy
        }
    }

    public func actionRecord(id: Int64) throws -> ActionRecord? {
        try writer.read { db in try ActionRecord.fetchOne(db, key: id) }
    }

    /// Marks a completed action as undone (History no longer offers "Undo" for it once this
    /// runs — the undo window itself is enforced by the caller, e.g. the undo-window timer).
    public func markActionUndone(id: Int64) throws {
        _ = try writer.write { db in
            try db.execute(
                sql: "UPDATE actionRecord SET status = ?, undoBackendID = NULL, undoFailedAt = NULL WHERE id = ?",
                arguments: [ActionRecord.Status.undone.rawValue, id])
        }
    }

    /// Records that Undo was tried and the item is still there. The record stays completed and
    /// keeps its undo token; only a completed record can carry the mark.
    public func markActionUndoFailed(id: Int64, at date: Date = Date()) throws {
        _ = try writer.write { db in
            try db.execute(
                sql: "UPDATE actionRecord SET undoFailedAt = ? WHERE id = ? AND status = ?",
                arguments: [date, id, ActionRecord.Status.completed.rawValue])
        }
    }

    /// Clears a completed action's undo affordance without marking it undone: the undo
    /// window passed with no tap, so History must stop offering "Undo" for it while the
    /// record itself stays completed (and the monthly use is kept).
    public func expireActionUndo(id: Int64) throws {
        _ = try writer.write { db in
            try db.execute(
                sql: "UPDATE actionRecord SET undoBackendID = NULL WHERE id = ?",
                arguments: [id])
        }
    }

    public func recentActions(limit: Int = 50) throws -> [ActionRecord] {
        try writer.read { db in
            try ActionRecord.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }
}
