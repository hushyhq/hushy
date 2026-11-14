import Foundation
import GRDB

extension Store {
    /// Fills in a failed dictation's row with the result of running its audio again, keeping the
    /// row's id, its place in History and its audio file.
    ///
    /// Only while that row still exists and is still failed, checked in the same transaction as
    /// the update. Returns nil, and writes nothing, when the row was deleted (by the person or by
    /// retention) or has been filled in since (History's own Retry): a deleted row is never
    /// inserted again under its old id, and newer text is never overwritten.
    public func fillFailedDictation(id: Int64, with result: Dictation) throws -> Dictation? {
        try writer.write { db in
            guard let existing = try Dictation.fetchOne(db, key: id), existing.status == .failed else { return nil }
            var filled = result
            filled.id = id
            filled.createdAt = existing.createdAt
            filled.audioPath = existing.audioPath
            try filled.update(db)
            return filled
        }
    }
}
