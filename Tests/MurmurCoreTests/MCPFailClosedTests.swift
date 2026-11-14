import Foundation
import Testing
@testable import MurmurCore

/// Launch rule (decisions-final #8): no dictation, note or meeting text leaves through the helper that
/// external AI apps launch, and no tool claims a confirmation card that does not exist.
@Suite("MCP fails closed")
struct MCPFailClosedTests {
    static let secret = "my card number is 4111 1111 1111 1111"
    static let removedHistory = ["search_history", "recent_dictations"]

    private func makeServer(scope: MCPServer.Scope, exposesNotes: Bool = true) throws -> MCPServer {
        let store = try Store()
        try store.save(Dictation(rawText: "", text: Self.secret, appName: "Slack", durationSeconds: 3))
        var note = Note(title: "Launch plan", transcript: "We launch on Friday. \(Self.secret)")
        note.summary = "Launch Friday."
        note.status = .ready
        try store.save(note)
        return MCPServer(reader: store.writer, scope: scope, exposesNotes: exposesNotes)
    }

    private func result(_ server: MCPServer, _ json: String) throws -> (text: String, isError: Bool) {
        let line = try #require(server.handle(line: json))
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    private func call(_ server: MCPServer, _ name: String) throws -> (text: String, isError: Bool) {
        try result(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":{"query":"card","id":1,"title":"x"}}}"#)
    }

    @Test("no scope lists a history-read tool")
    func historyToolsAreNotListed() throws {
        for scope in [MCPServer.Scope.all, .notes] {
            for exposesNotes in [true, false] {
                let names = MCPServer.toolNames(for: scope, exposesNotes: exposesNotes)
                for removed in Self.removedHistory { #expect(!names.contains(removed), "\(scope) lists \(removed)") }
                let list = try #require(try makeServer(scope: scope, exposesNotes: exposesNotes).handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
                for removed in Self.removedHistory { #expect(!list.contains(removed)) }
            }
        }
        for removed in Self.removedHistory { #expect(!MCPServer.toolNames.contains(removed)) }
    }

    @Test("a call to a removed history tool is a clear error and returns no dictation text")
    func removedHistoryToolsRefuse() throws {
        for scope in [MCPServer.Scope.all, .notes] {
            let server = try makeServer(scope: scope)
            for removed in Self.removedHistory {
                let reply = try call(server, removed)
                #expect(reply.isError)
                #expect(reply.text.contains("Unknown tool: \(removed)"))
                #expect(reply.text.contains("removed"))
                #expect(!reply.text.contains("4111"))
            }
        }
    }

    @Test("what external apps get lists only usage totals: no dictation, note, meeting or proposal tool")
    func allScopeIsUsageTotalsOnly() throws {
        let names = MCPServer.toolNames(for: .all, exposesNotes: true)
        #expect(names == ["get_insights"])
        let server = try makeServer(scope: .all)
        for name in MCPServer.noteToolNames.union(Self.removedHistory) {
            let reply = try call(server, name)
            #expect(reply.isError, "\(name) callable in .all")
            #expect(!reply.text.contains("4111") && !reply.text.contains("Launch plan"))
        }
        let insights = try call(server, "get_insights")
        #expect(!insights.isError)
        #expect(!insights.text.contains("4111"))
    }

    @Test("every tool external apps get answers without dictation, note or meeting text; meeting memory is the Assistant's only")
    func allScopeToolsYieldNoPersonalText() throws {
        let store = try Store()
        try store.save(Dictation(rawText: Self.secret, text: Self.secret, appName: "Slack", durationSeconds: 3))
        var meeting = Note(title: "Acme sync", transcript: "Priya: \(Self.secret)")
        meeting.summary = "- Decided: \(Self.secret)"
        meeting.actionItems = ["Priya will send \(Self.secret)"]
        meeting.status = .ready
        try store.save(meeting)
        let assistant = MCPServer(reader: store.writer, scope: .notes, exposesNotes: true)
        #expect(try call(assistant, "meeting_rows").text.contains("4111"), "the seeded meeting is readable where it may be")

        #expect(MCPServer.allToolNames.isDisjoint(with: MCPServer.noteToolNames.union(MeetingMemoryTools.names)))
        #expect(MeetingMemoryTools.names.isSubset(of: MCPServer.notesToolNames))
        let external = MCPServer(reader: store.writer, scope: .all, exposesNotes: true)
        for name in MCPServer.allToolNames.union(MCPServer.toolNames(for: .all, exposesNotes: true)) {
            let reply = try call(external, name)
            #expect(!reply.text.contains("4111"), "\(name) returns personal text to an external app")
        }
        for name in MeetingMemoryTools.names {
            let reply = try call(external, name)
            #expect(reply.isError && !reply.text.contains("4111"), "\(name) callable in .all")
        }
    }

    @Test("no tool says a confirmation is awaiting in Hushy unless Hushy can show it")
    func proposalToolsAreHonest() throws {
        #expect(MCPServer.toolNames(for: .all, exposesNotes: true).allSatisfy { !$0.hasPrefix("propose_") })
        let assistant = MCPServer.toolNames(for: .notes, exposesNotes: true)
        #expect(Set(assistant) == Set(["search_notes", "list_notes", "get_note", ProposeActionTool.name]).union(MeetingMemoryTools.names))
        for name in ConnectedProposalTools.names {
            #expect(!assistant.contains(name))
            #expect(!MCPServer.toolNames.contains(name))
            for scope in [MCPServer.Scope.all, .notes] {
                let reply = try call(try makeServer(scope: scope), name)
                #expect(reply.isError)
                #expect(reply.text.contains("nothing was done"))
                #expect(!reply.text.contains("awaiting"))
            }
        }
        let external = try call(try makeServer(scope: .all), ProposeActionTool.name)
        #expect(external.isError && external.text.contains("nothing was done"))
    }

    @Test("the server's instructions do not promise history or confirmation to an external app")
    func instructionsAreTruthful() throws {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let external = try #require(try makeServer(scope: .all).handle(line: initialize))
        #expect(!external.contains("dictation history"))
        #expect(!external.contains("confirms it"))
        #expect(!external.contains("propose"))
    }
}
