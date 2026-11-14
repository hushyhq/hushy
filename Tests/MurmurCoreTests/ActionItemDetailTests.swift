import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// Action items as fields (owner, task, due) next to the one-line strings. Every test uses a
/// temporary or in-memory database and invented people.
@Suite("Action item fields: storage, digest, rename, query", .timeLimit(.minutes(1)))
struct ActionItemDetailTests {
    static let details = [
        ActionItemDetail(owner: "Priya", task: "Send the revised budget", due: "by Friday"),
        ActionItemDetail(owner: "", task: "Book the room", due: ""),
        ActionItemDetail(owner: "Leo", task: "Draft the launch note", due: "next week"),
    ]

    static func note(_ title: String = "Weekly sync", at date: Date = Date(timeIntervalSince1970: 1_800_000_000),
                     lines: [String]? = nil, details: [ActionItemDetail]? = details,
                     status: Note.Status = .ready) -> Note {
        var note = Note(title: title, createdAt: date, transcript: "t", summary: "- Reviewed the plan", status: status)
        note.setActionItems(lines ?? (details ?? []).map(\.line), details: details)
        return note
    }

    // MARK: Line format

    @Test("a line is owner, task and due as the note has always written them")
    func lineFormat() {
        #expect(Self.details.map(\.line) == [
            "Priya: Send the revised budget — by Friday", "Book the room", "Leo: Draft the launch note — next week",
        ])
        // A due date the task already says is not repeated.
        #expect(ActionItemDetail(owner: "Ana", task: "Ship it by Friday", due: "Friday").line == "Ana: Ship it by Friday")
    }

    // MARK: Count and order invariant

    @Test("fields count only while they line up with the lines, in the same order")
    func invariant() {
        var note = Self.note()
        #expect(note.actionItemDetails == Self.details)
        #expect(note.actionItemDetail(at: 2)?.owner == "Leo")

        // Another count: the fields are gone, the lines stay. Never a wrong owner on a wrong item.
        note.actionItems.removeFirst()
        #expect(note.actionItemDetails == nil)
        #expect(note.actionItems.count == 2)
        #expect(note.actionItemDetail(at: 0) == .plain("Book the room"))

        // Fields of the wrong length are refused when set together with the lines.
        var other = Self.note(details: nil)
        other.setActionItems(["a", "b"], details: [ActionItemDetail(task: "a")])
        #expect(other.actionItemDetails == nil)
        #expect(other.actionItems == ["a", "b"])
        other.setActionItems(["a", "b"], details: [ActionItemDetail(task: "a"), ActionItemDetail(owner: "Ben", task: "b")])
        #expect(other.actionItemDetails?.map(\.owner) == ["", "Ben"])
    }

    @Test("a summary output drops fields that do not match its lines")
    func outputInvariant() {
        let bad = ExtractiveSummarizer.Output(title: "t", summary: "", actionItems: ["a"], actionDetails: Self.details)
        #expect(bad.actionDetails == nil)
        let good = ExtractiveSummarizer.Output(title: "t", summary: "", actionItems: ["a"], actionDetails: [ActionItemDetail(task: "a")])
        #expect(good.actionDetails?.count == 1)
    }

    @Test("a stored list of the wrong length reads as no fields, even straight from the database")
    func storedMismatch() throws {
        let store = try Store()
        let saved = try store.save(Self.note())
        let id = try #require(saved.id)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE note SET actionItems = ? WHERE id = ?", arguments: ["[\"only one\"]", id])
        }
        let note = try #require(try store.note(id: id))
        #expect(note.actionItems == ["only one"])
        #expect(note.actionItemDetails == nil)
    }

    // MARK: Migration

    @Test("a database with old notes migrates: lines, order and check-offs unchanged, no fields")
    func migrationKeepsOldNotes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t94-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hushy.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path)
        try Store.migrator.migrate(pool, upTo: "v17-note-calendar")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO note (id, title, createdAt, updatedAt, durationSeconds, transcript, summary, actionItems, status, source)
                VALUES (1, 'Old note', '2026-01-01 10:00:00', '2026-01-01 10:00:00', 60, 't', '- s',
                        '["Priya: Send the budget — by Friday","Book the room"]', 'ready', 'recording')
                """)
            try db.execute(sql: "INSERT INTO noteActionItem (noteId, itemIndex, isDone, updatedAt) VALUES (1, 1, 1, '2026-01-01 10:00:00')")
        }
        try pool.close()

        let store = try Store(url: url)
        let old = try #require(try store.note(id: 1))
        #expect(old.actionItems == ["Priya: Send the budget — by Friday", "Book the room"])
        #expect(old.actionItemDetails == nil)
        #expect(try store.doneActionItemIndexes(noteId: 1) == [1])
        let columns = try store.writer.read { db in try db.columns(in: "note").map(\.name) }
        #expect(columns.contains("actionItemDetails"))

        // A new note saves with fields and reads back with them; the old one is untouched.
        let saved = try store.save(Self.note("New"))
        let newId = try #require(saved.id)
        let reread = try #require(try store.note(id: newId))
        #expect(reread.actionItemDetails == Self.details)
        #expect(try store.note(id: 1)?.actionItemDetails == nil)
    }

    // MARK: Digest to note

    @Test("a digest carries owner and due into the note, with placeholders emptied")
    func digestToNote() {
        let digest = MeetingDigest(
            title: "Budget", keyPoints: ["Reviewed the budget"], decisions: [],
            actionItems: [
                DigestActionItem(owner: "Priya", task: "send the revised budget.", due: "by Friday"),
                DigestActionItem(owner: "TBD", task: "Book the room", due: "n/a"),
                DigestActionItem(owner: "Speaker 2", task: "Draft the launch note", due: ""),
            ])
        let output = NoteDigestMerge.output(digest, fallbackTitle: "Note")
        var note = Note(title: "t", status: .ready)
        note.setActionItems(from: output)
        #expect(note.actionItems == ["Priya: Send the revised budget — by Friday", "Book the room", "Speaker 2: Draft the launch note"])
        #expect(note.actionItemDetails == [
            ActionItemDetail(owner: "Priya", task: "Send the revised budget", due: "by Friday"),
            ActionItemDetail(owner: "", task: "Book the room", due: ""),
            ActionItemDetail(owner: "Speaker 2", task: "Draft the launch note", due: ""),
        ])
        // The strings are exactly what they were before the fields existed.
        #expect(note.actionItems == digest.actionItems.map(NoteDigestMerge.render))
    }

    @Test("the extractive fallback has lines and no fields")
    func extractiveHasNoFields() {
        let output = ExtractiveSummarizer.summarize("I will send the budget tomorrow. We talked about lunch for a while.", fallbackTitle: "t")
        #expect(output.actionDetails == nil)
    }

    // MARK: Speaker rename

    @Test("naming a speaker changes the owner field with the line")
    func renameUpdatesOwner() throws {
        var note = Self.note(lines: nil, details: [
            ActionItemDetail(owner: "Speaker 2", task: "Write the test plan", due: "Monday"),
            ActionItemDetail(owner: "Speaker 1", task: "Ask Speaker 2 for the numbers", due: ""),
        ])
        note.id = 1
        let renamed = try #require(DigestSpeakerRename.rewrite(note, from: ["Speaker 2"], to: "Leo"))
        #expect(renamed.actionItems == ["Leo: Write the test plan — Monday", "Speaker 1: Ask Leo for the numbers"])
        #expect(renamed.actionItemDetails?.map(\.owner) == ["Leo", "Speaker 1"])
        #expect(renamed.actionItemDetails?[1].task == "Ask Leo for the numbers")
        #expect(renamed.actionItemDetails?.map(\.due) == ["Monday", ""])
        // A rename that only touches the owner field still counts as a change.
        #expect(DigestSpeakerRename.rewrite(note, from: ["Speaker 9"], to: "Zoe") == nil)
    }

    @Test("a note without fields renames as before and gains none")
    func renameOldNote() throws {
        let old = Self.note(lines: ["Speaker 2: Write the plan"], details: nil)
        let renamed = try #require(DigestSpeakerRename.rewrite(old, from: ["Speaker 2"], to: "Leo"))
        #expect(renamed.actionItems == ["Leo: Write the plan"])
        #expect(renamed.actionItemDetails == nil)
    }

    @Test("in the store, a rename and a merge update owners and check-offs stay on their items")
    func storeRenameKeepsDone() throws {
        let store = try Store()
        let saved = try store.save(Self.note(lines: nil, details: [
            ActionItemDetail(owner: "Speaker 2", task: "Write the test plan", due: ""),
            ActionItemDetail(owner: "Speaker 1", task: "Book the room", due: "Friday"),
            ActionItemDetail(owner: "Speaker 2", task: "Email the notes", due: ""),
        ]))
        let id = try #require(saved.id)
        let speakers = try store.replaceSpeakerSegments(
            noteId: id, speakers: [NoteSpeaker(noteId: id, label: "Speaker 1"), NoteSpeaker(noteId: id, label: "Speaker 2")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "a")),
                       (1, AlignedSegment(speakerLabel: "S2", start: 1, end: 2, text: "b"))])
        try store.setActionItemDone(noteId: id, itemIndex: 1, isDone: true)
        let first = try #require(speakers[0].id), second = try #require(speakers[1].id)

        try store.renameSpeakerUpdatingDigest(id: second, to: "Leo")
        var note = try #require(try store.note(id: id))
        #expect(note.actionItemDetails?.map(\.owner) == ["Leo", "Speaker 1", "Leo"])
        #expect(note.actionItems[0] == "Leo: Write the test plan")
        #expect(try store.doneActionItemIndexes(noteId: id) == [1])
        #expect(note.actionItemDetails?[1].task == "Book the room")  // the checked item is still Book the room

        try store.mergeSpeakersUpdatingDigest(sourceId: first, intoTargetId: second)
        note = try #require(try store.note(id: id))
        #expect(note.actionItemDetails?.map(\.owner) == ["Leo", "Leo", "Leo"])
        #expect(try store.doneActionItemIndexes(noteId: id) == [1])
    }

    // MARK: Re-summary keeps fields with their lines

    @Test("merging a labelled digest keeps a checked item on its task, with its fields")
    func mergeKeepsFields() {
        let items = ["Priya: Send the revised budget — by Friday", "Book the room"]
        let current = Self.details.prefix(2).map { $0 }
        let labelled = [
            ActionItemDetail(owner: "Priya", task: "Send the budget to finance", due: "Friday"),
            ActionItemDetail(owner: "Leo", task: "Draft the launch note", due: ""),
        ]
        // Item 1 (Book the room) is checked and the new digest does not have it: it is kept at the end.
        let merged = DiarizedDigest.mergeList(
            items, details: current, done: [1], labelled: labelled.map(\.line), labelledDetails: labelled)
        #expect(merged.items.count == 3)
        #expect(merged.details?.count == 3)
        #expect(merged.items[2] == "Book the room")
        #expect(merged.details?[2] == current[1])
        #expect(merged.done == [2])
        // Labelled lines without fields: the lines are merged as before and no fields are claimed.
        let plain = DiarizedDigest.mergeList(items, details: current, done: [1], labelled: ["x"], labelledDetails: nil)
        #expect(plain.details == nil)
        #expect(plain.items == ["x", "Book the room"])
        // A kept item that never had fields cannot be given an owner: the merged note keeps lines only,
        // never a mix of known owners and guesses.
        let fromOld = DiarizedDigest.mergeList(items, details: nil, done: [1], labelled: labelled.map(\.line), labelledDetails: labelled)
        #expect(fromOld.details == nil)
        #expect(fromOld.items == labelled.map(\.line) + ["Book the room"])
        #expect(fromOld.done == [2])
        // A checked item that matches a labelled one needs nothing appended, so the fields survive.
        let matched = DiarizedDigest.mergeList(items, details: nil, done: [0], labelled: labelled.map(\.line), labelledDetails: labelled)
        #expect(matched.details == labelled)
        #expect(matched.done == [0])
    }

    // MARK: Open items query

    @Test("open items: done excluded, owner filter, newest note first, items in order")
    func openItems() throws {
        let store = try Store()
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let oldest = try store.save(Self.note("Oldest", at: base))
        let newest = try store.save(Self.note("Newest", at: base + 2 * day))
        _ = try store.save(Self.note("Plain", at: base + day, lines: ["Priya: Chase the vendor", "Book the hall"], details: nil))
        _ = try store.save(Self.note("Failed", at: base + 3 * day, status: .failed))
        let newestId = try #require(newest.id)
        try store.setActionItemDone(noteId: newestId, itemIndex: 0, isDone: true)

        let all = try store.openActionItems()
        #expect(all.map(\.noteTitle) == ["Newest", "Newest", "Plain", "Plain", "Oldest", "Oldest", "Oldest"])
        #expect(all.map(\.itemIndex) == [1, 2, 0, 1, 0, 1, 2])
        #expect(all.first?.detail == Self.details[1])
        #expect(all.first?.line == "Book the room")
        #expect(all.first?.noteId == newestId)
        _ = oldest

        // Owner filter: the field only; the old note's sentence "Priya: Chase…" is not guessed at.
        let priya = try store.openActionItems(owner: " priya ")
        #expect(priya.map(\.noteTitle) == ["Oldest"])
        #expect(priya.first?.detail.due == "by Friday")
        #expect(try store.openActionItems(owner: "Nobody").isEmpty)

        #expect(try store.openActionItems(limit: 3).count == 3)
    }
}
