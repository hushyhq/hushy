import Foundation
import GRDB

extension Store {
    /// Inserted dictations in the same app and local calendar day, newest first.
    public func recentInApp(_ bundleID: String, on day: Date = Date(), limit: Int = 3,
                            calendar: Calendar = .current) throws -> [Dictation] {
        guard let interval = calendar.dateInterval(of: .day, for: day), limit > 0 else { return [] }
        return try writer.read { db in
            try Dictation
                .filter(Column("appBundleID") == bundleID)
                .filter(Column("status") == Dictation.Status.inserted.rawValue)
                .filter(Column("createdAt") >= interval.start && Column("createdAt") < interval.end)
                .filter(Column("createdAt") <= day)
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(min(limit, 3))
                .fetchAll(db)
        }
    }
}
