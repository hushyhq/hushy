import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// With meetings private (`FeatureFlags.meetings`, TRY-98) the connector must not read notes, because the
/// Settings copy says what AI apps can read. The server takes the flag as an argument so both are testable here.
@Suite("MCP notes tools with meetings private")
struct MCPNotesPrivateTests {
    private func call(_ server: MCPServer, _ json: String) -> String { server.handle(line: json) ?? "" }

    @Test("the notes tools are not listed, named or callable, and the rest stay")
    func notesToolsGone() throws {
        let server = MCPServer(reader: try DatabaseQueue(), scope: .notes, exposesNotes: false)
        let list = call(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        for name in MCPServer.noteToolNames { #expect(!list.contains(name), "\(name) listed") }
        #expect(list.contains("propose_action"))
        #expect(call(MCPServer(reader: try DatabaseQueue(), exposesNotes: false), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).contains("get_insights"))
        for name in MCPServer.noteToolNames {
            let reply = call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\#(name)","arguments":{"query":"x","id":1}}}"#)
            #expect(reply.contains("Unknown tool"), "\(name) callable")
        }
        let names = MCPServer.toolNames(for: .all, exposesNotes: false)
        #expect(MCPServer.noteToolNames.isDisjoint(with: names))
        #expect(MCPServer.noteToolNames.isDisjoint(with: MCPServer.toolNames(for: .notes, exposesNotes: false)))
        #expect(!call(server, #"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}"#).contains("recorded notes"))
    }

    @Test("with meetings on the notes tools are as they were")
    func notesToolsKept() throws {
        let server = MCPServer(reader: try DatabaseQueue(), scope: .notes, exposesNotes: true)
        let list = call(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        for name in MCPServer.noteToolNames { #expect(list.contains(name)) }
        #expect(MCPServer.toolNames(for: .notes, exposesNotes: true).count == 4 + MeetingMemoryTools.names.count)
        #expect(Set(MCPServer.toolNames) == MCPServer.allToolNames.union(MCPServer.notesToolNames))
        #expect(MCPServer.noteToolNames.isSubset(of: MCPServer.notesToolNames))
    }

    @Test("the default follows the flag, which is on in a debug build")
    func defaultFollowsFlag() throws {
        let server = MCPServer(reader: try DatabaseQueue())
        #expect(server.exposesNotes == FeatureFlags.meetings)
    }
}
