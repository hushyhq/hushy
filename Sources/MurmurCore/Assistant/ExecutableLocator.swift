import Foundation

/// Finds a command-line tool the way a shell's `which` would — walking `PATH` — without ever
/// spawning a shell. Shared by `MCPInstaller` (connection status) and the in-app assistant
/// (which CLI to launch), so both agree on whether an agent is "on this Mac".
///
/// A Mac app launched from Finder or the Dock inherits launchd's minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), which misses where agent CLIs actually install
/// (`~/.local/bin` for Claude Code's native installer, Homebrew's prefixes, npm's global bin).
/// Those well-known directories are searched after `PATH`, in a fixed order, so the result is
/// the same whether Hushy was started from Terminal or from the Dock.
public enum ExecutableLocator {
    /// Directories searched after `PATH`. Relative entries are resolved against `home`.
    public static let fallbackDirectories = [
        ".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin",
        "/opt/homebrew/bin", "/usr/local/bin",
    ]

    /// The search order for `path` (the `PATH` value) and `home`: `PATH` entries first, then the
    /// fallbacks, duplicates and empty entries removed.
    public static func searchDirectories(path: String?, home: String) -> [String] {
        let fromPath = (path ?? "").split(separator: ":").map(String.init)
        let fallbacks = fallbackDirectories.map { $0.hasPrefix("/") ? $0 : "\(home)/\($0)" }
        var seen = Set<String>()
        return (fromPath + fallbacks).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The first executable file named `command` in the search order, or nil. `command` must be
    /// a bare name — anything containing a slash is rejected rather than resolved, so a caller
    /// can never be tricked into running a path.
    public static func locate(
        _ command: String,
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        guard !command.isEmpty, !command.contains("/") else { return nil }
        for directory in searchDirectories(path: path, home: home) {
            let candidate = "\(directory)/\(command)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}
