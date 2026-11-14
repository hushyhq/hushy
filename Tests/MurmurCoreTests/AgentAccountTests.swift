import Foundation
import Testing
@testable import MurmurCore

/// Sign-in detection and the fixed login commands. Real CLIs are never run: status parsing is
/// checked against canned outputs and fake `/bin/sh` CLIs.
@Suite("Agent accounts", .serialized)
struct AgentAccountTests {
    @Test("status and login commands are fixed argument vectors")
    func fixedCommands() {
        #expect(AgentAuth.statusArguments(for: .claudeCode) == ["auth", "status", "--json"])
        #expect(AgentAuth.statusArguments(for: .codex) == ["login", "status"])
        #expect(AgentAuth.loginArguments(for: .claudeCode) == ["auth", "login"])
        #expect(AgentAuth.loginArguments(for: .codex) == ["login"])
        #expect(AgentAuth.loginNeedsTerminal(.claudeCode))
        #expect(!AgentAuth.loginNeedsTerminal(.codex))
        #expect(AgentAuth.terminalScript(for: .claudeCode) == "#!/bin/zsh -l\nclaude auth login\n")
        #expect(AgentAuth.terminalScript(for: .codex) == "#!/bin/zsh -l\ncodex login\n")
        for agent in AgentKind.allCases {
            // Nothing that reads a secret from stdin or a flag, ever.
            let all = AgentAuth.loginArguments(for: agent) + AgentAuth.statusArguments(for: agent)
            #expect(!all.contains { $0.contains("api-key") || $0.contains("token") || $0.contains("email") })
            #expect(AgentAuth.docsURL(for: agent).scheme == "https")
        }
    }

    @Test("Claude Code status JSON", arguments: [
        (#"{"loggedIn": true, "authMethod": "claude.ai", "email": "x@example.com"}"#, Int32(0), AgentAccountState.ready),
        (#"{"loggedIn": false, "authMethod": "none"}"#, Int32(1), .signedOut),
        ("Not logged in. Run claude auth login to authenticate.", Int32(1), .signedOut),
        ("", Int32(0), .ready),
        ("garbage", Int32(2), .signedOut),
    ])
    func claudeStatus(output: String, exitCode: Int32, expected: AgentAccountState) {
        #expect(AgentAuth.parseStatus(for: .claudeCode, output: output, exitCode: exitCode) == expected)
    }

    @Test("Codex status text", arguments: [
        ("Logged in using ChatGPT", Int32(0), AgentAccountState.ready),
        ("Logged in using an API key - sk-***", Int32(0), .ready),
        ("Not logged in", Int32(1), .signedOut),
        ("", Int32(1), .signedOut),
    ])
    func codexStatus(output: String, exitCode: Int32, expected: AgentAccountState) {
        #expect(AgentAuth.parseStatus(for: .codex, output: output, exitCode: exitCode) == expected)
    }

    // MARK: Fake CLIs

    private func fakeCLI(named name: String, body: String) throws -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-fake-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (directory, script.path)
    }

    @Test("a fake signed-in Claude Code reads as ready, and only the status argv was passed")
    func fakeClaudeReady() async throws {
        let (directory, path) = try fakeCLI(named: "claude", body: #"""
            printf '%s\n' "$@" > "$(dirname "$0")/args.txt"
            echo '{"loggedIn": true, "authMethod": "claude.ai"}'
            """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checker = AgentAccountChecker(locate: { $0 == "claude" ? path : nil })
        #expect(await checker.state(for: .claudeCode) == .ready)
        #expect(await checker.state(for: .codex) == .notInstalled)
        let args = try String(contentsOf: directory.appendingPathComponent("args.txt"), encoding: .utf8)
        #expect(args == "auth\nstatus\n--json\n")
    }

    @Test("a fake signed-out CLI (exit 1) reads as signed out; a hung one as unknown")
    func fakeSignedOutAndHung() async throws {
        let (outDir, outPath) = try fakeCLI(named: "codex", body: "echo 'Not logged in' >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: outDir) }
        #expect(await AgentAccountChecker(locate: { $0 == "codex" ? outPath : nil }).state(for: .codex) == .signedOut)

        let (claudeDir, claudePath) = try fakeCLI(named: "claude", body: #"echo '{"loggedIn": false}'; exit 1"#)
        defer { try? FileManager.default.removeItem(at: claudeDir) }
        #expect(await AgentAccountChecker(locate: { $0 == "claude" ? claudePath : nil }).state(for: .claudeCode) == .signedOut)

        let (hungDir, hungPath) = try fakeCLI(named: "claude", body: "sleep 30\n")
        defer { try? FileManager.default.removeItem(at: hungDir) }
        let hung = AgentAccountChecker(locate: { _ in hungPath }, statusTimeout: .milliseconds(500))
        #expect(await hung.state(for: .claudeCode) == .unknown)
    }

    @Test("the browser sign-in runs the fixed login argv with nothing on stdin")
    func fakeCodexLogin() async throws {
        let (directory, path) = try fakeCLI(named: "codex", body: #"""
            printf '%s\n' "$@" > "$(dirname "$0")/args.txt"
            cat > "$(dirname "$0")/stdin.txt"
            echo 'Starting local login server on http://localhost:1455'
            exit 0
            """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checker = AgentAccountChecker(locate: { $0 == "codex" ? path : nil })
        #expect(await checker.signIn(.codex) == 0)
        #expect(try String(contentsOf: directory.appendingPathComponent("args.txt"), encoding: .utf8) == "login\n")
        #expect(try String(contentsOf: directory.appendingPathComponent("stdin.txt"), encoding: .utf8).isEmpty)
        // Claude Code's login needs a terminal, so the checker never runs it directly.
        #expect(await checker.signIn(.claudeCode) == nil)
    }
}
