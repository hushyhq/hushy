import Foundation
import Testing
@testable import MurmurCore

/// Canned Claude Code `--output-format stream-json --verbose --include-partial-messages` lines,
/// shaped like the CLI's real output, folded through `AgentStreamParser` and `AgentReply`.
@Suite("Agent stream parsing")
struct AgentStreamParserTests {
    static let initLine = #"{"type":"system","subtype":"init","cwd":"/tmp/x","session_id":"5f1c-aa","tools":["mcp__hushy__search_notes","mcp__hushy__get_note"],"mcp_servers":[{"name":"hushy","status":"connected"}],"model":"claude","permissionMode":"dontAsk"}"#
    static func delta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}},"session_id":"5f1c-aa","parent_tool_use_id":null}"#
    }
    static let toolUseLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"toolu_1","name":"mcp__hushy__search_notes","input":{"query":"deck"}}]},"session_id":"5f1c-aa","parent_tool_use_id":null}"#
    static let toolResultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"3 results","is_error":false}]},"session_id":"5f1c-aa"}"#
    static let answerLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You said the deck is due **Friday**."}]},"session_id":"5f1c-aa"}"#
    static let resultLine = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1200,"num_turns":2,"result":"You said the deck is due **Friday**.","session_id":"5f1c-aa"}"#

    private func reply(from lines: [String]) -> AgentReply {
        var reply = AgentReply()
        for line in lines {
            for event in AgentStreamParser.events(fromLine: line) { reply.apply(event) }
        }
        return reply
    }

    @Test("init line reports session, tools and MCP server status")
    func parsesInit() {
        let events = AgentStreamParser.events(fromLine: Self.initLine)
        #expect(events == [.started(
            sessionID: "5f1c-aa", tools: ["mcp__hushy__search_notes", "mcp__hushy__get_note"],
            mcpServers: ["hushy": "connected"])])
    }

    @Test("text deltas, tool use, tool result and the final result parse")
    func parsesEachKind() {
        #expect(AgentStreamParser.events(fromLine: Self.delta("Hel")) == [.textDelta("Hel")])
        #expect(AgentStreamParser.events(fromLine: Self.toolUseLine)
                == [.assistantMessage(text: "Let me look.", toolUses: ["mcp__hushy__search_notes"])])
        #expect(AgentStreamParser.events(fromLine: Self.toolResultLine) == [.toolResult(isError: false)])
        #expect(AgentStreamParser.events(fromLine: Self.resultLine) == [.finished(AgentResult(
            isError: false, subtype: "success", text: "You said the deck is due **Friday**.", sessionID: "5f1c-aa"))])
    }

    @Test("garbage, blank and unknown lines are ignored rather than failing the turn")
    func ignoresNoise() {
        #expect(AgentStreamParser.events(fromLine: "").isEmpty)
        #expect(AgentStreamParser.events(fromLine: "not json at all").isEmpty)
        #expect(AgentStreamParser.events(fromLine: #"{"type":"rate_limit_event"}"#).isEmpty)
        #expect(AgentStreamParser.events(fromLine: #"{"type":"system","subtype":"hook_started"}"#).isEmpty)
        // Sub-agent output isn't the reply.
        let nested = #"{"type":"assistant","message":{"content":[{"type":"text","text":"inner"}]},"parent_tool_use_id":"toolu_9"}"#
        #expect(AgentStreamParser.events(fromLine: nested).isEmpty)
    }

    @Test("a full turn folds into one answer without duplicating streamed text")
    func foldsFullTurn() {
        let reply = reply(from: [
            Self.initLine, Self.delta("Let "), Self.delta("me look."), Self.toolUseLine, Self.toolResultLine,
            Self.delta("You said"), Self.answerLine, Self.resultLine,
        ])
        #expect(reply.text == "Let me look.\n\nYou said the deck is due **Friday**.")
        #expect(reply.sessionID == "5f1c-aa")
        #expect(reply.toolsUsed == ["mcp__hushy__search_notes"])
        #expect(reply.isFinished)
        #expect(reply.error == nil)
        #expect(reply.activity == nil)
    }

    @Test("tool use shows a present-tense activity until text resumes")
    func activityLabels() {
        var reply = reply(from: [Self.initLine, Self.toolUseLine])
        #expect(reply.activity == "Searching your notes…")
        reply.apply(.toolResult(isError: false))
        #expect(reply.activity == "Reading what it found…")
        reply.apply(.textDelta("Found it"))
        #expect(reply.activity == nil)
        #expect(AgentReply.activityLabel(forTool: "mcp__hushy__get_insights") == "Checking your stats…")
        #expect(AgentReply.activityLabel(forTool: "mcp__other__thing") == "Working…")
    }

    @Test("streamed text is kept when the stream ends without a complete message")
    func keepsStreamedTextOnResult() {
        let reply = reply(from: [Self.initLine, Self.delta("Partial answer"),
                                 #"{"type":"result","subtype":"success","is_error":false,"result":"","session_id":"5f1c-aa"}"#])
        #expect(reply.text == "Partial answer")
    }

    @Test("a result with no streamed text falls back to the result's text")
    func resultTextFallback() {
        let reply = reply(from: [Self.initLine, Self.resultLine])
        #expect(reply.text == "You said the deck is due **Friday**.")
    }

    @Test("a not-logged-in error result becomes notLoggedIn")
    func notLoggedIn() {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","session_id":"x"}"#
        let reply = reply(from: [line])
        #expect(reply.error == .notLoggedIn(.claudeCode))
        #expect(reply.isFinished)
    }

    @Test("an error result carries its detail")
    func errorResult() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Something broke"],"session_id":"x"}"#
        #expect(reply(from: [line]).error == .agentError("Something broke"))
        let maxTurns = #"{"type":"result","subtype":"error_max_turns","session_id":"x"}"#
        #expect(reply(from: [maxTurns]).error == .agentError(""))
    }

    @Test("a failed Hushy MCP server marks the answer as not grounded in the user's data")
    func dataUnavailable() {
        let line = #"{"type":"system","subtype":"init","session_id":"s","tools":[],"mcp_servers":[{"name":"hushy","status":"failed"}]}"#
        #expect(reply(from: [line]).dataUnavailable)
        #expect(!reply(from: [Self.initLine]).dataUnavailable)
    }

    @Test("fail() records the first error only")
    func failKeepsFirst() {
        var reply = AgentReply()
        reply.fail(.timedOut(seconds: 120))
        reply.fail(.exited(code: 1, detail: ""))
        #expect(reply.error == .timedOut(seconds: 120))
    }
}

@Suite("Agent tool policy")
struct AgentToolPolicyTests {
    @Test("only Hushy's MCP tools (and the MCP resource helpers) are acceptable")
    func violations() {
        #expect(AgentToolPolicy.violations(in: ClaudeCodeCommand.allowedTools).isEmpty)
        #expect(AgentToolPolicy.violations(in: ["ListMcpResourcesTool", "ReadMcpResourceTool"]).isEmpty)
        #expect(AgentToolPolicy.violations(in: ["mcp__hushy__search_notes", "Bash", "Read", "mcp__github__create_issue", "mcp__hushyx__a"])
                == ["Bash", "Read", "mcp__github__create_issue", "mcp__hushyx__a"])
    }
}
