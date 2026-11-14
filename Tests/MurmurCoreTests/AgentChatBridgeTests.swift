import Foundation
import Testing
@testable import MurmurCore

/// Runs the real `AgentChatBridge`/`AgentProcessRunner` against fake agent executables — small
/// `/bin/sh` scripts in a temp directory that emit canned Claude Code stream-json — so the whole
/// subprocess path (argv, stdin, streaming, exit codes, timeout, cancellation, tool policy) is
/// exercised without ever launching a real agent or touching the network.
@Suite("Agent chat bridge (fake agent)", .serialized)
struct AgentChatBridgeTests {
    /// A temp dir holding one fake `claude` script and a workspace for the conversation.
    struct Fixture {
        let directory: URL
        let script: URL
        let workspace: AgentWorkspace

        init(script body: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("hushy-fake-agent-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            script = directory.appendingPathComponent("claude")
            try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            workspace = AgentWorkspace(root: directory.appendingPathComponent("conversation", isDirectory: true))
        }

        func bridge(timeout: Duration = .seconds(3600)) -> AgentChatBridge {
            let path = script.path
            return AgentChatBridge(
                runner: AgentProcessRunner(timeout: timeout, killGrace: .milliseconds(300)),
                locate: { $0 == "claude" ? path : nil },
                serverPath: "/usr/bin/true", murmurHome: nil)
        }

        func file(_ name: String) -> String? {
            try? String(contentsOf: workspace.workingDirectory.appendingPathComponent(name), encoding: .utf8)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Records argv (NUL-separated, since the system prompt spans lines) and stdin into the working directory, then streams a turn.
    static let happyScript = #"""
        for arg in "$@"; do printf '%s\0' "$arg" >> args.txt; done
        cat > stdin.txt
        pwd > cwd.txt
        cat <<'JSON'
        {"type":"system","subtype":"init","session_id":"sess-42","tools":["mcp__hushy__search_notes","mcp__hushy__get_note"],"mcp_servers":[{"name":"hushy","status":"connected"}]}
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking"}},"session_id":"sess-42"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Checking."},{"type":"tool_use","id":"t1","name":"mcp__hushy__search_notes","input":{"query":"deck"}}]},"session_id":"sess-42"}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]},"session_id":"sess-42"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"The deck is due Friday."}]},"session_id":"sess-42"}
        {"type":"result","subtype":"success","is_error":false,"result":"The deck is due Friday.","session_id":"sess-42"}
        JSON
        """#

    private func collect(_ stream: AsyncStream<AgentReply>) async -> [AgentReply] {
        var replies: [AgentReply] = []
        for await reply in stream { replies.append(reply) }
        return replies
    }

    @Test("a full turn streams, records the session, and passes the message only on stdin")
    func happyPath() async throws {
        let fixture = try Fixture(script: Self.happyScript)
        defer { fixture.cleanUp() }
        let message = "What did I say about the deck? $(touch pwned) `id`; rm -rf /"
        let replies = await collect(fixture.bridge().send(
            message: message, agent: .claudeCode, sessionID: nil, workspace: fixture.workspace))

        let final = try #require(replies.last)
        #expect(final.error == nil)
        #expect(final.isFinished)
        #expect(final.text == "Checking.\n\nThe deck is due Friday.")
        #expect(final.sessionID == "sess-42")
        #expect(final.toolsUsed == ["mcp__hushy__search_notes"])
        #expect(replies.contains { $0.activity == "Searching your notes…" })
        #expect(replies.count > 2, "the reply should arrive incrementally, not in one piece")

        // The message reached the child verbatim on stdin and was never executed.
        #expect(fixture.file("stdin.txt") == message)
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.workingDirectory.appendingPathComponent("pwned").path))
        // It ran in the conversation's own empty working directory.
        let cwd = fixture.file("cwd.txt")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(cwd.hasSuffix("/conversation/workspace"))

        // argv is exactly what ClaudeCodeCommand builds: no prompt, tools restricted.
        let args: [String] = Array((fixture.file("args.txt") ?? "").components(separatedBy: "\0").dropLast())
        // Everything but the system prompt (which carries the current time) matches exactly.
        func withoutPrompt(_ list: [String]) -> [String] {
            guard let index = list.firstIndex(of: "--append-system-prompt") else { return list }
            var copy = list
            copy.removeSubrange(index...(index + 1))
            return copy
        }
        #expect(withoutPrompt(args) == withoutPrompt(ClaudeCodeCommand.arguments(
            mcpConfigPath: fixture.workspace.mcpConfigFile.path, turn: AgentTurnOptions())))
        let promptIndex = try #require(args.firstIndex(of: "--append-system-prompt"))
        #expect(args[promptIndex + 1].hasPrefix(ClaudeCodeCommand.baseSystemPrompt))
        let modelIndex = try #require(args.firstIndex(of: "--model"))
        #expect(args[modelIndex + 1] == "haiku")
        #expect(!args.contains { $0.contains("deck") })
        let toolsIndex = try #require(args.firstIndex(of: "--tools"))
        #expect(args[toolsIndex + 1] == "")

        // The MCP config written beside the workspace names only Hushy's server.
        let config = try Data(contentsOf: fixture.workspace.mcpConfigFile)
        let servers = (try JSONSerialization.jsonObject(with: config) as? [String: Any])?["mcpServers"] as? [String: Any]
        #expect(servers.map { Array($0.keys) } == ["hushy"])
    }

    @Test("the next turn resumes the session id from the stream")
    func resumes() async throws {
        let fixture = try Fixture(script: Self.happyScript)
        defer { fixture.cleanUp() }
        _ = await collect(fixture.bridge().send(message: "one", agent: .claudeCode, sessionID: "sess-42", workspace: fixture.workspace))
        let args = (fixture.file("args.txt") ?? "").components(separatedBy: "\0")
        let index = try #require(args.firstIndex(of: "--resume"))
        #expect(args[index + 1] == "sess-42")
    }

    @Test("a non-zero exit with stderr becomes a readable error")
    func nonZeroExit() async throws {
        let fixture = try Fixture(script: "cat > /dev/null\necho 'boom: something failed' >&2\nexit 3\n")
        defer { fixture.cleanUp() }
        let final = await collect(fixture.bridge().send(message: "hi", agent: .claudeCode, sessionID: nil, workspace: fixture.workspace)).last
        #expect(final?.error == .exited(code: 3, detail: "boom: something failed"))
        #expect(final?.isFinished == true)
    }

    @Test("a not-signed-in CLI is reported as such, from the result line or stderr")
    func notLoggedIn() async throws {
        let fromResult = try Fixture(script: #"""
            cat > /dev/null
            echo '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}'
            exit 1
            """#)
        defer { fromResult.cleanUp() }
        let first = await collect(fromResult.bridge().send(message: "hi", agent: .claudeCode, sessionID: nil, workspace: fromResult.workspace)).last
        #expect(first?.error == .notLoggedIn(.claudeCode))

        let fromStderr = try Fixture(script: "cat > /dev/null\necho 'Invalid API key · Please run /login' >&2\nexit 1\n")
        defer { fromStderr.cleanUp() }
        let second = await collect(fromStderr.bridge().send(message: "hi", agent: .claudeCode, sessionID: nil, workspace: fromStderr.workspace)).last
        #expect(second?.error == .notLoggedIn(.claudeCode))
    }

    @Test("a hung agent is killed at the timeout")
    func timeout() async throws {
        let fixture = try Fixture(script: "cat > /dev/null\necho $$ > pid.txt\nsleep 30\n")
        defer { fixture.cleanUp() }
        let started = SuspendingClock.now
        let final = await collect(fixture.bridge(timeout: .seconds(1)).send(
            message: "hi", agent: .claudeCode, sessionID: nil, workspace: fixture.workspace)).last
        #expect(final?.error == .timedOut(seconds: 1))
        // The agent sleeps 30 s; one that was not killed would hold this up that long. Half of it cannot be reached
        // by a busy machine, and SuspendingClock does not count time the Mac spent asleep.
        #expect(SuspendingClock.now - started < .seconds(15))
        try await assertProcessGone(pidFile: fixture.file("pid.txt"))
    }

    @Test("cancelling the consumer stops the agent")
    func cancellation() async throws {
        let fixture = try Fixture(script: #"""
            cat > /dev/null
            echo $$ > pid.txt
            echo '{"type":"system","subtype":"init","session_id":"s","tools":[],"mcp_servers":[]}'
            sleep 30
            """#)
        defer { fixture.cleanUp() }
        let stream = fixture.bridge().send(message: "hi", agent: .claudeCode, sessionID: nil, workspace: fixture.workspace)
        let consumer = Task { await collect(stream) }
        try await Task.sleep(for: .milliseconds(500))
        consumer.cancel()
        let started = SuspendingClock.now
        _ = await consumer.value
        // The agent sleeps 30 s; see `timeout` for why 15 s.
        #expect(SuspendingClock.now - started < .seconds(15))
        try await assertProcessGone(pidFile: fixture.file("pid.txt"))
    }

    @Test("an agent offered tools beyond Hushy's is stopped before it answers")
    func toolPolicy() async throws {
        let fixture = try Fixture(script: #"""
            cat > /dev/null
            echo $$ > pid.txt
            echo '{"type":"system","subtype":"init","session_id":"s","tools":["Bash","mcp__hushy__search_notes","Read"],"mcp_servers":[{"name":"hushy","status":"connected"}]}'
            sleep 60
            echo '{"type":"assistant","message":{"content":[{"type":"text","text":"should never be shown"}]}}'
            """#)
        defer { fixture.cleanUp() }
        let started = SuspendingClock.now
        let replies = await collect(fixture.bridge().send(message: "hi", agent: .claudeCode, sessionID: nil, workspace: fixture.workspace))
        #expect(replies.last?.error == .toolPolicyViolation(["Bash", "Read"]))
        #expect(!replies.contains { $0.text.contains("should never") })
        // The agent would sit for 60 s before its (forbidden) answer; stopping it is what keeps this short.
        #expect(SuspendingClock.now - started < .seconds(30))
        try await assertProcessGone(pidFile: fixture.file("pid.txt"))
    }

    @Test("missing CLI, missing server and unsupported agents fail before launching anything")
    func preflightFailures() async throws {
        let workspace = AgentWorkspace(root: FileManager.default.temporaryDirectory.appendingPathComponent("hushy-none-\(UUID().uuidString)"))
        defer { workspace.remove() }
        let noCLI = AgentChatBridge(locate: { _ in nil }, serverPath: "/usr/bin/true")
        #expect(await collect(noCLI.send(message: "hi", agent: .claudeCode, sessionID: nil, workspace: workspace)).last?.error
                == .cliMissing(.claudeCode))
        let noServer = AgentChatBridge(locate: { _ in "/usr/bin/true" }, serverPath: nil)
        #expect(await collect(noServer.send(message: "hi", agent: .claudeCode, sessionID: nil, workspace: workspace)).last?.error
                == .serverMissing)
        #expect(await collect(noServer.send(message: "hi", agent: .codex, sessionID: nil, workspace: workspace)).last?.error
                == .unsupported(.codex))
    }

    @Test("an agent that exits cleanly without answering says so")
    func silentExit() async throws {
        let fixture = try Fixture(script: "cat > /dev/null\nexit 0\n")
        defer { fixture.cleanUp() }
        let final = await collect(fixture.bridge().send(message: "hi", agent: .claudeCode, sessionID: nil, workspace: fixture.workspace)).last
        #expect(final?.error == .agentError("The agent ended without answering."))
    }

    /// A fake agent that proposes a reminder through `propose_action`, the way Claude Code
    /// reports the tool call and its (acknowledgement) result.
    static func proposingScript(start: String) -> String {
        """
        cat > /dev/null
        cat <<'JSON'
        {"type":"system","subtype":"init","session_id":"sess-7","tools":["mcp__hushy__search_notes","mcp__hushy__propose_action"],"mcp_servers":[{"name":"hushy","status":"connected"}]}
        {"type":"assistant","message":{"content":[{"type":"text","text":"I'll set that up."},{"type":"tool_use","id":"t1","name":"mcp__hushy__propose_action","input":{"kind":"createReminder","title":"Send the deck","start":"\(start)","listName":"Work"}}]},"session_id":"sess-7"}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Proposed (not created)","is_error":false}]},"session_id":"sess-7"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"It's ready for you to confirm."}]},"session_id":"sess-7"}
        {"type":"result","subtype":"success","is_error":false,"result":"It's ready for you to confirm.","session_id":"sess-7"}
        JSON
        """
    }

    @Test("a proposed action in the stream becomes a card on the reply, and nothing else")
    func proposedAction() async throws {
        let start = ProposeActionTool.isoFormatter().string(from: Date().addingTimeInterval(86_400))
        let fixture = try Fixture(script: Self.proposingScript(start: start))
        defer { fixture.cleanUp() }
        let final = try #require(await collect(fixture.bridge().send(
            message: "remind me", agent: .claudeCode, sessionID: nil, workspace: fixture.workspace)).last)
        #expect(final.error == nil)
        #expect(final.proposedActions.count == 1)
        let action = try #require(final.proposedActions.first)
        #expect(action.kind == .createReminder)
        #expect(action.title == "Send the deck")
        #expect(action.listName == "Work")
        #expect(final.toolsUsed == ["mcp__hushy__propose_action"])
        #expect(final.text.hasSuffix("It's ready for you to confirm."))
    }

    @Test("a resumed session that no longer exists is reported as sessionNotFound")
    func missingSession() async throws {
        let fixture = try Fixture(script: """
            cat > /dev/null
            for arg in "$@"; do if [ "$arg" = "--resume" ]; then echo 'No conversation found with session ID: gone-1' >&2; exit 1; fi; done
            \(Self.happyScript)
            """)
        defer { fixture.cleanUp() }
        let resumed = await collect(fixture.bridge().send(
            message: "again", agent: .claudeCode, sessionID: "gone-1", workspace: fixture.workspace)).last
        #expect(resumed?.error == .sessionNotFound)
        // The same failure text without --resume is just an exit error, not a missing session.
        let fresh = await collect(fixture.bridge().send(
            message: "again", agent: .claudeCode, sessionID: nil, workspace: fixture.workspace)).last
        #expect(fresh?.error == nil)
    }

    /// The fake agent's pid is no longer alive (allowing for SIGTERM to land: it polls and returns as soon as the process is gone, so the
    /// 30 s ceiling only matters on a machine too busy to deliver a signal).
    private func assertProcessGone(pidFile: String?) async throws {
        let pid = try #require(pidFile.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        for _ in 0..<300 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(kill(pid, 0) != 0, "fake agent \(pid) should have been terminated")
    }
}
