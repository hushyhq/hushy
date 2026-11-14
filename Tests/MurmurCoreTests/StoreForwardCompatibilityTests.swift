import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// A test build may go back to an older build on the same database. The older build does not know migration
/// "v21-dictation-app-category": it must open the database, ignore the column, and the rows it saves afterwards
/// (no category) must still retry with the bundle-ID fallback.
@Suite("Database stays usable by an older build", .timeLimit(.minutes(1)))
struct StoreForwardCompatibilityTests {
    @Test("a migration identifier the migrator does not know is ignored, not refused")
    func unknownMigrationIsIgnored() throws {
        let queue = try DatabaseQueue()
        try Store.migrator.migrate(queue)
        // What an older build sees: an applied migration it has never heard of.
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-a-newer-build')") }
        try Store.migrator.migrate(queue)
        let applied = try queue.read { try Store.migrator.appliedIdentifiers($0) }
        #expect(applied.contains("v99-from-a-newer-build"))
    }

    @Test("the new column is nullable and additive: a row written without it reads back with no category")
    func olderRowHasNoCategory() throws {
        let queue = try DatabaseQueue()
        try Store.migrator.migrate(queue)
        let columns = try queue.read { try $0.columns(in: "dictation") }
        let category = columns.first { $0.name == "appCategory" }
        #expect(category != nil)
        #expect(category?.isNotNull == false)
        // An older build's INSERT names only the columns it knows.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO dictation (createdAt, rawText, text, appBundleID, appName, durationSeconds, wordCount, latencyMs, fixes, status)
                VALUES (?, 'raw', 'text', 'com.google.Chrome', 'Chrome', 2.0, 1, 100, 0, 'notInserted')
                """, arguments: [Date()])
        }
        let row = try queue.read { try Dictation.fetchOne($0) }
        #expect(row?.appCategory == nil)
        // No saved category: the retry falls back to the saved app's bundle ID, as before this migration.
        let retried = PipelineSettings.forRetry(
            cleanup: CleanupOptions(level: .polished), tone: .standard,
            mode: Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(.polished), bundleID: row?.appBundleID,
            category: row?.appCategory.flatMap(AppCategory.init(rawValue:)))
        #expect(retried.cleanupOptions.level == .polished)
    }
}
