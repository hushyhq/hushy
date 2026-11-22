import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// An imported file is recorded like a meeting (meetings T4b): `capture_segment(stream = 'file')` rows and journal
/// files, finished by the same `FinalizeRunner` steps, so Try again and playback read the same journal. An import
/// from before the journal (`chunk-%04d.wav`) is adopted as `file` rows on Try again. No speech model and an
/// in-memory store; files go under the test run's HUSHY_HOME.
@MainActor
@Suite("Imports through the capture journal", .serialized, .timeLimit(.minutes(2)))
struct ImportJournalTests {
    private func parts(suite: String) throws -> (Store, AppSettings, SpeechEngine, EncryptionController, FinalizeRunner) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
        settings.exportNotesToMarkdown = false
        settings.saveNotesToAppleNotes = false
        let status = SpeechModelStatus()
        let integrity = SpeechModelIntegrity(fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: suite)
        let speech = SpeechEngine(status: status, integrity: integrity)
        let encryption = EncryptionController(settings: settings, keyManager: EncryptionKeyManager(keyStore: InMemoryKeyStore()))
        let store = try Store()
        // Note folders are `Notes/<id>` under the shared test home: a spacer row moves this store's ids away from
        // the other suites' in-memory stores, which all start at 1.
        _ = try store.save(Note(id: Int64.random(in: 1_000_000...9_000_000), title: "spacer", status: .ready))
        let recorder = NoteRecorder(
            speech: speech, modelStatus: status, store: store, settings: settings, pill: PillModel(), encryption: encryption)
        // The summary names the note; an import keeps its file name.
        recorder.summarize = { _, _ in ExtractiveSummarizer.Output(title: "A summary title", summary: "", actionItems: []) }
        return (store, settings, speech, encryption, recorder.finalizer)
    }

    /// 70 s of tone bursts with pauses: the writer cuts it into a few segments.
    private func clip() -> [Float] {
        (0..<(70 * 16_000)).map { index in
            let loud: Float = (index / 8_000) % 2 == 0 ? 1 : 0.02
            return 0.2 * sin(Float(index) * 0.03) * loud
        }
    }

    private func eventually(within limit: Duration = .seconds(60), _ condition: () throws -> Bool) async rethrows -> Bool {
        let deadline = ContinuousClock.now + limit
        while try !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    @Test("an import writes file segments, no chunk files, finishes through the runner, keeps its name, and retries")
    func importThroughRunner() async throws {
        let suite = "hushy-test-import-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (store, settings, speech, encryption, finalizer) = try parts(suite: suite)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Board review \(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: source) }
        try WAVWriter.write(clip(), to: source, key: nil)
        let importer = FileTranscriber(
            fileURL: source, speech: speech, store: store, settings: settings, encryption: encryption, vocabulary: .empty,
            finalizer: finalizer)
        importer.start()
        #expect(await eventually { !importer.isRunning && importer.state != .idle })
        guard case .done(let id) = importer.state else { Issue.record("import ended \(importer.state)"); return }
        let note = try #require(try store.note(id: id))
        defer { if let path = note.audioPath { try? FileManager.default.removeItem(atPath: path) } }

        let journal = try store.captureJournal(noteId: id)
        #expect(!journal.audio(.file).isEmpty)
        #expect(journal.audio(.mic).isEmpty)
        #expect(journal.sealedSeconds(.file) > 69)
        #expect(!journal.hasOpenRows)
        let files = try FileManager.default.contentsOfDirectory(atPath: try #require(note.audioPath))
        #expect(files.allSatisfy { $0.hasPrefix("seg-") && $0.hasSuffix("-file.hseg") }, "journal files only, no chunk WAVs")
        #expect(try store.finalizeState(noteId: id)?.step == .done)
        #expect(note.status == .ready)
        #expect(note.title == source.deletingPathExtension().lastPathComponent)
        #expect(note.durationSeconds > 69)
        let folder = URL(fileURLWithPath: try #require(note.audioPath), isDirectory: true)
        #expect(MeetingAudioPlayer.spans(journal: journal, folder: folder)?.count == journal.audio(.file).count, "plays from the journal")

        finalizer.retry(noteId: id)
        #expect(try await eventually { try store.finalizeState(noteId: id)?.step == .done && finalizer.runningNoteIDs.isEmpty })
        #expect(try store.captureJournal(noteId: id).audio(.file).count == journal.audio(.file).count, "Try again reads the same rows")
        #expect(try store.note(id: id)?.title == note.title)
    }

    @Test("an import from before the journal still plays from its chunk files, and Try again adopts them as file rows")
    func legacyImportRetries() async throws {
        let suite = "hushy-test-import-legacy-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (store, _, _, _, finalizer) = try parts(suite: suite)
        var note = try store.save(Note(title: "Old import", status: .ready, source: .file))
        let id = try #require(note.id)
        let folder = AppPaths.notesAudioDirectory.appendingPathComponent("\(id)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<2 {
            try WAVWriter.write(Array(clip().prefix(16_000 * 5)), to: folder.appendingPathComponent(String(format: "chunk-%04d.wav", index)), key: nil)
        }
        note.audioPath = folder.path
        note = try store.save(note)
        try store.replaceTurns(noteId: id, turns: [
            NoteTurn(noteId: id, ordinal: 0, stream: .file, t0: 0, t1: 10, text: "what the old import heard", origin: .imported),
        ])
        #expect(MeetingAudioPlayer.spans(in: folder, key: nil).count == 2, "plays from the chunk files before Try again")

        finalizer.retry(noteId: id)
        #expect(try await eventually { try store.finalizeState(noteId: id)?.step == .done && finalizer.runningNoteIDs.isEmpty })
        let journal = try store.captureJournal(noteId: id)
        #expect(journal.audio(.file).count == 2)
        #expect(journal.audio(.file).allSatisfy { $0.format == .wav })
        #expect(journal.audio(.mic).isEmpty, "an import is never a microphone side, so it is never diarized")
        #expect(MeetingAudioPlayer.spans(journal: journal, folder: folder)?.count == 2)
        #expect(try store.note(id: id)?.title == "Old import")
    }
}
