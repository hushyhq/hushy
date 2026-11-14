import Foundation

/// Filesystem locations shared by the app and the MCP helper.
///
/// The product was renamed Murmur → Hushy (see `.claude/DECISIONS.md`); the on-disk folder
/// name follows the product name, not the Swift module name (`MurmurCore` is unchanged, see
/// the same decision). `AppDataMigration` moves an existing `Murmur` folder into `Hushy` once,
/// at first launch, before anything below is read.
public enum AppPaths {
    /// The current, user-facing product name. Determines the Application Support subfolder.
    public static let appName = "Hushy"

    /// The previous product name, kept only so `AppDataMigration` can find old user data.
    public static let previousAppName = "Murmur"

    /// `~/Library/Application Support/Hushy`, overridable with `HUSHY_HOME` (or the legacy
    /// `MURMUR_HOME`, still honored) for tests and for pointing at a specific data directory.
    public static var supportDirectory: URL {
        if let override = environmentOverride {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    /// The pre-rename Application Support folder (`~/Library/Application Support/Murmur`),
    /// used only by the one-time migration. Respects the same environment overrides so tests
    /// can point both old and new locations at fixtures.
    public static var previousSupportDirectory: URL {
        if let override = environmentOverride {
            return URL(fileURLWithPath: override, isDirectory: true)
                .deletingLastPathComponent()
                .appendingPathComponent(previousAppName, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(previousAppName, isDirectory: true)
    }

    /// `~/Library/Caches/Hushy`: scratch space that holds nothing the person wrote and may be
    /// emptied at any time. Under the `HUSHY_HOME` / `MURMUR_HOME` override it is a folder beside
    /// the override, never inside it, so tests and disposable runs leave the real caches alone and
    /// a process working here has none of the app's data above it.
    public static var cachesDirectory: URL {
        if let override = environmentOverride {
            let home = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            return home.deletingLastPathComponent()
                .appendingPathComponent("\(home.lastPathComponent)-Caches", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    /// `HUSHY_HOME` takes priority; `MURMUR_HOME` still works so existing scripts/tests
    /// (murmur-eval, run-evals.sh) that set it keep pointing at the same override directory.
    private static var environmentOverride: String? {
        let env = ProcessInfo.processInfo.environment
        if let value = env["HUSHY_HOME"], !value.isEmpty { return value }
        if let value = env["MURMUR_HOME"], !value.isEmpty { return value }
        return nil
    }

    public static var database: URL { supportDirectory.appendingPathComponent("murmur.sqlite") }
    public static var audioDirectory: URL { supportDirectory.appendingPathComponent("Audio", isDirectory: true) }
    public static var notesAudioDirectory: URL { supportDirectory.appendingPathComponent("Notes", isDirectory: true) }
    public static var memoryDirectory: URL { supportDirectory.appendingPathComponent("Memory", isDirectory: true) }

    /// Default Markdown export folder: `~/Documents/Hushy`.
    public static var defaultExportDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent(appName, isDirectory: true)
    }
}
