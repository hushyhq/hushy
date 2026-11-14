import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// `propose_action` validates and acknowledges, and nothing else: no backend, no database
/// write, whoever calls it (Hushy's Assistant or an external MCP client).
@Suite("propose_action")
struct ProposeActionToolTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    private func iso(_ offset: TimeInterval) -> String {
        ProposeActionTool.isoFormatter().string(from: now.addingTimeInterval(offset))
    }

    @Test("a calendar event with start and duration becomes a ProposedAction")
    func event() throws {
        let result = ProposeActionTool.validate([
            "kind": "createEvent", "title": "  Dentist\u{0007} ", "start": iso(86_400), "durationMinutes": 45,
            "notes": "Bring the form", "calendarName": "Home", "location": "Main St",
        ], sourceText: "book the dentist", now: now)
        let action = try result.get()
        #expect(action.kind == .createEvent)
        #expect(action.title == "Dentist")
        #expect(action.end?.timeIntervalSince(try #require(action.start)) == 45 * 60)
        #expect(action.notes == "Bring the form")
        #expect(action.calendarName == "Home")
        #expect(action.location == "Main St")
        #expect(action.sourceText == "book the dentist")
    }

    @Test("an event without a duration gets 30 minutes; a reminder may have no date")
    func defaults() throws {
        let event = try ProposeActionTool.validate(["kind": "createEvent", "title": "Sync", "start": iso(3600)], now: now).get()
        #expect(event.end?.timeIntervalSince(try #require(event.start)) == 30 * 60)
        let reminder = try ProposeActionTool.validate(["kind": "createReminder", "title": "Buy milk", "listName": "Groceries"], now: now).get()
        #expect(reminder.start == nil)
        #expect(reminder.listName == "Groceries")
    }

    @Test("a shortcut needs its name")
    func shortcut() throws {
        let run = try ProposeActionTool.validate(
            ["kind": "runShortcut", "title": "Focus", "shortcutName": "Start Focus", "shortcutInput": "60"], now: now).get()
        #expect(run.shortcutName == "Start Focus")
        #expect(run.shortcutInput == "60")
        #expect(throws: ProposeActionTool.ValidationError.self) {
            try ProposeActionTool.validate(["kind": "runShortcut", "title": "Focus"], now: now).get()
        }
    }

    private func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    @Test("unknown kinds and missing fields are rejected", arguments: [
        #"{"kind":"deleteEverything","title":"x"}"#,
        #"{"kind":"none","title":"x"}"#,
        #"{"title":"no kind"}"#,
        #"{"kind":3,"title":"x"}"#,
        #"{"kind":"createReminder"}"#,
        #"{"kind":"createReminder","title":"   "}"#,
        #"{"kind":"createReminder","title":["x"]}"#,
        #"{"kind":"createEvent","title":"no start"}"#,
        #"{"kind":"createReminder","title":"\#(String(repeating: "a", count: 201))"}"#,
    ])
    func rejectsMalformed(_ input: String) throws {
        let arguments = try #require(json(input) as? [String: Any])
        #expect(throws: ProposeActionTool.ValidationError.self) { try ProposeActionTool.validate(arguments, now: now).get() }
    }

    @Test("malformed, zone-less, past and far-future dates are rejected", arguments: [
        "tomorrow at 3", "2026-09-22", "2026-09-22T15:00:00", "2026-13-40T25:61:00Z", "not a date",
        "2026-09-10T10:00:00Z", "2035-01-01T10:00:00Z",
    ])
    func rejectsDates(_ start: String) {
        let result = ProposeActionTool.validate(["kind": "createEvent", "title": "x", "start": start], now: now)
        #expect(throws: ProposeActionTool.ValidationError.self) { try result.get() }
    }

    @Test("durations must be whole minutes within 5 min – 24 h", arguments: ["0", "4", "1441", "-30", "2.5", "true", #""30""#])
    func rejectsDurations(_ duration: String) throws {
        let value = try #require(json(duration))
        let result = ProposeActionTool.validate(
            ["kind": "createEvent", "title": "x", "start": iso(3600), "durationMinutes": value], now: now)
        #expect(throws: ProposeActionTool.ValidationError.self) { try result.get() }
    }

    @Test("fractional seconds and Z are accepted")
    func dateFormats() throws {
        let fractional = ProposeActionTool.validate(["kind": "createReminder", "title": "x", "start": "2026-09-22T09:00:00.000Z"], now: now)
        #expect(try fractional.get().start != nil)
    }

    @Test("credential-looking free text is rejected everywhere, not just the connected tools")
    func screensCredentials() {
        for arguments: [String: Any] in [
            ["kind": "createReminder", "title": "Send the deck", "notes": "password: hunter2"],
            ["kind": "createEvent", "title": "Sync", "start": iso(3600), "location": "token is abcdef1234567890"],
            ["kind": "runShortcut", "title": "Focus", "shortcutName": "Start Focus", "shortcutInput": "api-key=abcdef1234567890"],
        ] {
            let result = ProposeActionTool.validate(arguments, now: now)
            #expect(throws: ProposeActionTool.ValidationError.self) { try result.get() }
        }
    }

    // MARK: Through the MCP server

    private func call(_ server: MCPServer, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "propose_action", "arguments": arguments],
        ]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try #require(server.handle(line: line))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    @Test("the MCP server acknowledges a valid proposal and changes nothing")
    func serverAcknowledges() throws {
        let store = try Store()
        let server = MCPServer(reader: store.writer, scope: .notes)
        let start = ProposeActionTool.isoFormatter().string(from: Date().addingTimeInterval(86_400))
        let valid = try call(server, ["kind": "createEvent", "title": "Dentist", "start": start])
        #expect(!valid.isError)
        #expect(valid.text.contains("awaiting the user's confirmation in Hushy"))
        #expect(valid.text.contains("Dentist"))
        let invalid = try call(server, ["kind": "createEvent", "title": "Dentist", "start": "next tuesday"])
        #expect(invalid.isError)
        #expect(invalid.text.contains("ISO-8601"))
        let unknown = try call(server, ["kind": "sendEmail", "title": "x"])
        #expect(unknown.isError)
        #expect(unknown.text.contains("Unknown kind"))
        // Nothing was recorded or created.
        let actions = try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actionRecord") }
        #expect(actions == 0)
        #expect(try store.recentActions().isEmpty)
    }

    @Test("the MCP server and propose_action never reference EventKit, Shortcuts or the executor")
    func noSideEffectDependencies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Sources/MurmurCore/MCP/MCPServer.swift", "Sources/MurmurCore/MCP/ProposeActionTool.swift",
            "Sources/murmur-mcp/main.swift",
        ]
        for file in files {
            // Code only: doc comments are allowed to explain what the tool doesn't do.
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for forbidden in ["import EventKit", "EKEventStore", "ActionExecutor", "ShortcutsActionBackend", "CalendarActionBackend", ".write {", "Process("] {
                #expect(!source.contains(forbidden), "\(file) mentions \(forbidden)")
            }
        }
    }
}

@Suite("Agent stream: proposed actions")
struct AgentStreamProposalTests {
    private func line(_ input: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Here you go."},{"type":"tool_use","id":"t9","name":"mcp__hushy__propose_action","input":"# + input + "}]}}"
    }

    @Test("a valid propose_action tool call becomes a card event")
    func parsesProposal() throws {
        let start = ProposeActionTool.isoFormatter().string(from: Date().addingTimeInterval(7200))
        let events = AgentStreamParser.events(fromLine: line(#"{"kind":"createReminder","title":"Send the deck","start":"\#(start)"}"#))
        #expect(events.count == 2)
        guard case .actionProposed(let action) = events.last else {
            Issue.record("expected a proposal, got \(events)")
            return
        }
        #expect(action.kind == .createReminder)
        #expect(action.title == "Send the deck")
        var reply = AgentReply()
        for event in events { reply.apply(event) }
        #expect(reply.proposedActions.map(\.title) == ["Send the deck"])
        #expect(reply.toolsUsed == ["mcp__hushy__propose_action"])
        #expect(reply.activity == "Preparing something for you to confirm…")
    }

    @Test("an invalid proposal, or the same name on another server, yields no card")
    func ignoresInvalid() {
        #expect(AgentStreamParser.events(fromLine: line(#"{"kind":"launchMissiles","title":"x"}"#)).count == 1)
        let otherServer = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"mcp__evil__propose_action","input":{"kind":"createReminder","title":"x"}}]}}"#
        #expect(!AgentStreamParser.events(fromLine: otherServer).contains { if case .actionProposed = $0 { true } else { false } })
    }

    @Test("tool summaries are past tense and de-duplicated")
    func toolSummary() {
        #expect(AgentReply.toolSummary(["mcp__hushy__search_notes", "mcp__hushy__get_note", "mcp__hushy__get_note"])
            == "Searched your notes · Read a note")
        #expect(AgentReply.toolSummary([]) == nil)
    }
}
