import Foundation

/// Pure string-rewriting logic for the MCP helper binary rename (`murmur-mcp` -> `hushy-mcp`
/// on disk inside the app bundle; see `.claude/DECISIONS.md`).
///
/// The Swift target is still named `murmur-mcp` (unchanged, like `Murmur`/`MurmurCore`), but
/// the binary `scripts/build-app.sh` copies into `Hushy.app/Contents/MacOS` is now named
/// `hushy-mcp`, because that filename is what AI clients (Claude Desktop, Codex, Cursor) launch
/// as a subprocess and what macOS attributes TCC/permission prompts to — unlike the JSON-RPC
/// `serverInfo.name` (`MCPServer.name`, already "hushy"), the on-disk binary name is genuinely
/// user-visible. An existing client config written before this change points its `command` at
/// a path ending in `.../Contents/MacOS/murmur-mcp`; these functions detect and rewrite that,
/// independent of (and in addition to) the "murmur" -> "hushy" *entry name* migration in
/// `MCPInstaller`.
///
/// Kept as pure functions over strings, not `MCPInstaller` itself, so they can be unit-tested
/// without touching real client config files or the real app bundle (`MCPInstaller` lives in
/// the `Murmur` executable target, which has no test target of its own).
public enum MCPBinaryMigration {
    /// Current and legacy on-disk filenames for the bundled MCP helper.
    public static let currentBinaryName = "hushy-mcp"
    public static let legacyBinaryName = "murmur-mcp"

    /// Whether a config's raw text (TOML, JSON, or a `claude mcp add` scan) still references
    /// the legacy binary filename anywhere — most simply, a `command` path ending in
    /// `.../murmur-mcp`. Recognizes the legacy name only when it is not immediately followed by
    /// more path/word characters, so it does not also match `murmur-mcp-something-else`.
    public static func referencesLegacyBinary(_ contents: String) -> Bool {
        containsWholeToken(contents, token: legacyBinaryName)
    }

    /// Whether a config's raw text already references the current binary filename.
    public static func referencesCurrentBinary(_ contents: String) -> Bool {
        containsWholeToken(contents, token: currentBinaryName)
    }

    private static func containsWholeToken(_ contents: String, token: String) -> Bool {
        var searchRange = contents.startIndex..<contents.endIndex
        while let range = contents.range(of: token, range: searchRange) {
            let precededOK = range.lowerBound == contents.startIndex
                || !isPathWordCharacter(contents[contents.index(before: range.lowerBound)])
            let followedOK = range.upperBound == contents.endIndex
                || !isPathWordCharacter(contents[range.upperBound])
            if precededOK, followedOK { return true }
            searchRange = range.upperBound..<contents.endIndex
        }
        return false
    }

    private static func isPathWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    /// Rewrites every whole-token occurrence of the legacy binary filename to the current one
    /// in a path or command string (e.g. a Codex `command = "..."` line, or a full command
    /// path). Leaves everything else untouched; a no-op if the legacy name doesn't appear.
    public static func rewritingLegacyBinaryReferences(in text: String) -> String {
        guard referencesLegacyBinary(text) else { return text }
        // Whole-token replacement: same boundary rule as `referencesLegacyBinary`, applied
        // left to right so overlapping/adjacent matches are each considered independently.
        var result = ""
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: legacyBinaryName, range: searchRange) {
            let precededOK = range.lowerBound == text.startIndex
                || !isPathWordCharacter(text[text.index(before: range.lowerBound)])
            let followedOK = range.upperBound == text.endIndex
                || !isPathWordCharacter(text[range.upperBound])
            result += text[searchRange.lowerBound..<range.lowerBound]
            if precededOK, followedOK {
                result += currentBinaryName
            } else {
                result += text[range]
            }
            searchRange = range.upperBound..<text.endIndex
        }
        result += text[searchRange]
        return result
    }
}
