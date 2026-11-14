import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// The parts of the frozen meetings migrations that keep a person's data safe: a backfill that never throws, and
/// the copy of the store taken before v26 first runs.
@Suite("Meetings migration safety", .timeLimit(.minutes(1)))
struct MeetingsMigrationSafetyTests {
    @Test("the backfill counts what it cannot read and never throws")
    func backfillReport() throws {
        let queue = try DatabaseQueue()
        try Store.migrator.migrate(queue, upTo: "v28-turn")
        try queue.write { (db: Database) throws in
            let now = "2026-11-01 10:00:00.000"
            for (title, items) in [("ok", "[\"one\",\"\"]"), ("bad", "nope")] {
                try db.execute(sql: """
                    INSERT INTO note (title, createdAt, updatedAt, durationSeconds, transcript, summary, actionItems, status, source)
                    VALUES (?, ?, ?, 0, '', '- Decided: go', ?, 'ready', 'recording')
                    """, arguments: [title, now, now, items])
            }
        }
        try Store.migrator.migrate(queue)
        let report = try queue.write { db -> LegacyFactBackfill.Report in
            try db.execute(sql: "DELETE FROM meeting_fact")
            return try LegacyFactBackfill.run(db)
        }
        #expect(report == LegacyFactBackfill.Report(facts: 3, skippedNotes: 1, skippedItems: 1))
    }

    private static func home() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func store3005(in home: URL) throws -> URL {
        let url = home.appendingPathComponent("murmur.sqlite")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/store-build3005.sqlite"),
            to: url)
        return url
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test("the copy is owner-only, kept out of Time Machine, and holds the store as it was before v26")
    func copyIsPrivateAndWhole() throws {
        let url = try Self.store3005(in: try Self.home())
        try PreMeetingsBackup.writeIfNeeded(DatabasePool(path: url.path), storeURL: url)
        let copy = PreMeetingsBackup.url(next: url)
        #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int == 0o600)
        #expect(try copy.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let (identifier, notes) = try DatabaseQueue(path: copy.path).read { db in
            (try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM note"))
        }
        #expect(identifier == "v25-learned-evidence" && notes == 13)
    }

    @Test("after a successful upgrade, and for a fresh store, no copy is left")
    func successLeavesNoCopy() throws {
        let home = try Self.home()
        let upgraded = try Self.store3005(in: home)
        _ = try Store(url: upgraded)
        #expect(!Self.exists(PreMeetingsBackup.url(next: upgraded)))
        let fresh = home.appendingPathComponent("fresh/murmur.sqlite")
        _ = try Store(url: fresh)
        #expect(!Self.exists(PreMeetingsBackup.url(next: fresh)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).allSatisfy { !$0.hasPrefix("hushy-pre-v26") })
    }

    /// v28 cannot create `turn` when a table of that name is already there, so the upgrade stops after v27.
    private static func failingUpgrade(in home: URL) throws -> URL {
        let url = try store3005(in: home)
        try DatabaseQueue(path: url.path).write { try $0.execute(sql: "CREATE TABLE turn (blocker TEXT)") }
        return url
    }

    @Test("a failed upgrade keeps the copy, and restoring it brings back the store from before v26")
    func failedUpgradeRestores() throws {
        let url = try Self.failingUpgrade(in: try Self.home())
        #expect(throws: (any Error).self) { try Store(url: url) }
        #expect(Self.exists(PreMeetingsBackup.url(next: url)))
        #expect(try DatabaseQueue(path: url.path).read { try $0.tableExists("capture_segment") })
        #expect(try PreMeetingsBackup.restore(storeURL: url))
        let (identifier, notes, journal) = try DatabaseQueue(path: url.path).read { db in
            (try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM note"), try db.tableExists("capture_segment"))
        }
        #expect(identifier == "v25-learned-evidence" && notes == 13 && !journal)
        #expect(!Self.exists(PreMeetingsBackup.url(next: url)))
    }

    @Test("with data encryption on, no copy is made")
    func noCopyWhenEncrypted() throws {
        let url = try Self.failingUpgrade(in: try Self.home())
        #expect(throws: (any Error).self) { try Store(url: url, preMigrationBackup: false) }
        #expect(!Self.exists(PreMeetingsBackup.url(next: url)))
    }

    @Test("every erase the person asks for deletes a copy left by a failed upgrade", arguments: [
        "deleteNote", "deleteDictation", "deleteAllDictations", "eraseMeetings", "applyRetention", "deleteAllLearnedItems",
        "deleteAllAssistantChats", "deleteAllVoices", "truncateWAL",
    ])
    func eraseDeletesCopy(_ erase: String) throws {
        let home = try Self.home()
        let url = try Self.store3005(in: home)
        let store = try Store(url: url)
        let copy = PreMeetingsBackup.url(next: url)
        try Data("left by a failed upgrade".utf8).write(to: copy)
        switch erase {
        case "deleteNote": try store.deleteNote(id: 1)
        case "deleteDictation": try store.deleteDictation(id: 1)
        case "deleteAllDictations": _ = try store.deleteAllDictations()
        case "eraseMeetings": try store.eraseMeetings(store.meetingErasePlan())
        case "applyRetention": _ = try store.applyRetention(audioDays: 1, textDays: 1)
        case "deleteAllLearnedItems": try store.deleteAllLearnedItems()
        case "deleteAllAssistantChats": _ = try store.deleteAllAssistantChats()
        case "deleteAllVoices": try store.deleteAllVoices()
        case "truncateWAL": try store.truncateWAL()
        default: Issue.record("unknown erase \(erase)")
        }
        #expect(!Self.exists(copy), "\(erase) left the copy")
    }

    @Test("a copy left by a failed upgrade goes after 30 days")
    func copyExpires() throws {
        let url = try Self.home().appendingPathComponent("murmur.sqlite")
        let copy = PreMeetingsBackup.url(next: url)
        try Data("old".utf8).write(to: copy)
        PreMeetingsBackup.removeIfExpired(storeURL: url, now: Date().addingTimeInterval(29 * 24 * 3600))
        #expect(Self.exists(copy))
        PreMeetingsBackup.removeIfExpired(storeURL: url, now: Date().addingTimeInterval(31 * 24 * 3600))
        #expect(!Self.exists(copy))
    }
}
