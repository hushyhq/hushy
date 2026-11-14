import Foundation
import Testing
@testable import MurmurCore

/// Covers migration "v8-note-source": the `Note.source`/`sourcePath` columns, and that an
/// imported file's word timings round-trip through the existing v6 `note_segment` storage
/// (`Store.replaceSpeakerSegments`/`noteSegments`) with an unattributed (`speakerId == nil`)
/// segment per word — see `.claude/DECISIONS.md`'s file-import/speaker-labels reconciliation
/// entry for why v8 doesn't add its own segment table. General speaker/segment storage behavior
/// (atomicity, rename, merge) is covered by `StoreNoteSpeakersTests`; this file only covers the
/// v8-specific delta. Uses an in-memory store (`Store.init()`), never the user's real database.
@Suite("Store note source (v8-note-source)")
struct StoreNoteSourceTests {
    @Test("A note defaults to source .recording when not specified")
    func defaultSourceIsRecording() throws {
        let store = try Store()
        let saved = try store.save(Note(title: "Live note"))
        #expect(saved.source == .recording)
        #expect(saved.sourcePath == nil)
    }

    @Test("A note created with source .file persists its source and path")
    func fileSourcePersists() throws {
        let store = try Store()
        let note = Note(title: "Imported.mp3", source: .file, sourcePath: "/Users/test/Imported.mp3")
        let saved = try store.save(note)
        let fetched = try #require(try store.note(id: saved.id!))
        #expect(fetched.source == .file)
        #expect(fetched.sourcePath == "/Users/test/Imported.mp3")
    }

    @Test("An imported file's word timings save as unattributed note_segment rows")
    func importedWordsSaveUnattributed() throws {
        let store = try Store()
        let note = try store.save(Note(title: "Imported", source: .file, sourcePath: "/tmp/imported.wav"))
        let id = try #require(note.id)

        let words: [(word: String, start: Double, end: Double)] = [
            ("Hello", 0, 0.5), ("world", 0.5, 1.0),
        ]
        let segments: [(speakerIndex: Int?, segment: AlignedSegment)] = words.map {
            (nil, AlignedSegment(speakerLabel: "", start: $0.start, end: $0.end, text: $0.word))
        }
        try store.replaceSpeakerSegments(noteId: id, speakers: [], segments: segments)

        let fetched = try store.noteSegments(noteId: id)
        #expect(fetched.map(\.segment.text) == ["Hello", "world"])
        #expect(fetched.allSatisfy { $0.speaker == nil })
        #expect(fetched.map(\.segment.startTime) == [0, 0.5])
    }

    @Test("hasSpeakerSegments is true for an imported note with saved word segments")
    func hasSegmentsTrueForImport() throws {
        let store = try Store()
        let note = try store.save(Note(title: "Imported", source: .file))
        let id = try #require(note.id)
        try store.replaceSpeakerSegments(
            noteId: id, speakers: [],
            segments: [(nil, AlignedSegment(speakerLabel: "", start: 0, end: 1, text: "Hi"))])
        #expect(try store.hasSpeakerSegments(noteId: id))
    }

    @Test("A live recording with no diarization has no segments")
    func liveRecordingNoSegments() throws {
        let store = try Store()
        let note = try store.save(Note(title: "Live note"))
        #expect(try store.noteSegments(noteId: note.id!).isEmpty)
        #expect(try store.hasSpeakerSegments(noteId: note.id!) == false)
    }
}
