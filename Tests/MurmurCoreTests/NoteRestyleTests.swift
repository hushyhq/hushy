import Foundation
@testable import MurmurCore
import Testing

/// Rewrites each selection it is sent with `rewrite`, as an edit, and counts the calls.
private final class RewritingModel: LanguageModel, @unchecked Sendable {
    private let rewrite: @Sendable (String) -> String
    private let lock = NSLock()
    private var sent = 0

    init(_ rewrite: @escaping @Sendable (String) -> String) { self.rewrite = rewrite }

    var calls: Int { lock.withLock { sent } }
    var identifier: String { "rewriting" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        lock.withLock { sent += 1 }
        let selection = prompt.components(separatedBy: "<<<\n").dropFirst().first?.components(separatedBy: "\n>>>").first ?? ""
        let answer = rewrite(selection)
        let data = try JSONSerialization.data(withJSONObject: ["kind": "edit", "text": answer])
        return String(decoding: data, as: UTF8.self)
    }
}

/// An invented memo, as the recorder stores it: one voice, ready, no call app.
private func memo(_ body: String, status: Note.Status = .ready, source: Note.Source = .recording, app: MeetingApp? = nil) -> Note {
    var note = Note(id: 7, title: "Note · 9:41 AM", status: status, source: source, meetingApp: app)
    note = note.caching(NoteTranscript(turns: [
        NoteTurn(noteId: 7, ordinal: 0, stream: .mic, t0: 0, t1: 30, text: body, origin: .capture),
    ]))
    return note
}

@Suite("Note restyle")
struct NoteRestyleTests {
    private let body = "ok so for the offsite we will not book the boat, Marta is sorting the bus and we need 14 seats"
    private let professional = "For the offsite, we will not book the boat. Marta is arranging the bus, and we need 14 seats."

    // MARK: The rewrite

    @Test("a rewrite that keeps every fact is the note's new text")
    func rewritten() async {
        let outcome = await NoteRestyle.restyle(body, as: .professional, model: RewritingModel { _ in professional })
        #expect(outcome == .rewritten(professional))
    }

    @Test("Refined is the stored text itself: no model call")
    func refinedIsTheBody() async {
        let model = RewritingModel { _ in "anything" }
        #expect(await NoteRestyle.restyle(body, as: .refined, model: model) == .rewritten(body))
        #expect(model.calls == 0)
    }

    @Test("a dropped not, a changed name or changed digits keep the original",
          arguments: [
              "For the offsite, we will book the boat. Marta is arranging the bus, and we need 14 seats.",
              "For the offsite, we will not book the boat. Maria is arranging the bus, and we need 14 seats.",
              "For the offsite, we will not book the boat. Marta is arranging the bus, and we need 40 seats.",
          ])
    func guardRefusalKeepsOriginal(answer: String) async {
        let outcome = await NoteRestyle.restyle(body, as: .professional, model: RewritingModel { _ in answer })
        #expect(outcome == .kept(.wouldChangeMeaning))

        // What the page does with that outcome: the state, and so the shown text, stays as it was.
        let state = NoteStyleState(body: body)
        let after = NoteRestyleTests.apply(outcome, style: .professional, to: state)
        #expect(after == state)
        #expect(after.text(body: body) == body)
    }

    @Test("a long note goes piece by piece; one refused piece keeps the whole note")
    func piecesAllOrNothing() async {
        let sentence = "We will not ship the beta before the 3 reviews are done and Priya signs off on it."
        let long = Array(repeating: sentence, count: 60).joined(separator: " ")
        #expect(long.count > NoteRestyle.pieceCharacters * 2)

        let calm = RewritingModel { $0.replacingOccurrences(of: "We will not", with: "We won't") }
        guard case .rewritten(let text) = await NoteRestyle.restyle(long, as: .casual, model: calm) else {
            Issue.record("every piece kept its facts")
            return
        }
        #expect(calm.calls == NoteRestyle.pieces(of: long).count)
        #expect(calm.calls > 1)
        #expect(!text.contains("We will not") && text.contains("We won't ship the beta"))

        let pieces = NoteRestyle.pieces(of: long)
        let lastPiece = pieces[pieces.count - 1].text
        let slips = RewritingModel { selection in
            selection == lastPiece ? selection.replacingOccurrences(of: "3 reviews", with: "2 reviews") : selection + " Thanks."
        }
        #expect(await NoteRestyle.restyle(long, as: .casual, model: slips) == .kept(.wouldChangeMeaning))
    }

    @Test("dictation starting stops the rewrite between pieces, before the model is asked again")
    func pausesForDictation() async {
        let model = RewritingModel { _ in "unused" }
        #expect(await NoteRestyle.restyle(body, as: .casual, model: model, shouldContinue: { false }) == .paused)
        #expect(model.calls == 0)
    }

    @Test("a note that already reads that way is kept and says so")
    func unchanged() async {
        #expect(await NoteRestyle.restyle(body, as: .casual, model: RewritingModel { $0 }) == .kept(.unchanged))
    }

    @Test("past the length limit nothing is sent")
    func tooLong() async {
        let model = RewritingModel { $0 }
        let huge = String(repeating: "word ", count: NoteRestyle.maxCharacters / 5 + 10)
        #expect(await NoteRestyle.restyle(huge, as: .casual, model: model) == .tooLong)
        #expect(model.calls == 0)
    }

    @Test("pieces give the body back with its line breaks, and stay under the limit")
    func piecesRoundTrip() {
        let text = "First line.\n\nSecond line is here. And more.\nThird."
        #expect(NoteRestyle.join(NoteRestyle.pieces(of: text)) == text)
        let long = Array(repeating: "A short sentence about the plan.", count: 200).joined(separator: " ")
        let pieces = NoteRestyle.pieces(of: long)
        #expect(pieces.allSatisfy { $0.text.count <= NoteRestyle.pieceCharacters })
        #expect(NoteRestyle.join(pieces) == long)
    }

    // MARK: Undo and the current style

    @Test("each change can be undone, back to the text as written")
    func undo() {
        let start = NoteStyleState(body: body)
        #expect(start.style == .refined && !start.canUndo)

        let pro = start.showing(.professional, text: professional)
        #expect(pro.style == .professional && pro.text(body: body) == professional)
        let casual = pro.showing(.casual, text: "Offsite: no boat. Marta's on the bus, we need 14 seats.")
        #expect(casual.style == .casual)

        #expect(casual.undone().style == .professional)
        #expect(casual.undone().undone().style == .refined)
        #expect(casual.undone().undone().text(body: body) == body)
        #expect(!casual.undone().undone().canUndo)

        // Back to Refined is one more step, itself undoable, and every version stays cached.
        let back = casual.showing(.refined)
        #expect(back.text(body: body) == body)
        #expect(back.undone().style == .casual)
        #expect(back.hasVersion(.professional) && back.hasVersion(.casual))
    }

    @Test("a style with no written version cannot be shown")
    func noVersionNoChange() {
        let start = NoteStyleState(body: body)
        #expect(start.showing(.casual) == start)
    }

    @Test("Undo keeps at most its depth")
    func undoDepth() {
        var state = NoteStyleState(body: body).showing(.professional, text: professional).showing(.casual, text: "casual")
        for _ in 0..<(NoteStyleState.undoDepth * 2) { state = state.showing(state.style == .casual ? .professional : .casual) }
        #expect(state.history.count == NoteStyleState.undoDepth)
    }

    // MARK: Survives a relaunch

    @Test("the style and its versions are read back from the note's folder after a relaunch")
    func relaunchPersistence() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = NoteStyleState(body: body).showing(.professional, text: professional)
        try NoteStyleFile(folder: folder).write(state)

        // A new process: nothing in memory, only the file.
        let reread = try #require(NoteStyleFile(folder: folder).read(body: body))
        #expect(reread == state)
        #expect(reread.text(body: body) == professional)
        #expect(reread.undone().text(body: body) == body)

        let attributes = try FileManager.default.attributesOfItem(atPath: NoteStyleFile(folder: folder).url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("versions written from other text are not shown: a retried note reads as written")
    func staleVersionsIgnored() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = NoteStyleFile(folder: folder)
        try file.write(NoteStyleState(body: body).showing(.professional, text: professional))
        #expect(file.read(body: body + " And one more thing.") == nil)
        #expect(NoteStyleState(body: body).showing(.professional, text: professional).text(body: "other text") == "other text")

        try Data("not json".utf8).write(to: file.url)
        #expect(file.read(body: body) == nil)
        file.remove()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test("the file lives in the note's own folder, which deleting the note removes")
    func fileLocation() {
        var note = memo(body)
        note.audioPath = "/tmp/hushy-test/Notes/7"
        #expect(NoteStyleFile(note: note)?.url.path == "/tmp/hushy-test/Notes/7/restyle.json")
        note.audioPath = nil
        let notes = URL(fileURLWithPath: "/tmp/hushy-test/Notes", isDirectory: true)
        #expect(NoteStyleFile(note: note, notesDirectory: notes)?.url.path == "/tmp/hushy-test/Notes/7/restyle.json")
        #expect(NoteStyleFile(note: Note(title: "unsaved"), notesDirectory: notes) == nil)
    }

    // MARK: Memos only

    @Test("only a memo's body is offered; meetings, imports and unfinished notes are not")
    func availability() {
        func of(_ note: Note, voices: Bool = false, consent: Bool = false, calendar: Bool = false) -> NoteRestyle.Availability {
            NoteRestyle.availability(of: note, hasSeveralVoices: voices, hasConsent: consent, hasCalendarLink: calendar)
        }
        #expect(of(memo(body)) == .available)
        #expect(of(memo(body, app: .zoom)) == .meeting)
        #expect(of(memo(body), voices: true) == .meeting)
        #expect(of(memo(body), consent: true) == .meeting)
        #expect(of(memo(body), calendar: true) == .meeting)
        #expect(of(memo(body, source: .file)) == .imported)
        #expect(of(memo(body, status: .processing)) == .notReady)
        #expect(of(memo("  ")) == .empty)
        #expect(of(memo(String(repeating: "a", count: NoteRestyle.maxCharacters + 1))) == .tooLong)
    }

    @Test("every string the restyle shows is a placeholder until the founder writes it")
    func placeholderCopy() {
        var strings = [NoteRestyleCopy.controlLabel, NoteRestyleCopy.rewriting, NoteRestyleCopy.rewritingDetail,
                       NoteRestyleCopy.stop, NoteRestyleCopy.undo, NoteRestyleCopy.backToRefined,
                       NoteRestyleCopy.originalKept, NoteRestyleCopy.paused, NoteRestyleCopy.tooLong]
        strings += RestyleStyle.allCases.flatMap { [NoteRestyleCopy.style($0), NoteRestyleCopy.shownAs($0)] }
        strings += VoiceEditDecline.allCases.map(NoteRestyleCopy.kept)
        for string in strings { #expect(string.hasPrefix("[placeholder] "), "\(string)") }
    }

    // MARK: Helpers

    /// The page's rule: only a rewrite changes the state.
    static func apply(_ outcome: NoteRestyle.Outcome, style: RestyleStyle, to state: NoteStyleState) -> NoteStyleState {
        guard case .rewritten(let text) = outcome else { return state }
        return state.showing(style, text: text)
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("note-restyle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
