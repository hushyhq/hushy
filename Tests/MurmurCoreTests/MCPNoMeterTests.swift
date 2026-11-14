import Foundation
import Testing
@testable import MurmurCore

/// Launch decision 5: meetings are free, with no monthly limit and no 30-day lock. A Free user (no Pro
/// snapshot in the store) reads, lists and searches every note through the MCP helper, however old.
@Suite("MCP has no meeting meter")
struct MCPNoMeterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func makeStore() throws -> (Store, oldID: Int64) {
        let store = try Store()
        var fresh = Note(title: "Fresh launch plan", createdAt: now.addingTimeInterval(-3_600),
                         transcript: "We will launch on Friday.")
        fresh.status = .ready
        var old = Note(title: "Old launch plan", createdAt: now.addingTimeInterval(-400 * 86_400),
                       transcript: "We launched last year.")
        old.status = .ready
        try store.save(fresh)
        old = try store.save(old)
        return (store, old.id!)
    }

    func text(_ server: MCPServer, _ name: String, _ arguments: String) throws -> (text: String, isError: Bool) {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
        let line = try #require(server.handle(line: json))
        let response = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = response["result"] as? [String: Any]
        let content = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (content, result?["isError"] as? Bool == true || response["error"] != nil)
    }

    @Test("on Free, list_notes, search_notes and get_note return a note over a year old")
    func oldNotesAreReadable() throws {
        let (store, oldID) = try makeStore()
        let server = MCPServer(reader: store.writer, scope: .notes, now: { now })

        let list = try text(server, "list_notes", "{}")
        #expect(list.text.contains("Fresh launch plan") && list.text.contains("Old launch plan"))
        let search = try text(server, "search_notes", #"{"query":"launch"}"#)
        #expect(search.text.contains("Old launch plan"))
        let get = try text(server, "get_note", #"{"id":\#(oldID)}"#)
        #expect(!get.isError)
        #expect(get.text.contains("We launched last year"))
    }

    @Test("the store lists and searches every note: no date cutoff exists")
    func storeHasNoCutoff() throws {
        let (store, _) = try makeStore()
        #expect(try store.notes().map(\.title) == ["Fresh launch plan", "Old launch plan"])
        #expect(Set(try store.searchNotes("launch").map(\.title)) == ["Fresh launch plan", "Old launch plan"])
    }

    @Test("many call-detected meetings in one month are all kept and listed")
    func manyMeetingsInOneMonth() throws {
        let store = try Store()
        for index in 0..<12 {
            var note = Note(title: "Call \(index)", createdAt: now.addingTimeInterval(Double(-index) * 3_600),
                            transcript: "weekly sync")
            note.status = .ready
            note.meetingApp = .zoom
            try store.save(note)
        }
        #expect(try store.notes().count == 12)
    }

    @Test("Entitlements exposes no meetings or note-history feature")
    func noMeetingFeature() {
        let names = ProFeature.allCases.map(\.rawValue)
        #expect(!names.contains { $0.lowercased().contains("meeting") || $0.lowercased().contains("history") })
        #expect(ProFeature.allCases.allSatisfy { $0.isFree }, "nothing is gated (founder, 2026-11-11)")
    }
}
