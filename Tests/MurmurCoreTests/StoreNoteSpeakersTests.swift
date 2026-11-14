import Foundation
import Testing
@testable import MurmurCore

/// Covers the note speakers/segments storage API added in migration "v6-note-speakers": atomic
/// replace, fetch-with-speaker-join, rename, and merge. Uses an in-memory store, never the
/// user's real database — same convention as `StoreNoteFoldersTests`.
@Suite("Store note speakers")
struct StoreNoteSpeakersTests {
    private func makeNote(_ store: Store) throws -> Int64 {
        let note = try store.save(Note(title: "Test note", transcript: "hello there hey back", status: .ready))
        return try #require(note.id)
    }

    @Test("replaceSpeakerSegments saves speakers and segments, linked by array index")
    func replaceSavesLinkedRows() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let speakers = [
            NoteSpeaker(noteId: noteId, label: "Speaker 1"),
            NoteSpeaker(noteId: noteId, label: "Speaker 2"),
        ]
        let segments: [(speakerIndex: Int?, segment: AlignedSegment)] = [
            (0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "hello there")),
            (1, AlignedSegment(speakerLabel: "S2", start: 1, end: 2, text: "hey back")),
        ]
        let inserted = try store.replaceSpeakerSegments(noteId: noteId, speakers: speakers, segments: segments)
        #expect(inserted.count == 2)
        #expect(inserted.allSatisfy { $0.id != nil })

        let fetched = try store.noteSegments(noteId: noteId)
        #expect(fetched.count == 2)
        #expect(fetched[0].segment.text == "hello there")
        #expect(fetched[0].speaker?.label == "Speaker 1")
        #expect(fetched[1].segment.text == "hey back")
        #expect(fetched[1].speaker?.label == "Speaker 2")
    }

    @Test("replaceSpeakerSegments is atomic: a second call fully replaces the first")
    func replaceIsAtomic() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        _ = try store.replaceSpeakerSegments(
            noteId: noteId, speakers: [NoteSpeaker(noteId: noteId, label: "Speaker 1")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "old"))])
        _ = try store.replaceSpeakerSegments(
            noteId: noteId, speakers: [NoteSpeaker(noteId: noteId, label: "Speaker 1")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "new"))])

        let fetched = try store.noteSegments(noteId: noteId)
        #expect(fetched.count == 1)
        #expect(fetched[0].segment.text == "new")
    }

    @Test("hasSpeakerSegments reflects whether a note has saved segments")
    func hasSpeakerSegmentsReflectsState() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        #expect(try store.hasSpeakerSegments(noteId: noteId) == false)
        _ = try store.replaceSpeakerSegments(
            noteId: noteId, speakers: [NoteSpeaker(noteId: noteId, label: "Speaker 1")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "hi"))])
        #expect(try store.hasSpeakerSegments(noteId: noteId) == true)
    }

    @Test("renameSpeaker sets displayName, and every segment picks it up on read")
    func renameSpeakerUpdatesDisplayLabel() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let inserted = try store.replaceSpeakerSegments(
            noteId: noteId, speakers: [NoteSpeaker(noteId: noteId, label: "Speaker 1")],
            segments: [
                (0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "a")),
                (0, AlignedSegment(speakerLabel: "S1", start: 1, end: 2, text: "b")),
            ])
        let speakerId = try #require(inserted.first?.id)
        try store.renameSpeaker(id: speakerId, to: "Alex")

        let fetched = try store.noteSegments(noteId: noteId)
        #expect(fetched.count == 2)
        #expect(fetched.allSatisfy { $0.speaker?.displayLabel == "Alex" })
    }

    @Test("renaming to an empty string clears the display name back to the stable label")
    func renameToEmptyClearsDisplayName() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let inserted = try store.replaceSpeakerSegments(
            noteId: noteId, speakers: [NoteSpeaker(noteId: noteId, label: "Speaker 1")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "a"))])
        let speakerId = try #require(inserted.first?.id)
        try store.renameSpeaker(id: speakerId, to: "Alex")
        try store.renameSpeaker(id: speakerId, to: "   ")

        let fetched = try store.noteSegments(noteId: noteId)
        #expect(fetched.first?.speaker?.displayLabel == "Speaker 1")
    }

    @Test("mergeSpeakers re-points segments and deletes the source speaker")
    func mergeSpeakersRepoints() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let inserted = try store.replaceSpeakerSegments(
            noteId: noteId,
            speakers: [
                NoteSpeaker(noteId: noteId, label: "Speaker 1"),
                NoteSpeaker(noteId: noteId, label: "Speaker 2"),
            ],
            segments: [
                (0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "a")),
                (1, AlignedSegment(speakerLabel: "S2", start: 1, end: 2, text: "b")),
            ])
        let target = try #require(inserted[0].id)
        let source = try #require(inserted[1].id)

        try store.mergeSpeakers(sourceId: source, intoTargetId: target)

        let fetched = try store.noteSegments(noteId: noteId)
        #expect(fetched.count == 2)
        #expect(fetched.allSatisfy { $0.speaker?.id == target })
    }

    @Test("deleting a speaker sets its segments' speakerId to null rather than deleting the segment")
    func deletingSpeakerNullsSegments() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let inserted = try store.replaceSpeakerSegments(
            noteId: noteId, speakers: [NoteSpeaker(noteId: noteId, label: "Speaker 1")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "a"))])
        let speakerId = try #require(inserted.first?.id)

        // Simulate a direct delete (not via merge) to confirm the FK's ON DELETE SET NULL policy.
        try store.writer.write { db in
            try NoteSpeaker.deleteOne(db, key: speakerId)
        }

        let fetched = try store.noteSegments(noteId: noteId)
        #expect(fetched.count == 1)
        #expect(fetched[0].segment.text == "a")
        #expect(fetched[0].speaker == nil)
    }

    @Test("deleting a note cascades to its speakers and segments")
    func deletingNoteCascades() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        _ = try store.replaceSpeakerSegments(
            noteId: noteId, speakers: [NoteSpeaker(noteId: noteId, label: "Speaker 1")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "a"))])

        try store.deleteNote(id: noteId)

        #expect(try store.noteSegments(noteId: noteId).isEmpty)
    }

    @Test("segments with no speaker index are saved as unattributed (nil speakerId)")
    func unassignedSpeakerIndexIsNull() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        _ = try store.replaceSpeakerSegments(
            noteId: noteId, speakers: [],
            segments: [(nil, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "solo"))])

        let fetched = try store.noteSegments(noteId: noteId)
        #expect(fetched.count == 1)
        #expect(fetched[0].speaker == nil)
    }
}
