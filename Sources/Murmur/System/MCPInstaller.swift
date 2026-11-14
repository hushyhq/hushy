import Foundation
import MurmurCore

/// Connects Hushy's read-only MCP server to AI clients the user already pays for.
///
/// The MCP entry name changed from "murmur" to "hushy" when the product was renamed (see
/// `.claude/DECISIONS.md`). The Swift target is still called `murmur-mcp`, but the binary
/// `scripts/build-app.sh` ships inside the app bundle is now named `hushy-mcp`: that on-disk
/// filename is what AI clients launch as a subprocess and what macOS attributes TCC/permission
/// prompts to, so unlike the internal target name it is genuinely user-visible. Clients that
/// already have an old "murmur" entry, an old `murmur-mcp` binary path, or both, are detected
/// via `hasLegacyEntry` and offered an update (rewritten in place to "hushy" / `hushy-mcp`)
/// rather than silently left stale or duplicated. String-level detection/rewriting lives in
/// `MCPBinaryMigration` (MurmurCore) so it can be unit-tested.
enum MCPInstaller {
    enum Client: String, CaseIterable, Identifiable {
        case claudeDesktop, claudeCode, codex, cursor

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeDesktop: "Claude Desktop"
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .cursor: "Cursor"
            }
        }

        /// Config file we can update in place (with the user's confirmation), if any.
        var configURL: URL? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeDesktop:
                return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
            case .cursor:
                return home.appendingPathComponent(".cursor/mcp.json")
            case .codex:
                return home.appendingPathComponent(".codex/config.toml")
            case .claudeCode:
                return nil
            }
        }
    }

    /// Detects whether the client itself is present on this Mac, independent of whether
    /// Murmur has been added to its config yet. Best-effort: checks the usual app/CLI
    /// locations, not every possible custom install.
    static func isClientInstalled(_ client: Client) -> Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        switch client {
        case .claudeDesktop:
            return fileManager.fileExists(atPath: "/Applications/Claude.app")
                || fileManager.fileExists(atPath: home.appendingPathComponent("Applications/Claude.app").path)
        case .cursor:
            return fileManager.fileExists(atPath: "/Applications/Cursor.app")
                || fileManager.fileExists(atPath: home.appendingPathComponent("Applications/Cursor.app").path)
                || fileManager.fileExists(atPath: home.appendingPathComponent(".cursor").path)
        case .codex:
            return fileManager.fileExists(atPath: home.appendingPathComponent(".codex").path)
                || which("codex") != nil
        case .claudeCode:
            return which("claude") != nil
        }
    }

    /// Looks a command up on PATH the way a shell would, without spawning a shell. Shared with
    /// the in-app assistant (see `ExecutableLocator`), which also searches the usual install
    /// directories a Dock-launched app's minimal PATH misses.
    static func which(_ command: String) -> String? {
        ExecutableLocator.locate(command)
    }

    /// The helper binary ships next to the app executable (Contents/MacOS/hushy-mcp).
    static var serverPath: String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent()
            .appendingPathComponent(MCPBinaryMigration.currentBinaryName).path
    }

    /// The pre-rename binary path (Contents/MacOS/murmur-mcp), checked as a fallback so a build
    /// installed before the binary rename still resolves to something runnable.
    private static var legacyServerPath: String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent()
            .appendingPathComponent(MCPBinaryMigration.legacyBinaryName).path
    }

    /// The runnable helper binary — current name first, pre-rename name as a fallback — or nil.
    static var resolvedServerPath: String? {
        [serverPath, legacyServerPath].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var serverExists: Bool {
        FileManager.default.isExecutableFile(atPath: serverPath)
            || FileManager.default.isExecutableFile(atPath: legacyServerPath)
    }

    /// Entry name used in client configs. Was "murmur" before the rename.
    static let entryName = "hushy"
    static let legacyEntryName = "murmur"

    /// What the user would paste or run manually.
    static func snippet(for client: Client) -> String {
        let path = serverPath
        switch client {
        case .claudeCode:
            return "claude mcp add --scope user \(entryName) -- \"\(path)\""
        case .codex:
            return """
                [mcp_servers.\(entryName)]
                command = "\(path)"
                """
        case .claudeDesktop, .cursor:
            return """
                {
                  "mcpServers": {
                    "\(entryName)": { "command": "\(path)" }
                  }
                }
                """
        }
    }

    enum InstallError: LocalizedError {
        case unsupported, invalidConfig(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: "Run the command shown instead."
            case .invalidConfig(let file): "\(file) isn't valid JSON, so it was left untouched. Add the snippet by hand."
            }
        }
    }

    /// Whether the client's config has our entry under its *current* name ("hushy") pointing
    /// at the *current* binary (`hushy-mcp`). A leftover pre-rename "murmur" entry name or a
    /// stale `murmur-mcp` binary path (see `hasLegacyEntry`) does not count as installed, so
    /// the UI offers to update it rather than reporting "Connected".
    static func isInstalled(_ client: Client) -> Bool {
        guard let url = client.configURL, let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        switch client {
        case .codex:
            return contents.contains("[mcp_servers.\(entryName)]") && !MCPBinaryMigration.referencesLegacyBinary(contents)
        case .claudeDesktop, .cursor:
            guard let data = contents.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any],
                  let entry = servers[entryName] as? [String: Any],
                  let command = entry["command"] as? String
            else { return false }
            return !MCPBinaryMigration.referencesLegacyBinary(command)
        case .claudeCode:
            return MCPBinaryMigration.referencesCurrentBinary(contents)
        }
    }

    /// Whether the client's config still has the pre-rename "murmur" entry name, still points
    /// its command at the pre-rename `murmur-mcp` binary, or both. Re-reads the file from disk
    /// each time, like `isInstalled`.
    static func hasLegacyEntry(_ client: Client) -> Bool {
        guard let url = client.configURL, let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        switch client {
        case .codex:
            let hasLegacyName = contents.contains("[mcp_servers.\(legacyEntryName)]")
            let hasLegacyBinary = contents.contains("[mcp_servers.\(entryName)]") && MCPBinaryMigration.referencesLegacyBinary(contents)
            return hasLegacyName || hasLegacyBinary
        case .claudeDesktop, .cursor:
            guard let data = contents.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any]
            else { return false }
            if servers[legacyEntryName] != nil, servers[entryName] == nil { return true }
            if let entry = servers[entryName] as? [String: Any], let command = entry["command"] as? String {
                return MCPBinaryMigration.referencesLegacyBinary(command)
            }
            return false
        case .claudeCode:
            return MCPBinaryMigration.referencesLegacyBinary(contents) && !MCPBinaryMigration.referencesCurrentBinary(contents)
        }
    }

    /// Connection state for the Connections list: whether the client is on this Mac at all,
    /// and (re-reading its config from disk, never cached) whether Murmur is already in it.
    enum ConnectionStatus: Equatable {
        case notInstalled
        case notConnected
        case connected

        var title: String {
            switch self {
            case .notInstalled: "Not installed"
            case .notConnected: "Not connected"
            case .connected: "Connected"
            }
        }
    }

    /// Claude Code has no config file to inspect; running the client's own `claude mcp list`
    /// would be needed for a real check, so it stays "not connected" until the user says
    /// otherwise. Recorded locally after the copy-command flow so it doesn't nag every time.
    private static let claudeCodeConnectedKey = "murmur.mcp.claudeCodeConnected"

    static func status(for client: Client) -> ConnectionStatus {
        guard isClientInstalled(client) else { return .notInstalled }
        if client == .claudeCode {
            return UserDefaults.standard.bool(forKey: claudeCodeConnectedKey) ? .connected : .notConnected
        }
        return isInstalled(client) ? .connected : .notConnected
    }

    static func markClaudeCodeConnected() {
        UserDefaults.standard.set(true, forKey: claudeCodeConnectedKey)
    }

    /// Merges the Hushy entry into the client's config, preserving everything else. Also
    /// removes a pre-rename "murmur" entry if one is present, and rewrites any lingering
    /// `murmur-mcp` binary path to `hushy-mcp` (see `MCPBinaryMigration`), so the client ends
    /// up with a single, correctly named entry pointing at the current binary rather than a
    /// duplicate or a stale path. A backup of the previous file is written alongside it.
    static func install(_ client: Client) throws {
        guard let url = client.configURL else { throw InstallError.unsupported }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try? Data(contentsOf: url)
        // Keep the user's original config: never overwrite an earlier backup with a Hushy-edited one.
        let backup = url.appendingPathExtension("hushy-backup")
        if let existing, !fileManager.fileExists(atPath: backup.path) {
            try existing.write(to: backup, options: .atomic)
        }

        switch client {
        case .codex:
            var text = existing.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            text = text.replacingOccurrences(of: "[mcp_servers.\(legacyEntryName)]", with: "[mcp_servers.\(entryName)]")
            text = MCPBinaryMigration.rewritingLegacyBinaryReferences(in: text)
            guard !text.contains("[mcp_servers.\(entryName)]") else {
                try text.write(to: url, atomically: true, encoding: .utf8)
                return
            }
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += "\n" + snippet(for: .codex) + "\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
        case .claudeDesktop, .cursor:
            var root: [String: Any] = [:]
            if let existing, !existing.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                    throw InstallError.invalidConfig(url.lastPathComponent)
                }
                root = parsed
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers.removeValue(forKey: legacyEntryName)
            // Always (re)write the command to the current serverPath, so an existing "hushy"
            // entry left over from before the binary rename gets its path corrected too, not
            // just a brand-new entry.
            servers[entryName] = ["command": serverPath]
            root["mcpServers"] = servers
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
        case .claudeCode:
            throw InstallError.unsupported
        }
    }
}
