import Foundation
import Testing
@testable import MurmurCore

/// Covers `NoteTranscriptExporter`: rendering a note's stored `NoteSegmentWithSpeaker` rows as
/// SRT/VTT/timestamped plain text, and the untimed-transcript fallback for a note with no stored
/// segments (a live microphone recording with no diarization run — see `NoteSegment`'s doc
/// comment).
@Suite("NoteTranscriptExporter")
struct NoteTranscriptExporterTests {
    private func makeNote(transcript: String = "Hello there") -> Note {
        Note(title: "Test Note", createdAt: Date(timeIntervalSince1970: 0), transcript: transcript, status: .ready)
    }

    private func segment(_ text: String, _ start: Double, _ end: Double, speaker: NoteSpeaker? = nil) -> NoteSegmentWithSpeaker {
        NoteSegmentWithSpeaker(
            segment: NoteSegment(noteId: 1, speakerId: speaker?.id, startTime: start, endTime: end, text: text, ordinal: 0),
            speaker: speaker)
    }

    private var words: [NoteSegmentWithSpeaker] {
        [segment("Hello", 0, 0.4), segment("there", 0.4, 0.9)]
    }

    @Test("SRT format renders subtitle cues from word timings")
    func srtRendersWords() {
        let output = NoteTranscriptExporter.render(makeNote(), segments: words, format: .srt)
        #expect(output.contains("Hello there"))
        #expect(output.contains("-->"))
    }

    @Test("VTT format renders the WEBVTT header and cues")
    func vttRendersWords() {
        let output = NoteTranscriptExporter.render(makeNote(), segments: words, format: .vtt)
        #expect(output.hasPrefix("WEBVTT"))
        #expect(output.contains("Hello there"))
    }

    @Test("Plain text format uses timestamps when segments are present")
    func plainTextUsesTimestampsWhenAvailable() {
        let output = NoteTranscriptExporter.render(makeNote(), segments: words, format: .plainText)
        #expect(output.hasPrefix("[0:00]"))
    }

    @Test("Plain text falls back to the untimed transcript when there are no stored segments")
    func plainTextFallsBackWithoutWords() {
        let note = makeNote(transcript: "No timings available here.")
        let output = NoteTranscriptExporter.render(note, segments: [], format: .plainText)
        #expect(output == "No timings available here.")
    }

    @Test("SRT with no segments renders an empty (but non-crashing) file")
    func srtWithNoWords() {
        let output = NoteTranscriptExporter.render(makeNote(), segments: [], format: .srt)
        #expect(output.isEmpty)
    }

    @Test("A speaker-attributed segment gets a 'Speaker: text' prefix in SRT")
    func speakerPrefixInSrt() {
        let speaker = NoteSpeaker(id: 1, noteId: 1, label: "Speaker 1")
        let output = NoteTranscriptExporter.render(
            makeNote(), segments: [segment("Hello there", 0, 1, speaker: speaker)], format: .srt)
        #expect(output.contains("Speaker 1: Hello there"))
    }

    @Test("File names are derived from the note's date and title, with the format's extension")
    func fileNameIncludesExtension() {
        let note = makeNote()
        #expect(NoteTranscriptExporter.fileName(for: note, format: .srt).hasSuffix(".srt"))
        #expect(NoteTranscriptExporter.fileName(for: note, format: .vtt).hasSuffix(".vtt"))
        #expect(NoteTranscriptExporter.fileName(for: note, format: .plainText).hasSuffix(".txt"))
    }

    @Test("File names strip characters that are invalid in a filename")
    func fileNameSanitizesTitle() {
        let note = Note(title: "Meeting: Q1/Q2 Review?", createdAt: Date(timeIntervalSince1970: 0), status: .ready)
        let name = NoteTranscriptExporter.fileName(for: note, format: .srt)
        for invalid in "/\\:*?\"<>|" {
            #expect(!name.contains(invalid))
        }
    }

    @Test("export(_:segments:format:to:) writes a readable file to disk")
    func exportWritesFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = makeNote()
        let url = try NoteTranscriptExporter.export(note, segments: words, format: .srt, to: directory)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("Hello there"))
    }

    @Test("Exporting the same note and format twice overwrites rather than duplicating")
    func exportOverwrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = makeNote()
        _ = try NoteTranscriptExporter.export(note, segments: words, format: .srt, to: directory)
        _ = try NoteTranscriptExporter.export(note, segments: words, format: .srt, to: directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
    }
}
