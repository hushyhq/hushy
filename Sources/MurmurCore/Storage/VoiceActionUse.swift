import Foundation
import GRDB

/// One counted chord use for the Free plan's monthly allowance (`VoiceActionQuota`), migration
/// "v15-voice-action-uses". Separate from `ActionRecord` on purpose: a confirmed card with three
/// rows is three History records but *one* use, an answer or a screen summary is a use with no
/// History record at all, and History rows must never disappear when a use is given back.
/// Nothing the user said is stored here — only when, what kind, and which record (if any) an
/// Undo would give back.
public struct VoiceActionUse: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// A Do (Tier-1 chip or a confirmed card), including an AI hand-off's link.
        case action
        /// An answer from the user's own stuff.
        case ask
        /// A screen summary.
        case summary
    }

    public var id: Int64?
    public var usedAt: Date
    public var kind: Kind
    /// The History record whose Undo gives this use back; nil for answers and summaries.
    public var actionRecordID: Int64?
    /// Given back by Undo: no longer counted.
    public var undone: Bool

    public init(id: Int64? = nil, usedAt: Date = Date(), kind: Kind, actionRecordID: Int64? = nil, undone: Bool = false) {
        self.id = id
        self.usedAt = usedAt
        self.kind = kind
        self.actionRecordID = actionRecordID
        self.undone = undone
    }
}

extension VoiceActionUse: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "voiceActionUse"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static func migrate(_ db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("usedAt", .datetime).notNull().indexed()
            t.column("kind", .text).notNull()
            t.column("actionRecordID", .integer).indexed()
            t.column("undone", .boolean).notNull().defaults(to: false)
        }
    }
}

// MARK: - Store

extension Store {
    @discardableResult
    public func recordVoiceActionUse(_ use: VoiceActionUse) throws -> VoiceActionUse {
        try writer.write { db in
            var copy = use
            try copy.save(db)
            return copy
        }
    }

    /// Gives back the use tied to `actionRecordID` (the done chip's or History's Undo).
    public func markVoiceActionUseUndone(actionRecordID: Int64) throws {
        _ = try writer.write { db in
            try db.execute(
                sql: "UPDATE voiceActionUse SET undone = 1 WHERE actionRecordID = ?", arguments: [actionRecordID])
        }
    }

    /// Gives back every use that belongs to an action already marked undone. Safe to run any
    /// time (it changes nothing once settled): it covers a refund that failed and was forgotten
    /// when the app quit.
    @discardableResult
    public func reconcileVoiceActionRefunds() throws -> Int {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE voiceActionUse SET undone = 1
                WHERE undone = 0 AND actionRecordID IN (SELECT id FROM actionRecord WHERE status = ?)
                """, arguments: [ActionRecord.Status.undone.rawValue])
            return db.changesCount
        }
    }

    /// Uses in `interval` that were not given back.
    public func voiceActionCount(in interval: DateInterval) throws -> Int {
        try writer.read { db in
            try VoiceActionUse
                .filter(Column("usedAt") >= interval.start && Column("usedAt") < interval.end)
                .filter(Column("undone") == false)
                .fetchCount(db)
        }
    }

    /// `voiceActionCount(in:)` for the local calendar month containing `now`.
    public func voiceActionsThisMonth(now: Date = Date(), calendar: Calendar = .current) throws -> Int {
        try voiceActionCount(in: VoiceActionQuota.monthInterval(containing: now, calendar: calendar))
    }
}
