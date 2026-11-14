import Foundation
import GRDB

/// Historical fixes that may have taught a recognizer's mistake in reverse. Detection only:
/// keep using the item until the person explicitly chooses Forget. A separate add-only table
/// preserves older builds' ability to decode `learnedItem` and remembers a review across launches.
public enum BackwardTermReview {
    /// A term is asked about when one of its heard spellings is a Dictionary term ("codec", heard as "Codex"), or
    /// when it and another learned term undo each other (one taught "codec" → "Codex", the other "Codex" → "codec"):
    /// then only the newer of the two is asked about, since a revert of the first is what teaches the second.
    public static func pending(items: [LearnedItem], dictionary: [DictionaryEntry], reviewed: Set<Int64>) -> [LearnedItem] {
        let terms = Set(dictionary.map { VocabularySwap.key($0.term) })
        let learned = items.filter { $0.kind == .term && $0.status != .forgotten }
        var learnedAtByDirection: [String: Date] = [:]
        for item in learned {
            for heard in item.heardAs { learnedAtByDirection[direction(heard, item.value)] = item.createdAt }
        }
        return learned.filter { item in
            guard let id = item.id, !reviewed.contains(id) else { return false }
            let value = VocabularySwap.key(item.value)
            return item.heardAs.contains {
                let key = VocabularySwap.key($0)
                guard key != value else { return false }
                if terms.contains(key) { return true }
                guard let other = learnedAtByDirection[direction(item.value, $0)] else { return false }
                return item.createdAt > other
            }
        }
    }

    /// The other learned terms that undo `item`: heard as its spelling, written as one of its heard spellings.
    static func opposites(of item: LearnedItem, in items: [LearnedItem]) -> [LearnedItem] {
        let undone = Set(item.heardAs.map { direction(item.value, $0) })
        return items.filter { other in
            other.id != item.id && other.kind == .term && other.status != .forgotten
                && other.heardAs.contains { undone.contains(direction($0, other.value)) }
        }
    }

    private static func direction(_ heard: String, _ written: String) -> String {
        "\(VocabularySwap.key(heard))→\(VocabularySwap.key(written))"
    }
}

extension Store {
    static func migrateLearnedTermReview(_ db: Database) throws {
        try db.create(table: "learnedTermReview") { table in
            table.column("itemID", .integer).primaryKey().references("learnedItem", onDelete: .cascade)
        }
    }

    public func backwardTermReviews() throws -> [LearnedItem] {
        try writer.read { db in try Self.backwardTermReviews(db) }
    }

    public static func backwardTermReviews(_ db: Database) throws -> [LearnedItem] {
        try BackwardTermReview.pending(items: learnedItems(db), dictionary: DictionaryEntry.fetchAll(db),
            reviewed: Set(Int64.fetchAll(db, sql: "SELECT itemID FROM learnedTermReview")))
    }

    /// An explicit Keep/Forget decision resolves the question once. Keep forgets the learned term it contradicts, so
    /// the two never undo each other; nothing else is removed.
    public func resolveBackwardTermReview(id: Int64, forget: Bool) throws {
        try writer.write { db in
            guard let item = try LearnedItem.fetchOne(db, key: id) else { return }
            let gone = forget ? [item] : BackwardTermReview.opposites(of: item, in: try LearnedItem.filter(Column("kind") == LearnedItem.Kind.term.rawValue).fetchAll(db))
            for old in gone { try Learner.forget(old).update(db) }
            try db.execute(sql: "INSERT OR IGNORE INTO learnedTermReview (itemID) VALUES (?)", arguments: [id])
        }
    }
}
