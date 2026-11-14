import Foundation
import GRDB

extension Store {
    /// One dictation by its identifier, or nil when it does not exist (deleted, or removed by
    /// the retention setting). A read: nothing is written. History uses it to find the day of a
    /// dictation another screen asked it to open.
    public func dictation(id: Int64) throws -> Dictation? {
        try writer.read { db in try Dictation.fetchOne(db, key: id) }
    }
}
