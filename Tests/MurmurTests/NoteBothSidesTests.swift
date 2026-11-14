import Foundation
import MurmurCore
import Synchronization
import Testing
@testable import Murmur

/// Notes audit B2: a two-channel note keeps both sides, and a listen-only call (the mic said nothing)
/// finishes ready from the other side's words, with them in the summary's input and the export.
@MainActor
@Suite("A call note keeps both sides", .serialized, .timeLimit(.minutes(1)))
struct NoteBothSidesTests {
    private func recorder(store: Store, suite: String, exports: URL) throws -> NoteRecorder {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
        settings.exportNotesToMarkdown = true
        settings.saveNotesToAppleNotes = false
        settings.exportDirectory = exports
        let status = SpeechModelStatus()
        let integrity = SpeechModelIntegrity(fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: suite)
        return NoteRecorder(
            speech: SpeechEngine(status: status, integrity: integrity), modelStatus: status, store: store,
            settings: settings, pill: PillModel(),
            encryption: EncryptionController(settings: settings, keyManager: EncryptionKeyManager(keyStore: InMemoryKeyStore())))
    }

    private func turn(_ stream: NoteTurn.Stream, _ text: String, at t0: Double) -> NoteTurn {
        NoteTurn.captured(stream: stream, seq: Int(t0 / 30), start: t0, duration: 30, text: text, timings: nil)!
    }

    private func finish(_ turns: [NoteTurn]) async throws -> (note: Note?, summaryInput: String, export: String) {
        let suite = "hushy-test-both-sides-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("both-sides-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store()
        let note = try store.save(Note(title: "Zoom call", status: .processing, meetingApp: .zoom))
        try store.appendTurns(noteId: try #require(note.id), turns: turns)
        let recorder = try recorder(store: store, suite: suite, exports: root)
        let input = Mutex("")
        recorder.summarize = { transcript, _ in
            input.withLock { $0 = transcript }
            return ExtractiveSummarizer.Output(title: "Contract", summary: "- Contract by Thursday", actionItems: [])
        }
        let finished = await recorder.summarizeAndFinalize(note, chunkFailed: false, persistenceFailed: false)
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let export = try files.first.map { try String(contentsOf: $0, encoding: .utf8) } ?? ""
        return (finished, input.withLock { $0 }, export)
    }

    @Test("a listen-only call ends ready with the other side's words in the summary input and the export")
    func listenOnly() async throws {
        let result = try await finish([turn(.system, "The procurement team signs on Thursday.", at: 0)])
        #expect(result.note?.status == .ready)
        #expect(result.note?.transcript == "The procurement team signs on Thursday.")
        #expect(result.summaryInput.contains("procurement team"))
        #expect(result.export.contains("procurement team"))
    }

    @Test("a two-channel call is summarized and exported as both sides, by label")
    func bothSides() async throws {
        let result = try await finish([
            turn(.mic, "Can you send the contract?", at: 0), turn(.system, "Yes, by Thursday.", at: 30),
        ])
        #expect(result.note?.status == .ready)
        #expect(result.summaryInput == "You: Can you send the contract?\nSpeaker 1: Yes, by Thursday.")
        #expect(result.export.contains("Speaker 1: Yes, by Thursday."))
    }

    @Test("a note with no words at all still ends failed")
    func nothingSaid() async throws {
        let result = try await finish([])
        #expect(result.note?.status == .failed)
    }
}
