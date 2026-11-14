import Foundation
import GRDB

extension Store {
    static func migrateKeepHeard(_ db: Database) throws {
        try db.create(table: KeepHeardEntry.databaseTableName) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("appBundleID", .text).notNull()
            t.column("heardKey", .text).notNull()
            t.column("writtenKey", .text).notNull()
            t.column("heard", .text).notNull()
            t.column("written", .text).notNull()
            t.column("source", .text).notNull()
            t.column("status", .text).notNull()
            t.column("observations", .integer).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("lastSeenAt", .datetime).notNull()
            t.uniqueKey(["appBundleID", "heardKey", "writtenKey"])
        }
    }

    @discardableResult
    public func recordReverts(_ reverts: [Revert], app: String, at: Date = Date()) throws -> [KeepHeardEntry] {
        try writer.write { db in try Self.recordReverts(reverts, app: app, at: at, db: db) }
    }

    static func recordReverts(_ reverts: [Revert], app: String, at: Date, db: Database) throws -> [KeepHeardEntry] {
        guard !app.isEmpty else { return [] }
        var written: [KeepHeardEntry] = []
        for revert in reverts {
            let swap = revert.swap
            var entry = try KeepHeardEntry.filter(Column("appBundleID") == app && Column("heardKey") == swap.heardKey && Column("writtenKey") == swap.writtenKey).fetchOne(db)
                ?? KeepHeardEntry(appBundleID: app, heardKey: swap.heardKey, writtenKey: swap.writtenKey,
                                  heard: revert.typed, written: swap.written, source: swap.source.rawValue,
                                  status: .active, observations: 0, createdAt: at, lastSeenAt: at)
            if entry.status == .forgotten {
                entry.status = .active
                entry.observations = 0
                entry.heard = revert.typed
                entry.written = swap.written
                entry.source = swap.source.rawValue
            }
            entry.observations += 1
            entry.lastSeenAt = at
            try entry.save(db)
            written.append(entry)
        }
        return written
    }

    public func keepHeardSet(for app: String?) throws -> KeepHeardSet {
        guard let app else { return .empty }
        return try writer.read { db in
            KeepHeardSet(entries: try KeepHeardEntry.filter(Column("appBundleID") == app).fetchAll(db))
        }
    }

    public func keepHeardEntries() throws -> [KeepHeardEntry] {
        try writer.read { db in try KeepHeardEntry.order(Column("lastSeenAt").desc).fetchAll(db) }
    }

    @discardableResult
    public func forgetKeepHeard(id: Int64) throws -> KeepHeardEntry? {
        try writer.write { db in
            guard var entry = try KeepHeardEntry.fetchOne(db, key: id) else { return nil }
            let previous = entry
            entry.status = .forgotten
            try entry.update(db)
            return previous
        }
    }

    public func restoreKeepHeard(_ entry: KeepHeardEntry) throws {
        try writer.write { db in try entry.update(db) }
    }
}
