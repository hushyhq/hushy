import Foundation
import Testing
@testable import MurmurCore

/// How action items with owners and due dates read in the shared recap and the Markdown export,
/// with and without fields, and with check-offs. Invented notes only.
@Suite("Action items in the recap and Markdown export", .timeLimit(.minutes(1)))
struct ActionItemExportTests {
    static let details = [
        ActionItemDetail(owner: "Priya", task: "Send the revised budget", due: "by Friday"),
        ActionItemDetail(owner: "", task: "Book the room", due: ""),
        ActionItemDetail(owner: "Leo", task: "Draft the launch note", due: ""),
    ]

    private func note(withFields: Bool) -> Note {
        var note = Note(
            id: 5, title: "Weekly sync", createdAt: Date(timeIntervalSince1970: 1_790_000_000), durationSeconds: 600,
            transcript: "We met.", summary: "- Reviewed the plan", status: .ready)
        note.setActionItems(Self.details.map(\.line), details: withFields ? Self.details : nil)
        return note
    }

    private func recap(_ note: Note, done: Set<Int> = []) throws -> MeetingRecap {
        try #require(MeetingRecap.make(
            from: note, doneItems: done, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!))
    }

    @Test("recap lines carry owner and due when there are any, and nothing extra when there are none")
    func recapLines() throws {
        let text = try recap(note(withFields: true)).plainText
        #expect(text.contains("""
            Action items
            - Priya: Send the revised budget — by Friday
            - Book the room
            - Leo: Draft the launch note
            """))
        #expect(try recap(note(withFields: true)).markdown.contains("""
            - [ ] Priya: Send the revised budget — by Friday
            - [ ] Book the room
            - [ ] Leo: Draft the launch note
            """))
    }

    @Test("an old note without fields gives the same lines")
    func recapOldNote() throws {
        let withFields = try recap(note(withFields: true))
        let old = try recap(note(withFields: false))
        #expect(old.plainText == withFields.plainText)
        #expect(old.markdown == withFields.markdown)
        #expect(old.actionDetails == nil)
    }

    @Test("a checked-off item is marked in every format, on the right item")
    func recapDone() throws {
        let made = try recap(note(withFields: true), done: [1])
        #expect(made.plainText.contains("- Book the room (done)"))
        #expect(!made.plainText.contains("Priya: Send the revised budget — by Friday (done)"))
        #expect(made.markdown.contains("- [x] Book the room"))
        #expect(made.markdown.contains("- [ ] Leo: Draft the launch note"))
        #expect(made.html.contains("<li><s>Book the room</s> (done)</li>"))
    }

    @Test("check-offs stay on their item when an empty item is skipped")
    func doneWithEmptyItem() throws {
        var sparse = note(withFields: false)
        sparse.setActionItems(["  ", "Book the room", "Draft the note"], details: nil)
        let made = try recap(sparse, done: [2])
        #expect(made.actionItems == ["Book the room", "Draft the note"])
        #expect(made.actionDone == [false, true])
    }

    @Test("html puts the owner in bold only when the note has it as a field, and escapes it")
    func recapHtml() throws {
        #expect(try recap(note(withFields: true)).html.contains("<li><strong>Priya</strong>: Send the revised budget — by Friday</li>"))
        #expect(try recap(note(withFields: false)).html.contains("<li>Priya: Send the revised budget — by Friday</li>"))
        var hostile = note(withFields: false)
        hostile.setActionItems(["<b>Eve</b> & co: Do it"], details: [ActionItemDetail(owner: "<b>Eve</b> & co", task: "Do it")])
        let html = try recap(hostile).html
        #expect(html.contains("<strong>&lt;b&gt;Eve&lt;/b&gt; &amp; co</strong>: Do it"))
        #expect(!html.contains("<b>Eve"))
    }

    @Test("Markdown export: lines as before, done items checked, old notes unchanged")
    func markdownExport() {
        let withFields = MarkdownExporter.markdown(for: note(withFields: true), done: [0])
        #expect(withFields.contains("""
            ## Action items

            - [x] Priya: Send the revised budget — by Friday
            - [ ] Book the room
            - [ ] Leo: Draft the launch note
            """))
        let old = Note(id: 3, title: "Old", transcript: "t", summary: "s", actionItems: ["Priya: Send it — Friday", "Book the room"])
        #expect(MarkdownExporter.markdown(for: old).contains("- [ ] Priya: Send it — Friday\n- [ ] Book the room"))
        #expect(MarkdownExporter.markdown(for: old, done: [1]).contains("- [ ] Priya: Send it — Friday\n- [x] Book the room"))
    }
}
