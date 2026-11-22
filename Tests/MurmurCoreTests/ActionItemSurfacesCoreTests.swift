import Foundation
import Testing
@testable import MurmurCore

/// The core half of Task 95: the shared secondary-text format, who "mine" is, the re-summary rule
/// that never mixes fields with guesses, and the MCP `get_note` text. Invented data only.
@Suite("Action item surfaces (core)", .timeLimit(.minutes(1)))
struct ActionItemSurfacesCoreTests {
    @Test("secondary text is owner and due, only what is there")
    func secondary() {
        #expect(ActionItemDetail(owner: "Priya", task: "t", due: "by Friday").secondaryText == "Priya · by Friday")
        #expect(ActionItemDetail(owner: "Priya", task: "t").secondaryText == "Priya")
        #expect(ActionItemDetail(task: "t", due: "next week").secondaryText == "next week")
        #expect(ActionItemDetail(task: "t").secondaryText == "")
    }

    @Test("an owner is mine only when the field names me; empty and other people are not")
    func ownership() {
        let mine = ["You", "Sam"]
        #expect(ActionItemDetail(owner: "You", task: "t").isOwned(by: mine))
        #expect(ActionItemDetail(owner: " sam ", task: "t").isOwned(by: mine))
        #expect(!ActionItemDetail(owner: "", task: "Sam to send it").isOwned(by: mine))
        #expect(!ActionItemDetail(owner: "Priya", task: "t").isOwned(by: mine))
        #expect(!ActionItemDetail(owner: "Samantha", task: "t").isOwned(by: mine))
        #expect(!ActionItemDetail(owner: "You", task: "t").isOwned(by: []))
    }

    @Test("MCP get_note marks checked-off items and keeps owner and due in the line")
    func mcpGetNote() throws {
        let store = try Store()
        var note = Note(title: "Weekly sync", createdAt: Date(timeIntervalSince1970: 1_800_000_000), transcript: "We met.", status: .ready)
        let details = [
            ActionItemDetail(owner: "Priya", task: "Send the revised budget", due: "by Friday"),
            ActionItemDetail(task: "Book the room"),
        ]
        note.setActionItems(details.map(\.line), details: details)
        let saved = try store.save(note)
        let id = try #require(saved.id)
        try store.setActionItemDone(noteId: id, itemIndex: 1, isDone: true)

        let server = MCPServer(reader: store.writer, scope: .notes, now: { Date(timeIntervalSince1970: 1_800_000_100) })
        let line = try #require(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_note","arguments":{"id":\#(id)}}}"#))
        let response = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let content = (response["result"] as? [String: Any])?["content"] as? [[String: Any]]
        let text = try #require(content?.first?["text"] as? String)
        #expect(text.contains("- [ ] Priya: Send the revised budget — by Friday\n- [x] Book the room"))
        // Everything it had before is still there.
        #expect(text.contains("title: \"Weekly sync\""))
        #expect(text.contains("## Transcript"))
    }
}
