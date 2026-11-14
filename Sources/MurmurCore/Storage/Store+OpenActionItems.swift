import Foundation
import GRDB

/// An action item that is not checked off, with the note it came from. Personal data: never log
/// it or put it in metrics.
public struct OpenActionItem: Equatable, Sendable {
    public let noteId: Int64
    public let noteTitle: String
    public let noteDate: Date
    /// Position in the note's `actionItems`; where its check-off is kept.
    public let itemIndex: Int
    /// The item's one-line form, as the note shows it in lists.
    public let line: String
    /// The item as fields; for a note without them, the line is the task and owner and due are empty.
    public let detail: ActionItemDetail
}

extension Store {
    /// Every open (not checked off) action item of every ready note, newest note first and each
    /// note's items in their own order.
    ///
    /// - `owner`: only items whose owner field is this name (ignoring case and surrounding
    ///   spaces). A note without fields has no owners to match, so none of its items are returned:
    ///   an owner is never guessed from the sentence.
    /// - `limit`: at most this many items.
    public func openActionItems(
        owner: String? = nil, limit: Int = 200
    ) throws -> [OpenActionItem] {
        let wanted = owner?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try writer.read { db in
            let done = try Self.doneByNote(db)
            let rows = Note.filter(Column("status") == Note.Status.ready.rawValue && Column("actionItems") != "[]")
            let cursor = try rows.order(Column("createdAt").desc, Column("id").desc)
                .select(Column("id"), Column("title"), Column("createdAt"), Column("actionItems"), Column("actionItemDetails"), as: Row.self)
                .fetchCursor(db)
            var result: [OpenActionItem] = []
            while let row = try cursor.next(), result.count < limit {
                let items = Self.openItems(row, done: done[row["id"] as Int64] ?? [], owner: wanted)
                result += items.prefix(limit - result.count)
            }
            return result
        }
    }

    private static func doneByNote(_ db: Database) throws -> [Int64: Set<Int>] {
        let rows = try NoteActionItemStatus.filter(Column("isDone") == true).fetchAll(db)
        return Dictionary(grouping: rows, by: \.noteId).mapValues { Set($0.map(\.itemIndex)) }
    }

    private static func openItems(_ row: Row, done: Set<Int>, owner: String?) -> [OpenActionItem] {
        let decoder = JSONDecoder()
        let lines = (row["actionItems"] as String?).flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) } ?? []
        let details = ActionItemDetail.aligned(
            (row["actionItemDetails"] as String?).flatMap { try? decoder.decode([ActionItemDetail].self, from: Data($0.utf8)) },
            count: lines.count)
        return lines.indices.compactMap { index in
            guard !done.contains(index) else { return nil }
            let detail = details?[index] ?? .plain(lines[index])
            if let owner, detail.owner.trimmingCharacters(in: .whitespaces).lowercased() != owner { return nil }
            return OpenActionItem(
                noteId: row["id"], noteTitle: row["title"], noteDate: row["createdAt"],
                itemIndex: index, line: lines[index], detail: detail)
        }
    }
}
