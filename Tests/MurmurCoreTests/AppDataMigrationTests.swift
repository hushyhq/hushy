import Foundation
import Testing
@testable import MurmurCore

@Suite("AppDataMigration")
struct AppDataMigrationTests {
    // MARK: shouldMigrateSupportDirectory (pure decision)

    @Test("migrates only when the old folder exists and the new one does not")
    func decidesFolderMigration() {
        #expect(AppDataMigration.shouldMigrateSupportDirectory(oldExists: true, newExists: false))
        #expect(!AppDataMigration.shouldMigrateSupportDirectory(oldExists: false, newExists: false))
        #expect(!AppDataMigration.shouldMigrateSupportDirectory(oldExists: false, newExists: true))
        #expect(!AppDataMigration.shouldMigrateSupportDirectory(oldExists: true, newExists: true))
    }

    // MARK: migrateSupportDirectoryIfNeeded (real filesystem, in a disposable temp dir)

    @Test("moves the old folder to the new location when only the old one exists")
    func movesFolderWhenOldExistsAlone() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Murmur", isDirectory: true)
        let new = root.appendingPathComponent("Hushy", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: old.appendingPathComponent("murmur.sqlite"))
        let flags = FakeStore([:])

        let migrated = AppDataMigration.migrateSupportDirectoryIfNeeded(oldDirectory: old, newDirectory: new, newStore: flags)

        #expect(migrated)
        #expect(flags.values[AppDataMigration.supportDirectoryMigrationFlagKey] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("murmur.sqlite").path))
    }

    @Test("never overwrites an existing new folder, and leaves the old one in place")
    func doesNotOverwriteExistingNewFolder() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Murmur", isDirectory: true)
        let new = root.appendingPathComponent("Hushy", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: new.appendingPathComponent("marker"))
        let flags = FakeStore([:])

        let migrated = AppDataMigration.migrateSupportDirectoryIfNeeded(oldDirectory: old, newDirectory: new, newStore: flags)

        #expect(!migrated)
        #expect(flags.values[AppDataMigration.supportDirectoryMigrationFlagKey] == nil)
        #expect(FileManager.default.fileExists(atPath: old.path))
        let keptContents = try Data(contentsOf: new.appendingPathComponent("marker"))
        #expect(String(data: keptContents, encoding: .utf8) == "new")
    }

    @Test("is a no-op when neither folder exists")
    func noopWhenNeitherExists() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Murmur", isDirectory: true)
        let new = root.appendingPathComponent("Hushy", isDirectory: true)
        let flags = FakeStore([:])

        let migrated = AppDataMigration.migrateSupportDirectoryIfNeeded(oldDirectory: old, newDirectory: new, newStore: flags)

        #expect(!migrated)
        #expect(flags.values[AppDataMigration.supportDirectoryMigrationFlagKey] == nil)
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test("an empty old folder moves but does not claim data came with the user")
    func emptyFolderDoesNotShowMigration() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Murmur", isDirectory: true)
        let new = root.appendingPathComponent("Hushy", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let flags = FakeStore([:])

        #expect(AppDataMigration.migrateSupportDirectoryIfNeeded(oldDirectory: old, newDirectory: new, newStore: flags))
        #expect(flags.values[AppDataMigration.supportDirectoryMigrationFlagKey] == nil)
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hushy-migration-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: UserDefaults copy (pure decision + pure diff + fake store)

    @Test("copies defaults only the first time")
    func decidesDefaultsMigration() {
        #expect(AppDataMigration.shouldMigrateDefaults(alreadyMigrated: false))
        #expect(!AppDataMigration.shouldMigrateDefaults(alreadyMigrated: true))
    }

    @Test("keysToCopy carries over old keys the new store doesn't already have")
    func keysToCopyFiltersExistingAndFlag() {
        let old: [String: Any] = [
            "triggerKey": "fn",
            "cleanupLevel": "clean",
            AppDataMigration.defaultsMigrationFlagKey: true,
        ]
        let new: [String: Any] = ["cleanupLevel": "polished"]

        let copied = AppDataMigration.keysToCopy(oldValues: old, newValues: new)

        #expect(copied["triggerKey"] as? String == "fn")
        #expect(copied["cleanupLevel"] == nil, "must not overwrite a value already set post-rename")
        #expect(copied[AppDataMigration.defaultsMigrationFlagKey] == nil, "must not copy the flag itself")
    }

    @Test("migrateDefaultsIfNeeded copies old values into the new store and sets the flag")
    func migratesDefaultsIntoFakeStore() {
        let old = FakeStore(["triggerKey": "fn", "voiceCommands": true])
        let new = FakeStore([:])

        AppDataMigration.migrateDefaultsIfNeeded(oldDomain: "app.murmur.Murmur", newStore: new, oldStoreOverride: old)

        #expect(new.values["triggerKey"] as? String == "fn")
        #expect(new.values["voiceCommands"] as? Bool == true)
        #expect(new.values[AppDataMigration.defaultsMigrationFlagKey] as? Bool == true)
    }

    @Test("migrateDefaultsIfNeeded is a no-op once already migrated")
    func skipsSecondMigration() {
        let old = FakeStore(["triggerKey": "fn"])
        let new = FakeStore([AppDataMigration.defaultsMigrationFlagKey: true, "triggerKey": "rightOption"])

        AppDataMigration.migrateDefaultsIfNeeded(oldDomain: "app.murmur.Murmur", newStore: new, oldStoreOverride: old)

        #expect(new.values["triggerKey"] as? String == "rightOption", "must not clobber a value the user set after migrating")
    }

    @Test("migrateDefaultsIfNeeded tolerates an empty or missing old domain")
    func toleratesEmptyOldDomain() {
        let old = FakeStore([:])
        let new = FakeStore([:])

        AppDataMigration.migrateDefaultsIfNeeded(oldDomain: "app.murmur.Murmur", newStore: new, oldStoreOverride: old)

        #expect(new.values[AppDataMigration.defaultsMigrationFlagKey] as? Bool == true)
        #expect(new.values.count == 1)
    }
}

/// A minimal in-memory `AppDataMigration.KeyValueStore` fake for testing without touching
/// real `UserDefaults` (which is process-global and would leak between test runs).
private final class FakeStore: AppDataMigration.KeyValueStore {
    private(set) var values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }

    func dictionaryRepresentation() -> [String: Any] { values }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
