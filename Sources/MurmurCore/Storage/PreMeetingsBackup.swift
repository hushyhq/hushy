import Foundation
import GRDB
import os

/// A copy of the store taken just before the frozen meetings migrations (v26 to v29) first run on an existing file.
/// It exists only while an upgrade may need undoing: a migration that completes and checks out deletes it at once,
/// and so does every erase the person asks for, because the copy would otherwise keep what they deleted. A copy left
/// by a failed upgrade is deleted after 30 days. It holds the person's text: owner-only (0600), excluded from Time
/// Machine, never made while data encryption is on (the database itself is not encrypted, so the copy could not be
/// either), never logged or read except to restore.
enum PreMeetingsBackup {
    static let fileName = "hushy-pre-v26.sqlite"
    static let keepFor: TimeInterval = 30 * 24 * 3600
    static let identifiers: Set<String> = ["v26-attendees", "v27-capture-segment", "v28-turn", "v29-meeting-fact"]

    static func url(next storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Writes the copy when the file already holds migrations and lacks any of v26 to v29, and no copy exists yet
    /// (a run that failed keeps the first, older copy). SQLite writes it inside a fresh 0700 folder, so no one else
    /// can open it while it is written; it is then made 0600, kept out of Time Machine, and renamed into place, so a
    /// copy that is there is whole. A failure is logged and the upgrade goes on: refusing to open would lose more.
    static func writeIfNeeded(_ pool: DatabasePool, storeURL: URL) {
        let backup = url(next: storeURL)
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        let staging = staging(next: storeURL)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            guard try isNeeded(pool) else { return }
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var part = staging.appendingPathComponent(fileName)
            try pool.writeWithoutTransaction { db in try db.execute(sql: "VACUUM INTO ?", arguments: [part.path]) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: part.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try part.setResourceValues(values)
            try FileManager.default.moveItem(at: part, to: backup)
        } catch {
            log.error("pre-v26 backup failed: \((error as? DatabaseError)?.resultCode.rawValue ?? -1, privacy: .public)")
        }
    }

    private static func staging(next storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(".\(fileName).part", isDirectory: true)
    }

    private static func isNeeded(_ pool: DatabasePool) throws -> Bool {
        try pool.read { db in
            guard try db.tableExists("grdb_migrations") else { return false }
            let applied = Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
            return !applied.isEmpty && !applied.isSuperset(of: identifiers)
        }
    }

    /// After the migrations ran: deletes the copy when the store has every migration and still holds every note the
    /// copy holds. A copy that does not check out is kept for a restore.
    static func discardIfVerified(_ pool: DatabasePool, migrator: DatabaseMigrator, storeURL: URL) {
        let backup = url(next: storeURL)
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        do {
            let (complete, notes) = try pool.read { db in
                (try migrator.hasCompletedMigrations(db), try Int.fetchOne(db, sql: "SELECT count(*) FROM note") ?? -1)
            }
            var config = Configuration()
            config.readonly = true
            let copied = try DatabaseQueue(path: backup.path, configuration: config).read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM note") ?? -2
            }
            if complete, notes == copied {
                remove(next: storeURL)
            } else {
                log.error("pre-v26 backup kept: the upgraded store did not check out")
            }
        } catch {
            log.error("pre-v26 backup check failed: \((error as? DatabaseError)?.resultCode.rawValue ?? -1, privacy: .public)")
        }
    }

    static func remove(next storeURL: URL) {
        let backup = url(next: storeURL)
        for file in [backup, staging(next: storeURL)] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func removeIfExpired(storeURL: URL, now: Date = Date()) {
        let backup = url(next: storeURL)
        guard let created = (try? FileManager.default.attributesOfItem(atPath: backup.path))?[.creationDate] as? Date,
              now.timeIntervalSince(created) > keepFor else { return }
        remove(next: storeURL)
    }

    /// Puts the copy back in place of the store after a failed upgrade. No connection to the store may be open.
    /// Returns false when there is no copy.
    @discardableResult
    static func restore(storeURL: URL) throws -> Bool {
        let backup = url(next: storeURL)
        guard FileManager.default.fileExists(atPath: backup.path) else { return false }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
        }
        try FileManager.default.moveItem(at: backup, to: storeURL)
        return true
    }

    private static let log = Logger(subsystem: "app.hushy", category: "store-migration")
}
