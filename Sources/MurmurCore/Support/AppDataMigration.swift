import Foundation

/// One-time data migration for the Murmur → Hushy rename (see `.claude/DECISIONS.md`).
///
/// Two independent things move the first time the renamed app launches:
/// 1. The Application Support folder: `~/Library/Application Support/Murmur` → `.../Hushy`.
/// 2. UserDefaults: keys under the old bundle identifier's domain (`app.murmur.Murmur`) are
///    copied into the new domain (`app.hushy.Hushy`, i.e. `.standard` under the new bundle id).
///
/// Both halves are split into pure decision/copy functions plus a thin `run` that does the
/// actual I/O, so the logic can be unit-tested with fake filesystems and defaults stores.
public enum AppDataMigration {
    /// Recorded only after the old Application Support folder was actually moved.
    public static let supportDirectoryMigrationFlagKey = "hushy.movedSupportFromMurmur"
    // MARK: Application Support folder

    /// Whether the on-disk folder migration should run, given what currently exists.
    /// Pure function of existence checks — no I/O itself.
    public static func shouldMigrateSupportDirectory(oldExists: Bool, newExists: Bool) -> Bool {
        oldExists && !newExists
    }

    /// Moves `~/Library/Application Support/Murmur` to `.../Hushy` if the old folder exists
    /// and the new one does not yet. Safe to call on every launch: it is a no-op once migrated,
    /// and never overwrites an existing Hushy folder (so a user who already has both, e.g. from
    /// running an old and new build side by side, keeps the new one untouched).
    @discardableResult
    public static func migrateSupportDirectoryIfNeeded(
        fileManager: FileManager = .default,
        oldDirectory: URL = AppPaths.previousSupportDirectory,
        newDirectory: URL = AppPaths.supportDirectory,
        newStore: KeyValueStore = UserDefaults.standard
    ) -> Bool {
        let oldExists = fileManager.fileExists(atPath: oldDirectory.path)
        let newExists = fileManager.fileExists(atPath: newDirectory.path)
        guard shouldMigrateSupportDirectory(oldExists: oldExists, newExists: newExists) else { return false }
        do {
            let hadData = !((try? fileManager.contentsOfDirectory(atPath: oldDirectory.path)) ?? []).isEmpty
            try fileManager.createDirectory(
                at: newDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: oldDirectory, to: newDirectory)
            if hadData { newStore.set(true, forKey: supportDirectoryMigrationFlagKey) }
            return true
        } catch {
            return false
        }
    }

    // MARK: UserDefaults

    /// A minimal key-value store, so this can be unit-tested against a fake instead of the
    /// real `UserDefaults`.
    public protocol KeyValueStore {
        func dictionaryRepresentation() -> [String: Any]
        func object(forKey key: String) -> Any?
        func set(_ value: Any?, forKey key: String)
    }

    /// Flag key recorded in the *new* domain once the copy has run, so it never repeats
    /// (including if the old domain is later deleted or the user never had one).
    public static let defaultsMigrationFlagKey = "hushy.migratedDefaultsFromMurmur"

    /// Whether the UserDefaults copy should run. Pure: true only the first time, i.e. when the
    /// new domain hasn't already recorded that migration happened.
    public static func shouldMigrateDefaults(alreadyMigrated: Bool) -> Bool {
        !alreadyMigrated
    }

    /// Returns the key/value pairs that should be copied from the old domain into the new one:
    /// everything in `oldValues` except keys the new store already has (never overwrite a
    /// value the user has already set post-rename) and the migration flag itself.
    public static func keysToCopy(oldValues: [String: Any], newValues: [String: Any]) -> [String: Any] {
        oldValues.filter { key, _ in
            key != defaultsMigrationFlagKey && key != supportDirectoryMigrationFlagKey && newValues[key] == nil
        }
    }

    /// Copies every UserDefaults key from the old bundle identifier's domain into `newStore`
    /// (normally `UserDefaults.standard` under the new bundle id) exactly once. Idempotent and
    /// safe to call on every launch.
    ///
    /// `oldStoreOverride` lets tests substitute a fake for the real old-domain `UserDefaults`
    /// (which can't be faked directly: `UserDefaults(suiteName:)` always reads/writes the real
    /// per-user store). Production code leaves it nil and reads the real old domain.
    public static func migrateDefaultsIfNeeded(
        oldDomain: String = "app.murmur.Murmur",
        newStore: KeyValueStore = UserDefaults.standard,
        oldStoreOverride: KeyValueStore? = nil
    ) {
        let alreadyMigrated = (newStore.object(forKey: defaultsMigrationFlagKey) as? Bool) ?? false
        guard shouldMigrateDefaults(alreadyMigrated: alreadyMigrated) else { return }
        defer { newStore.set(true, forKey: defaultsMigrationFlagKey) }

        guard let oldStore = oldStoreOverride ?? UserDefaults(suiteName: oldDomain) else { return }
        let oldValues = oldStore.dictionaryRepresentation()
        guard !oldValues.isEmpty else { return }
        let newValues = newStore.dictionaryRepresentation()
        for (key, value) in keysToCopy(oldValues: oldValues, newValues: newValues) {
            newStore.set(value, forKey: key)
        }
    }

    /// Runs both migrations. Call once, early in app launch, before `AppSettings` or `Store`
    /// read anything.
    public static func migrateIfNeeded() {
        migrateSupportDirectoryIfNeeded()
        migrateDefaultsIfNeeded()
    }
}

extension UserDefaults: AppDataMigration.KeyValueStore {}
