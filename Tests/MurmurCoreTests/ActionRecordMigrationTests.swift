import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// The Undo-failed column added to a database that already holds voice actions.
@Suite("Action records: migration of an existing database", .timeLimit(.minutes(1)))
struct ActionRecordMigrationTests {
    @Test("a database from before v20 keeps its action rows, which read as never having failed an Undo")
    func existingDatabaseMigrates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t114-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("hushy.sqlite")
        let pool = try DatabasePool(path: url.path)
        try Store.migrator.migrate(pool, upTo: "v18-action-item-details")
        try pool.write { db in
            #expect(try !db.columns(in: "actionRecord").map(\.name).contains("undoFailedAt"))
            try db.execute(sql: """
                INSERT INTO actionRecord (id, createdAt, kind, title, detail, sourceText, status, undoBackendID)
                VALUES (1, '2026-01-01 10:00:00', 'createReminder', 'Call Dana', 'No date set', 'remind me', 'completed', 'r-1'),
                       (2, '2026-01-01 11:00:00', 'runShortcut', 'Send Standup', 'Shortcut: Send Standup', 'run it', 'completed', NULL)
                """)
        }
        try pool.close()

        let store = try Store(url: url)
        let first = try #require(try store.actionRecord(id: 1))
        #expect(first.status == .completed)
        #expect(first.undoBackendID == "r-1")
        #expect(first.undoFailedAt == nil)
        #expect(try store.actionRecord(id: 2)?.undoFailedAt == nil)
        let columns = try store.writer.read { db in try db.columns(in: "actionRecord").map(\.name) }
        #expect(columns.contains("undoFailedAt"))

        // The new states save and read back beside the old rows.
        try store.markActionUndoFailed(id: 1)
        #expect(try store.actionRecord(id: 1)?.undoFailedAt != nil)
        let uncertain = try store.save(ActionRecord(kind: .runShortcut, title: "x", sourceText: "", status: .uncertain))
        #expect(try store.actionRecord(id: #require(uncertain.id))?.status == .uncertain)
    }

    @Test("reconciling gives back only the uses of undone records, and is safe to repeat")
    func reconcileRefunds() throws {
        let store = try Store()
        let kept = try store.save(ActionRecord(kind: .createReminder, title: "a", sourceText: "", status: .completed))
        let undone = try store.save(ActionRecord(kind: .createReminder, title: "b", sourceText: "", status: .undone))
        try store.recordVoiceActionUse(VoiceActionUse(kind: .action, actionRecordID: kept.id))
        try store.recordVoiceActionUse(VoiceActionUse(kind: .action, actionRecordID: undone.id))
        #expect(try store.voiceActionsThisMonth() == 2)
        #expect(try store.reconcileVoiceActionRefunds() == 1)
        #expect(try store.voiceActionsThisMonth() == 1)
        #expect(try store.reconcileVoiceActionRefunds() == 0)
    }
}
