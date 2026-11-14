import Foundation
import MurmurCore
import Testing

@testable import Murmur

/// Where the app lists action items outside the note: the Assistant's open items (the card that
/// used to be on Home) and the Apple Notes export. Invented notes; Apple Notes goes through the
/// fake scripter only, never AppleScript.
@MainActor
@Suite("Action item surfaces", .timeLimit(.minutes(1)))
struct ActionItemSurfacesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func note(
        _ id: Int64, _ title: String, ageDays: Double, _ details: [ActionItemDetail]?, lines: [String] = []
    ) -> Note {
        var note = Note(
            id: id, title: title, createdAt: now.addingTimeInterval(-ageDays * 86_400), transcript: "t", status: .ready)
        note.setActionItems(details?.map(\.line) ?? lines, details: details)
        return note
    }

    private func items(
        _ notes: [Note], done: Set<String> = [], mine: [String] = [], limit: Int = 6
    ) -> [OpenActionItems.Item] {
        OpenActionItems.select(
            notes: notes, isDone: { done.contains("\($0.id ?? 0)-\($1)") }, 
            mine: mine, limit: limit)
    }

    private var fielded: [Note] {
        [
            note(1, "Weekly sync", ageDays: 0, [
                ActionItemDetail(owner: "Priya", task: "Send the revised budget", due: "by Friday"),
                ActionItemDetail(owner: "You", task: "Book the room"),
            ]),
            note(2, "Old note", ageDays: 2, nil, lines: ["Leo: Draft the launch note — next week"]),
            note(3, "Planning", ageDays: 3, [ActionItemDetail(owner: "Sam", task: "Order the cake", due: "Monday")]),
        ]
    }

    @Test("a fielded item shows the task and, under it, owner and due; an old note shows its line")
    func rows() {
        let rows = items(fielded)
        #expect(rows.map(\.text) == [
            "Send the revised budget", "Book the room", "Leo: Draft the launch note — next week", "Order the cake",
        ])
        #expect(rows.map(\.secondary) == ["Priya · by Friday", "You", "", "Sam · Monday"])
        #expect(rows.map(\.id) == ["1-0", "1-1", "2-0", "3-0"])
    }

    @Test("done items are left out, on the right item, and the limit keeps the newest first")
    func doneAndLimit() {
        let rows = items(fielded, done: ["1-0"])
        #expect(rows.map(\.text).first == "Book the room")
        #expect(rows.count == 3)
        #expect(items(fielded, limit: 2).map(\.id) == ["1-0", "1-1"])
    }

    @Test("a note older than 30 days still lists its open items")
    func oldNotesAreNotLocked() {
        let old = [note(9, "Ancient", ageDays: 60, [ActionItemDetail(task: "Old task")])]
        #expect(items(old).map(\.text) == ["Old task"])
    }

    @Test("mine leads with the user's own items, keeping order within each group; nothing else changes")
    func mineFirst() {
        let rows = items(fielded, mine: OpenActionItems.myNames(userName: "Sam"))
        #expect(rows.map(\.id) == ["1-1", "3-0", "1-0", "2-0"])
        // Without mine, or with nobody matching, the order is the plain newest-first one.
        #expect(items(fielded, mine: []).map(\.id) == ["1-0", "1-1", "2-0", "3-0"])
        #expect(items(fielded, mine: ["Nobody"]).map(\.id) == ["1-0", "1-1", "2-0", "3-0"])
        // An old note's sentence is never read for a name: "Leo:" in the line does not make it Leo's.
        #expect(items(fielded, mine: ["Leo"]).map(\.id) == ["1-0", "1-1", "2-0", "3-0"])
        // The limit applies after the reorder.
        #expect(items(fielded, mine: ["You"], limit: 1).map(\.id) == ["1-1"])
    }

    @Test("my names are You and the Settings name, trimmed, without empties")
    func names() {
        #expect(OpenActionItems.myNames(userName: " Sam ") == ["You", "Sam"])
        #expect(OpenActionItems.myNames(userName: "  ") == ["You"])
        #expect(OpenActionItems.myNames(userName: nil) == ["You"])
    }

    // MARK: Apple Notes

    @Test("Apple Notes gets the same one-line items as the recap, with done marked and text escaped")
    func appleNotesHtml() {
        var note = note(4, "Sync <1>", ageDays: 0, [
            ActionItemDetail(owner: "Priya", task: "Send the budget & slides", due: "by Friday"),
            ActionItemDetail(task: "Book the room"),
        ])
        note.summary = "- Reviewed"
        let html = AppleNotesExporter.html(note, done: [1])
        #expect(html.contains("<h2>Action items</h2><ul><li>Priya: Send the budget &amp; slides — by Friday</li><li>Book the room (done)</li></ul>"))
        #expect(html.contains("<h1>Sync &lt;1&gt;</h1>"))
        // An old note exports its lines as before.
        let old = self.note(5, "Old", ageDays: 1, nil, lines: ["Leo: Draft it"])
        #expect(AppleNotesExporter.html(old).contains("<ul><li>Leo: Draft it</li></ul>"))
    }

    @Test("export sends the done-marked body through the scripter and never past it")
    func appleNotesExport() throws {
        let fake = FakeAppleNotesScripter()
        let note = note(6, "Sync", ageDays: 0, [ActionItemDetail(owner: "Priya", task: "Send it", due: "Friday")])
        try AppleNotesExporter.export(note, done: [0], using: fake)
        #expect(fake.sources.count == 1)
        #expect(fake.sources[0].contains("Priya: Send it — Friday (done)"))
    }
}
