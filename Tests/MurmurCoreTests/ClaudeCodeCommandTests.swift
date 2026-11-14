import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// The Claude Code command line: a plain argument vector (no shell), the message kept out of
/// it, and a tool restriction that names Hushy's read-only MCP tools and nothing else.
@Suite("Claude Code command")
struct ClaudeCodeCommandTests {
    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @Test("the invocation runs the CLI directly, never through a shell")
    func noShell() {
        let invocation = ClaudeCodeCommand.invocation(
            executable: "/Users/x/.local/bin/claude", message: "hi", turn: AgentTurnOptions(),
            workingDirectory: "/tmp/w", mcpConfigPath: "/tmp/hushy-mcp.json")
        #expect(invocation.executable == "/Users/x/.local/bin/claude")
        for shell in ["sh", "bash", "zsh", "env"] {
            #expect(!invocation.executable.hasSuffix("/\(shell)"))
        }
        #expect(!invocation.arguments.contains("-c"))
    }

    @Test("the message goes on stdin and never into the arguments")
    func messageOnStdin() {
        let message = "What did I say about the deck?\"; rm -rf ~ $(whoami) `id`"
        let invocation = ClaudeCodeCommand.invocation(
            executable: "/bin/claude", message: message, turn: AgentTurnOptions(),
            workingDirectory: "/tmp/w", mcpConfigPath: "/tmp/c.json")
        #expect(invocation.stdin == message)
        #expect(!invocation.arguments.contains { $0.contains("deck") || $0.contains("whoami") })
        // No positional prompt: `-p` is followed by an option, so it reads stdin.
        #expect(invocation.arguments.first == "-p")
        #expect(invocation.arguments[1].hasPrefix("--"))
    }

    @Test("built-in tools are removed and only Hushy's MCP tools are allowed")
    func toolRestriction() {
        let arguments = ClaudeCodeCommand.arguments(mcpConfigPath: "/tmp/c.json", turn: AgentTurnOptions(resumeSessionID: nil))
        #expect(value(after: "--tools", in: arguments) == "")
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(value(after: "--mcp-config", in: arguments) == "/tmp/c.json")
        #expect(value(after: "--permission-mode", in: arguments) == "dontAsk")
        #expect(value(after: "--output-format", in: arguments) == "stream-json")
        #expect(arguments.contains("--verbose"))

        let allowed = value(after: "--allowedTools", in: arguments)?.split(separator: ",").map(String.init) ?? []
        #expect(allowed == MCPServer.toolNames(for: .notes).map { "mcp__hushy__\($0)" })
        // The Assistant reads meeting notes only, never dictations.
        #expect(!allowed.contains("mcp__hushy__search_history"))
        #expect(!allowed.contains("mcp__hushy__recent_dictations"))
        #expect(allowed.allSatisfy { $0.hasPrefix("mcp__hushy__") })
        #expect(AgentToolPolicy.violations(in: allowed).isEmpty)

        let denied = Set(value(after: "--disallowedTools", in: arguments)?.split(separator: ",").map(String.init) ?? [])
        for tool in ["Bash", "Edit", "Write", "Read", "WebFetch", "WebSearch", "Task"] {
            #expect(denied.contains(tool))
        }
        #expect(!arguments.contains("--dangerously-skip-permissions"))
        #expect(!arguments.contains { $0.contains("bypassPermissions") })
    }

    @Test("resume is added only for a well-formed session id")
    func resume() {
        let resumed = ClaudeCodeCommand.arguments(mcpConfigPath: "/c", turn: AgentTurnOptions(resumeSessionID: "9b2e1c3a-0f4d-4e7a-9b1c-2d3e4f5a6b7c"))
        #expect(value(after: "--resume", in: resumed) == "9b2e1c3a-0f4d-4e7a-9b1c-2d3e4f5a6b7c")
        #expect(!ClaudeCodeCommand.arguments(mcpConfigPath: "/c", turn: AgentTurnOptions(resumeSessionID: nil)).contains("--resume"))
        for bad in ["", "--dangerously-skip-permissions", "a b", "x;rm", "ünïcode"] {
            #expect(!ClaudeCodeCommand.arguments(mcpConfigPath: "/c", turn: AgentTurnOptions(resumeSessionID: bad)).contains("--resume"))
        }
    }

    @Test("the MCP config points at the bundled server only")
    func mcpConfig() throws {
        let data = try ClaudeCodeCommand.mcpConfigJSON(serverPath: "/Applications/Hushy.app/Contents/MacOS/hushy-mcp", murmurHome: "/tmp/h")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(Array(servers.keys) == ["hushy"])
        let hushy = try #require(servers["hushy"] as? [String: Any])
        #expect(hushy["command"] as? String == "/Applications/Hushy.app/Contents/MacOS/hushy-mcp")
        #expect(hushy["type"] as? String == "stdio")
        #expect((hushy["env"] as? [String: String])?["MURMUR_HOME"] == "/tmp/h")
        let bare = try JSONSerialization.jsonObject(with: ClaudeCodeCommand.mcpConfigJSON(serverPath: "/x")) as? [String: Any]
        #expect(((bare?["mcpServers"] as? [String: Any])?["hushy"] as? [String: Any])?["env"] == nil)
    }

    @Test("environment overrides set and remove variables")
    func environment() {
        let invocation = AgentInvocation(
            executable: "/x", arguments: [], stdin: "", workingDirectory: "/",
            environmentOverrides: ["CLAUDECODE": nil, "PATH": "/a:/b"])
        let env = invocation.environment(from: ["CLAUDECODE": "1", "HOME": "/Users/x", "PATH": "/usr/bin"])
        #expect(env == ["HOME": "/Users/x", "PATH": "/a:/b"])
    }

    @Test("the model defaults to Haiku and Sonnet is selectable, via the CLI's aliases")
    func model() {
        #expect(AgentTurnOptions().model == .haiku)
        #expect(value(after: "--model", in: ClaudeCodeCommand.arguments(mcpConfigPath: "/c", turn: AgentTurnOptions())) == "haiku")
        #expect(value(after: "--model", in: ClaudeCodeCommand.arguments(
            mcpConfigPath: "/c", turn: AgentTurnOptions(model: .sonnet))) == "sonnet")
        #expect(AssistantModelChoice.allCases.map(\.claudeAlias) == ["haiku", "sonnet"])
    }

    @Test("the system prompt carries local time and, when given, the earlier transcript")
    func systemPrompt() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let plain = ClaudeCodeCommand.systemPrompt(for: AgentTurnOptions(now: now, timeZone: zone))
        #expect(plain.hasPrefix(ClaudeCodeCommand.baseSystemPrompt))
        #expect(plain.contains("America/Los_Angeles"))
        #expect(plain.contains("-07:00") || plain.contains("-08:00"))
        #expect(plain.contains("propose_action"))
        let turn = AgentTurnOptions(carriedContext: "Earlier: hello", now: now, timeZone: zone)
        let carried = ClaudeCodeCommand.systemPrompt(for: turn)
        #expect(!carried.contains("Earlier: hello"))
        #expect(ClaudeCodeCommand.stdinText(message: "Follow up", turn: turn).hasPrefix("Earlier: hello"))
        #expect(ClaudeCodeCommand.stdinText(message: "Follow up", turn: turn).hasSuffix("Follow up"))
        let args = ClaudeCodeCommand.arguments(mcpConfigPath: "/c", turn: turn)
        #expect(args.filter { $0.contains("Earlier: hello") }.isEmpty)
    }

    @Test("propose_action is allowed; the runtime check allows exactly Hushy's tools by name")
    func proposeActionAllowed() {
        let allowed = ClaudeCodeCommand.allowedTools
        #expect(allowed.contains("mcp__hushy__propose_action"))
        #expect(allowed.count == 4 + MeetingMemoryTools.names.count, "three notes lookups, the meeting-memory lookups and propose_action")
        #expect(!AgentToolPolicy.violations(in: ["mcp__hushy__search_history"]).isEmpty)
        #expect(AgentToolPolicy.violations(in: allowed + ["ListMcpResourcesTool"]).isEmpty)
        #expect(AgentToolPolicy.violations(in: ["mcp__hushy__delete_everything", "Bash", "mcp__other__x"])
            == ["mcp__hushy__delete_everything", "Bash", "mcp__other__x"])
    }

    @Test("only Claude Code is supported; Codex is listed but not wired up")
    func supportedAgents() {
        #expect(AgentKind.claudeCode.isSupported)
        #expect(!AgentKind.codex.isSupported)
        #expect(Entitlements.has(.assistantChat))
        #expect(ProFeature.assistantChat.isFree)
    }
}

@Suite("Executable locator")
struct ExecutableLocatorTests {
    @Test("PATH comes first, then the usual install directories, without duplicates")
    func searchOrder() {
        let dirs = ExecutableLocator.searchDirectories(path: "/usr/bin::/opt/homebrew/bin", home: "/Users/x")
        #expect(dirs.first == "/usr/bin")
        #expect(dirs.contains("/Users/x/.local/bin"))
        #expect(dirs.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(!dirs.contains(""))
    }

    @Test("finds a tool outside a minimal PATH, and refuses paths")
    func locate() {
        let executables: Set<String> = ["/Users/x/.local/bin/claude", "/usr/bin/true"]
        let found = ExecutableLocator.locate("claude", path: "/usr/bin:/bin", home: "/Users/x") { executables.contains($0) }
        #expect(found == "/Users/x/.local/bin/claude")
        #expect(ExecutableLocator.locate("missing", path: "/usr/bin", home: "/Users/x") { executables.contains($0) } == nil)
        #expect(ExecutableLocator.locate("../bin/true", path: "/usr/bin", home: "/x") { _ in true } == nil)
        #expect(ExecutableLocator.locate("", path: "/usr/bin", home: "/x") { _ in true } == nil)
    }
}

@Suite("MCP notes scope")
struct MCPNotesScopeTests {
    @Test("the notes scope hides and refuses dictation tools; the default scope serves usage totals only")
    func notesScope() throws {
        let queue = try DatabaseQueue()
        let notes = MCPServer(reader: queue, scope: .notes)
        let list = notes.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) ?? ""
        #expect(list.contains("search_notes"))
        #expect(!list.contains("search_history"))
        #expect(!list.contains("recent_dictations"))
        #expect(!list.contains("get_insights"))
        let call = notes.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"recent_dictations","arguments":{}}}"#) ?? ""
        #expect(call.contains("Unknown tool") && call.contains("removed"))
        #expect(MCPServer.toolNames(for: .all) == ["get_insights"])
        let config = String(decoding: try ClaudeCodeCommand.mcpConfigJSON(serverPath: "/x/hushy-mcp"), as: UTF8.self)
        #expect(config.contains("--scope") && config.contains("notes"))
    }
}
