import Foundation
import Testing
@testable import MurmurCore

@Suite("Speaker rename carried into the digest")
struct DigestSpeakerRenameTests {
    static let note = Note(
        id: 1, title: "Speaker 1 and the plan", transcript: "t",
        summary: "- Speaker 1 wants the launch moved\n- Decided: Speaker 12 owns QA",
        actionItems: ["Speaker 1: Send the deck to Speaker 3 — Friday", "Speaker 12: Book the room", "Ben: Draft the plan"],
        status: .ready)

    @Test("whole-word label occurrences change; longer labels and the title don't")
    func rewrite() throws {
        let renamed = try #require(DigestSpeakerRename.rewrite(Self.note, from: ["Speaker 1"], to: "Grace"))
        #expect(renamed.summary == "- Grace wants the launch moved\n- Decided: Speaker 12 owns QA")
        #expect(renamed.actionItems == ["Grace: Send the deck to Speaker 3 — Friday", "Speaker 12: Book the room", "Ben: Draft the plan"])
        #expect(renamed.title == Self.note.title)
    }

    @Test("renaming again replaces the previous name; clearing writes the label back; no-ops are nil")
    func renameAgain() throws {
        let first = try #require(DigestSpeakerRename.rewrite(Self.note, from: ["Speaker 3"], to: "Priya"))
        let second = try #require(DigestSpeakerRename.rewrite(first, from: ["Speaker 3", "Priya"], to: "Priya Shah"))
        #expect(second.actionItems[0] == "Speaker 1: Send the deck to Priya Shah — Friday")
        let cleared = try #require(DigestSpeakerRename.rewrite(second, from: ["Speaker 3", "Priya Shah"], to: "Speaker 3"))
        #expect(cleared.actionItems[0] == Self.note.actionItems[0])
        #expect(DigestSpeakerRename.rewrite(Self.note, from: ["Speaker 9"], to: "Zoe") == nil)
        #expect(DigestSpeakerRename.rewrite(Self.note, from: ["Speaker 1"], to: "  ") == nil)
    }

    @Test("names with regex characters are replaced literally")
    func literal() throws {
        let renamed = try #require(DigestSpeakerRename.rewrite(Self.note, from: ["Speaker 12"], to: "Dr. O'Neil ($1)"))
        #expect(renamed.actionItems[1] == "Dr. O'Neil ($1): Book the room")
    }

    @Test("the store renames the speaker and the digest in one step; check-offs stay on their items")
    func store() throws {
        let store = try Store()
        let saved = try store.save(Note(title: "T", transcript: "t", summary: "- Speaker 2 owns QA",
                                        actionItems: ["Speaker 2: Write the test plan", "Speaker 1: Book the room"], status: .ready))
        let id = try #require(saved.id)
        let speakers = try store.replaceSpeakerSegments(
            noteId: id, speakers: [NoteSpeaker(noteId: id, label: "Speaker 1"), NoteSpeaker(noteId: id, label: "Speaker 2")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "a")),
                       (1, AlignedSegment(speakerLabel: "S2", start: 1, end: 2, text: "b"))])
        try store.setActionItemDone(noteId: id, itemIndex: 0, isDone: true)
        let second = try #require(speakers[1].id), first = try #require(speakers[0].id)

        try store.renameSpeakerUpdatingDigest(id: second, to: "Leo")
        var note = try #require(try store.note(id: id))
        #expect(note.actionItems == ["Leo: Write the test plan", "Speaker 1: Book the room"])
        #expect(note.summary == "- Leo owns QA")
        #expect(try store.doneActionItemIndexes(noteId: id) == [0])

        try store.mergeSpeakersUpdatingDigest(sourceId: first, intoTargetId: second)
        note = try #require(try store.note(id: id))
        #expect(note.actionItems == ["Leo: Write the test plan", "Leo: Book the room"])

        try store.renameSpeakerUpdatingDigest(id: second, to: "")
        note = try #require(try store.note(id: id))
        #expect(note.actionItems == ["Speaker 2: Write the test plan", "Speaker 2: Book the room"])
    }

    @Test("a digest written after a rename gets the new name (rename during the re-summary)")
    func renameDuringResummary() throws {
        let store = try Store()
        let saved = try store.save(Note(title: "T", transcript: "t", summary: "- Plan", actionItems: ["Book the room"], status: .ready))
        let id = try #require(saved.id)
        let speakers = try store.replaceSpeakerSegments(
            noteId: id, speakers: [NoteSpeaker(noteId: id, label: "Speaker 1"), NoteSpeaker(noteId: id, label: "Speaker 2")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "a"))])
        try store.renameSpeakerUpdatingDigest(id: try #require(speakers[1].id), to: "Leo")
        try store.updateNoteDigest(id: id) { note, done in
            var labelled = note
            labelled.actionItems = ["Speaker 2: Book the room", "Speaker 1: Send the deck"]
            return (labelled, done)
        }
        #expect(try store.note(id: id)?.actionItems == ["Leo: Book the room", "Speaker 1: Send the deck"])
    }
}
