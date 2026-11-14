import Foundation
import GRDB

/// Persisted completion state for one action item within a `Note`. Action items themselves live
/// as a plain `[String]` on `Note` (extracted once by summarization and never reordered in place),
/// so a row here is addressed by `(noteId, itemIndex)` — the item's position in that array —
/// rather than duplicating the item's text. Only "done" items get a row; a missing row means
/// "not done", which keeps the common case (nothing checked yet) free.
public struct NoteActionItemStatus: Codable, Sendable, Equatable {
    public var noteId: Int64
    public var itemIndex: Int
    public var isDone: Bool
    public var updatedAt: Date

    public init(noteId: Int64, itemIndex: Int, isDone: Bool, updatedAt: Date = Date()) {
        self.noteId = noteId
        self.itemIndex = itemIndex
        self.isDone = isDone
        self.updatedAt = updatedAt
    }
}

extension NoteActionItemStatus: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "noteActionItem"
}
