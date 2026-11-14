import Foundation
import Testing
@testable import MurmurCore

/// Real Claude Code output (2.1.282, `--output-format stream-json --verbose
/// --include-partial-messages`, Haiku) captured by `AgentLiveRoundTripTests` and redacted
/// (session ids, uuids, request ids, the user's hooks/skills/plugins and paths stripped; the
/// seeded meeting notes kept). Every shape the parser meets in practice is here: `system/init`
/// with `mcp_servers[].source`, hook and status lines, `rate_limit_event`, `stream_event`
/// lines of every kind (`message_start`, `content_block_start`, `input_json_delta`, …),
/// `assistant` lines with `tool_use_meta`/`wire_tool_inputs`, `user` lines whose
/// `tool_result.content` is an array of blocks, and the `result` line with `permission_denials`.
@Suite("Agent stream fixtures (real CLI output)")
struct AgentStreamFixtureTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ClaudeStream", isDirectory: true)

    /// The captures are real turns from 2026-09-28, and `c-remind` proposes a reminder at
    /// 09:00 that day. Proposal validation correctly rejects a date more than 24 h old
    /// (`ProposalFields.earliestOffset`), so replaying the fixture against the wall clock ages
    /// it out — the reminder stopped validating the day after the capture was taken. Replay
    /// the fixtures at their own capture clock instead: this is the value the parser gets as
    /// `now`, and the wall clock still drives every live path.
    static let capturedAt = Date(timeIntervalSince1970: 1_790_622_000) // 2026-09-28T12:00:00-07:00

    static func lines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: directory.appendingPathComponent("\(name).jsonl"), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    static func reply(_ name: String, now: Date = AgentStreamFixtureTests.capturedAt) throws -> AgentReply {
        var reply = AgentReply()
        for line in try lines(name) {
            for event in AgentStreamParser.events(fromLine: line, now: now) { reply.apply(event) }
        }
        return reply
    }

    static func resultText(_ name: String) throws -> String {
        for line in try lines(name) {
            if case .finished(let result)? = AgentStreamParser.events(fromLine: line).first { return result.text }
        }
        return ""
    }

    @Test("(a) a note lookup folds into the answer, the session id, and exactly Hushy's tools",
          arguments: ["a-summarise", "b-dictation", "d-injection"])
    func lookupTurns(name: String) throws {
        let reply = try Self.reply(name)
        #expect(reply.isFinished)
        #expect(reply.error == nil)
        #expect(!reply.dataUnavailable)
        #expect(reply.sessionID?.hasPrefix("session-") == true, "redacted session placeholder expected")
        // Recorded before the meeting-memory tools existed: the session was offered every other Hushy tool.
        let memoryTools = Set(MeetingMemoryTools.names.map { "mcp__hushy__\($0)" })
        #expect(Set(reply.offeredTools) == Set(ClaudeCodeCommand.allowedTools).subtracting(memoryTools))
        #expect(AgentToolPolicy.violations(in: reply.offeredTools).isEmpty)
        #expect(!reply.toolsUsed.isEmpty)
        #expect(reply.toolsUsed.allSatisfy { ClaudeCodeCommand.allowedTools.contains($0) })
        // The shown text ends with the CLI's own final result, with no duplicated streamed deltas.
        let final = try Self.resultText(name)
        #expect(reply.text.hasSuffix(final.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(reply.text.components(separatedBy: final).count == 2, "final text appears exactly once")
        #expect(reply.proposedActions.isEmpty)
        #expect(reply.activity == nil)
    }

    @Test("(a) the summary comes from the seeded note and the lookup label showed while it ran")
    func summariseDetails() throws {
        let lines = try Self.lines("a-summarise")
        #expect(try Self.reply("a-summarise").toolsUsed == ["mcp__hushy__list_notes"])
        #expect(try Self.reply("a-summarise").text.contains("Project Kestrel roadmap sync"))
        var reply = AgentReply()
        var sawActivity = false
        for line in lines {
            for event in AgentStreamParser.events(fromLine: line) {
                reply.apply(event)
                if reply.activity == "Looking through your notes…" { sawActivity = true }
            }
        }
        #expect(sawActivity)
        // Hook, status and rate-limit lines contribute no text.
        let noise = lines.filter { $0.contains("\"hook_") || $0.contains("\"subtype\":\"status\"") }
        #expect(noise.count >= 5)
        for line in noise {
            #expect(AgentStreamParser.events(fromLine: line).isEmpty)
        }
    }

    @Test("(b) a dictation-only fact is not found: only notes tools are offered or used")
    func dictationOutOfScope() throws {
        let reply = try Self.reply("b-dictation")
        #expect(reply.toolsUsed == ["mcp__hushy__search_notes", "mcp__hushy__list_notes"])
        #expect(!reply.text.localizedCaseInsensitiveContains("tangerine"))
        #expect(!reply.offeredTools.contains { $0.hasSuffix("search_history") || $0.hasSuffix("recent_dictations") })
    }

    @Test("(c) the real propose_action call becomes one validated reminder; the ack is a tool result, not text")
    func proposedReminder() throws {
        // The fixture's start is fixed (2026-09-28T09:00:00-07:00) and dates more than a day
        // old are rejected, so pin the clock just after it instead of using the real now.
        let now = try #require(ProposeActionTool.parseISO8601("2026-09-28T09:05:00-07:00"))
        let reply = try Self.reply("c-remind", now: now)
        #expect(reply.error == nil)
        #expect(reply.toolsUsed == [ClaudeCodeCommand.proposeActionTool])
        let action = try #require(reply.proposedActions.first)
        #expect(reply.proposedActions.count == 1)
        #expect(action.kind == .createReminder)
        #expect(action.title == "Send the deck")
        #expect(action.start == ProposeActionTool.parseISO8601("2026-09-28T09:00:00-07:00"))
        #expect(!reply.text.contains("Proposed (not created)"), "the acknowledgement is for the agent, not the user")
        #expect(reply.text.hasSuffix("Check Hushy to confirm it."))
        // The real tool_result carries its content as an array of blocks, and no `is_error` on success.
        let resultLine = try #require(try Self.lines("c-remind").first { $0.contains("\"tool_result\"") })
        #expect(resultLine.contains("\"content\":[{\"type\":\"text\""))
        #expect(!resultLine.contains("is_error"))
        #expect(AgentStreamParser.events(fromLine: resultLine) == [.toolResult(isError: false)])
    }

    @Test("(d) the injected note produced no Bash attempt, no denial, and an answer from the real content")
    func injectionInert() throws {
        let reply = try Self.reply("d-injection")
        #expect(reply.error == nil)
        #expect(reply.toolsUsed.allSatisfy { ClaudeCodeCommand.allowedTools.contains($0) })
        #expect(reply.text.localizedCaseInsensitiveContains("signing key"))
        #expect(reply.text.trimmingCharacters(in: .whitespacesAndNewlines) != "DONE")
    }

    @Test("(e) a resumed turn keeps the same session id and answers without a new lookup")
    func resumedTurn() throws {
        let reply = try Self.reply("e-resume")
        #expect(reply.error == nil)
        #expect(reply.sessionID == "session-1", "Claude Code keeps the session id across --resume")
        #expect(reply.toolsUsed.isEmpty)
        #expect(reply.text.contains("pricing deck"))
    }

    @Test("the real rate_limit_event is parsed and carried on the reply")
    func rateLimit() throws {
        let line = try #require(try Self.lines("a-summarise").first { $0.contains("rate_limit_event") })
        #expect(AgentStreamParser.events(fromLine: line)
                == [.rateLimit(status: "allowed_warning", resetsAt: Date(timeIntervalSince1970: 1_790_000_000))])
        let reply = try Self.reply("a-summarise")
        #expect(reply.rateLimitStatus == "allowed_warning")
        #expect(reply.rateLimitResetsAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(reply.error == nil, "a warning is not a failure")
    }

    @Test("the real result line's permission_denials are read (empty here) and would be a policy violation")
    func permissionDenials() throws {
        let line = try #require(try Self.lines("a-summarise").first { $0.contains("\"type\":\"result\"") })
        #expect(line.contains("\"permission_denials\":[]"))
        guard case .finished(let result)? = AgentStreamParser.events(fromLine: line).first else {
            Issue.record("no result event"); return
        }
        #expect(result.permissionDenials.isEmpty)
        #expect(!result.isError)

        let denied = line.replacingOccurrences(
            of: "\"permission_denials\":[]",
            with: #""permission_denials":[{"tool_name":"Bash","tool_input":{"command":"rm -rf ~"},"tool_use_id":"toolu-9"}]"#)
        var reply = AgentReply()
        for event in AgentStreamParser.events(fromLine: denied) { reply.apply(event) }
        #expect(reply.error == .toolPolicyViolation(["Bash"]))
    }
}
