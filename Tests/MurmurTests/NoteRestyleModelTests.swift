import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Answers every voice edit with `answer`, as an edit.
private struct FixedEditModel: LanguageModel {
    let answer: String
    var identifier: String { "fixed-edit" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["kind": "edit", "text": answer]), as: UTF8.self)
    }
}

/// The note page's restyle, end to end on an invented memo in a temporary notes folder: a refusal keeps the text and
/// writes nothing, a rewrite is shown and saved, a new model (a relaunch) reads it back, and Undo goes back.
@MainActor
@Suite("Note restyle on the page")
struct NoteRestyleModelTests {
    private let body = "we will not move the launch, Jonas has the 3 slides ready for the review on friday"
    private let professional = "We will not move the launch. Jonas has the 3 slides ready for the review on Friday."

    private func memo(in folder: URL) -> Note {
        var note = Note(id: 42, title: "Launch", status: .ready)
        note.audioPath = folder.appendingPathComponent("42", isDirectory: true).path
        return note.caching(NoteTranscript(turns: [NoteTurn(noteId: 42, ordinal: 0, stream: .mic, t0: 0, t1: 20, text: body, origin: .capture)]))
    }

    private func settled(_ styles: NoteRestyleModel, _ note: Note) async -> NoteRestyleModel.Page {
        for _ in 0..<400 {
            if case .rewriting = styles.page(for: note).phase { try? await Task.sleep(for: .milliseconds(5)) } else { break }
        }
        return styles.page(for: note)
    }

    @Test("a refused rewrite keeps the text and saves nothing; an accepted one survives a relaunch and undoes")
    func refuseAcceptRelaunchUndo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("note-restyle-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = memo(in: folder)
        let file = try #require(NoteStyleFile(note: note))

        let refusing = NoteRestyleModel(model: FixedEditModel(answer: "We will not move the launch. Jonas has 4 slides."),
                                        isCapturing: { false }, notesDirectory: folder)
        refusing.load(note)
        refusing.pick(.professional, for: note)
        let kept = await settled(refusing, note)
        #expect(kept.phase == .notice(NoteRestyleCopy.kept(.wouldChangeMeaning)))
        #expect(kept.state.style == .refined)
        #expect(refusing.text(for: note) == body)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))

        let accepting = NoteRestyleModel(model: FixedEditModel(answer: professional), isCapturing: { false }, notesDirectory: folder)
        accepting.load(note)
        accepting.pick(.professional, for: note)
        let shown = await settled(accepting, note)
        #expect(shown.phase == .idle && shown.state.style == .professional)
        #expect(accepting.text(for: note) == professional)
        #expect(note.transcript == body, "the stored text is never written")

        // A relaunch: a new model with nothing in memory reads the note's folder.
        let relaunched = NoteRestyleModel(model: FixedEditModel(answer: "unused"), isCapturing: { false }, notesDirectory: folder)
        relaunched.load(note)
        #expect(relaunched.text(for: note) == professional)
        relaunched.undo(note)
        #expect(relaunched.text(for: note) == body)

        let again = NoteRestyleModel(model: FixedEditModel(answer: "unused"), isCapturing: { false }, notesDirectory: folder)
        again.load(note)
        #expect(again.page(for: note).state.style == .refined, "Undo is saved too")
        again.pick(.professional, for: note)
        #expect(again.text(for: note) == professional, "the kept version is shown without asking the model")
    }

    @Test("nothing is rewritten while a dictation or a recording is under way")
    func waitsForCapture() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("note-restyle-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = memo(in: folder)
        let styles = NoteRestyleModel(model: FixedEditModel(answer: professional), isCapturing: { true }, notesDirectory: folder)
        styles.pick(.professional, for: note)
        let page = await settled(styles, note)
        #expect(page.phase == .notice(NoteRestyleCopy.paused))
        #expect(styles.text(for: note) == body)
    }
}
