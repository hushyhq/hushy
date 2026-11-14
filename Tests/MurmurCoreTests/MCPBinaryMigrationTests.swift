import Foundation
import Testing
@testable import MurmurCore

@Suite("MCPBinaryMigration")
struct MCPBinaryMigrationTests {
    // MARK: referencesLegacyBinary / referencesCurrentBinary

    @Test("detects the legacy binary name in a full bundle path")
    func detectsLegacyBinaryInPath() {
        let path = "/Applications/Hushy.app/Contents/MacOS/murmur-mcp"
        #expect(MCPBinaryMigration.referencesLegacyBinary(path))
        #expect(!MCPBinaryMigration.referencesCurrentBinary(path))
    }

    @Test("detects the current binary name in a full bundle path")
    func detectsCurrentBinaryInPath() {
        let path = "/Applications/Hushy.app/Contents/MacOS/hushy-mcp"
        #expect(MCPBinaryMigration.referencesCurrentBinary(path))
        #expect(!MCPBinaryMigration.referencesLegacyBinary(path))
    }

    @Test("detects the legacy binary name inside a Codex TOML command line")
    func detectsLegacyBinaryInCodexConfig() {
        let toml = """
            [mcp_servers.hushy]
            command = "/Applications/Hushy.app/Contents/MacOS/murmur-mcp"
            """
        #expect(MCPBinaryMigration.referencesLegacyBinary(toml))
    }

    @Test("detects the legacy binary name inside a claude mcp add command string")
    func detectsLegacyBinaryInClaudeCodeCommand() {
        let text = #"claude mcp add --scope user murmur -- "/path/to/Hushy.app/Contents/MacOS/murmur-mcp""#
        #expect(MCPBinaryMigration.referencesLegacyBinary(text))
    }

    @Test("does not false-positive on a filename that merely starts with the legacy token")
    func doesNotMatchLongerFilename() {
        let path = "/Applications/Hushy.app/Contents/MacOS/murmur-mcp-helper-extra"
        #expect(!MCPBinaryMigration.referencesLegacyBinary(path))
    }

    @Test("does not false-positive on a filename that merely ends with the legacy token")
    func doesNotMatchPrefixedFilename() {
        let path = "/Applications/Hushy.app/Contents/MacOS/old-murmur-mcp"
        #expect(!MCPBinaryMigration.referencesLegacyBinary(path))
    }

    @Test("returns false for text that references neither binary")
    func noReferenceAtAll() {
        let text = "[mcp_servers.something_else]\ncommand = \"/usr/bin/true\""
        #expect(!MCPBinaryMigration.referencesLegacyBinary(text))
        #expect(!MCPBinaryMigration.referencesCurrentBinary(text))
    }

    // MARK: rewritingLegacyBinaryReferences

    @Test("rewrites a bare legacy path to the current binary name")
    func rewritesBarePath() {
        let path = "/Applications/Hushy.app/Contents/MacOS/murmur-mcp"
        let rewritten = MCPBinaryMigration.rewritingLegacyBinaryReferences(in: path)
        #expect(rewritten == "/Applications/Hushy.app/Contents/MacOS/hushy-mcp")
    }

    @Test("rewrites the legacy binary name inside a Codex TOML block, preserving everything else")
    func rewritesCodexConfig() {
        let toml = """
            [mcp_servers.hushy]
            command = "/Applications/Hushy.app/Contents/MacOS/murmur-mcp"
            """
        let rewritten = MCPBinaryMigration.rewritingLegacyBinaryReferences(in: toml)
        #expect(rewritten.contains("hushy-mcp"))
        #expect(!MCPBinaryMigration.referencesLegacyBinary(rewritten))
        #expect(rewritten.contains("[mcp_servers.hushy]"))
    }

    @Test("is a no-op when the legacy binary name is not present")
    func noopWhenAlreadyCurrent() {
        let toml = """
            [mcp_servers.hushy]
            command = "/Applications/Hushy.app/Contents/MacOS/hushy-mcp"
            """
        #expect(MCPBinaryMigration.rewritingLegacyBinaryReferences(in: toml) == toml)
    }

    @Test("does not rewrite a filename that only shares the legacy token as a substring")
    func doesNotRewriteLongerFilename() {
        let path = "/Applications/Hushy.app/Contents/MacOS/murmur-mcp-helper-extra"
        #expect(MCPBinaryMigration.rewritingLegacyBinaryReferences(in: path) == path)
    }

    @Test("rewrites every occurrence when the legacy name appears more than once")
    func rewritesMultipleOccurrences() {
        let text = "murmur-mcp and again murmur-mcp"
        let rewritten = MCPBinaryMigration.rewritingLegacyBinaryReferences(in: text)
        #expect(rewritten == "hushy-mcp and again hushy-mcp")
    }
}
