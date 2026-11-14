import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The recorder writes into the capture journal and the finalize runner finishes or resumes it (notes audit B3, B4).
/// Synthetic sides, an in-memory store and key store, a throwaway defaults suite, exports off; no speech model, so
/// recognition fails and the note still ends ready from its audio. Audio files go under the test run's HUSHY_HOME.
@MainActor
@Suite("Recording into the capture journal", .serialized, .timeLimit(.minutes(2)))
struct NoteJournalRecorderTests {
    private func recorder(store: Store, suite: String) throws -> NoteRecorder {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
        settings.exportNotesToMarkdown = false
        settings.saveNotesToAppleNotes = false
        let status = SpeechModelStatus()
        let integrity = SpeechModelIntegrity(fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: suite)
        let recorder = NoteRecorder(
            speech: SpeechEngine(status: status, integrity: integrity), modelStatus: status, store: store,
            settings: settings, pill: PillModel(),
            encryption: EncryptionController(settings: settings, keyManager: EncryptionKeyManager(keyStore: InMemoryKeyStore())))
        recorder.summarize = { _, title in ExtractiveSummarizer.Output(title: title, summary: "", actionItems: []) }
        return recorder
    }

    /// Bursts of tone with quiet between them, three seconds, looped by the source.
    private func speech() -> [Float] {
        var out = [Float](repeating: 0, count: 48_000)
        for index in out.indices {
            let loud: Float = (index / 4_000) % 2 == 0 ? 1 : 0.1
            out[index] = 0.2 * sin(Float(index) * 0.03) * loud
        }
        return out
    }

    private func eventually(within limit: Duration = .seconds(60), _ condition: () throws -> Bool) async rethrows -> Bool {
        let deadline = ContinuousClock.now + limit
        while try !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    @Test("a stopped two-channel recording is on disk sealed, both sides, and the note finishes ready")
    func stopFinishes() async throws {
        let suite = "hushy-test-journal-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = try Store()
        let recorder = try recorder(store: store, suite: suite)
        let mic = SyntheticNoteSource(samples: speech())
        let call = SyntheticNoteSource(samples: speech())
        recorder.makeMicSource = { mic }
        recorder.makeCallSource = { call }
        try await recorder.start()
        let id = try #require(recorder.activeNote?.id)
        defer { if let path = try? store.note(id: id)?.audioPath { try? FileManager.default.removeItem(atPath: path) } }
        #expect(try store.finalizeState(noteId: id)?.step == .capturing)
        try await Task.sleep(for: .seconds(3.5))
        recorder.stop()
        #expect(try await eventually { try store.finalizeState(noteId: id)?.step == .done })
        let journal = try store.captureJournal(noteId: id)
        #expect(!journal.hasOpenRows)
        #expect(journal.sealedSeconds(.mic) >= 3, "every tick reached the disk")
        #expect(journal.sealedSeconds(.system) >= 2.5)
        #expect(try store.note(id: id)?.status == .ready, "audio with no words is a gap, never a failure")
    }

    @Test("a quit seals the recording at sealing, and a new runner finishes it with no click")
    func quitThenResume() async throws {
        let suite = "hushy-test-journal-quit-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = try Store()
        let recorder = try recorder(store: store, suite: suite)
        let mic = SyntheticNoteSource(samples: speech())
        recorder.makeMicSource = { mic }
        try await recorder.start()
        let id = try #require(recorder.activeNote?.id)
        defer { if let path = try? store.note(id: id)?.audioPath { try? FileManager.default.removeItem(atPath: path) } }
        try await Task.sleep(for: .seconds(2.5))
        await recorder.flushForQuit()
        #expect(try store.finalizeState(noteId: id)?.step == .sealing)
        #expect(try store.note(id: id)?.status == .processing)
        #expect(try store.captureJournal(noteId: id).sealedSeconds(.mic) >= 2)

        let relaunched = try self.recorder(store: store, suite: suite)
        #expect(relaunched.finalizer.resumeInterrupted() == [id])
        #expect(try await eventually { try store.finalizeState(noteId: id)?.step == .done })
        #expect(try store.note(id: id)?.status == .ready)
    }

    @Test("a side that stops delivering is warned about within seconds, rebuilt, and its missing time is a gap")
    func stallIsNoticed() async throws {
        let suite = "hushy-test-journal-stall-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = try Store()
        let recorder = try recorder(store: store, suite: suite)
        let mic = SyntheticNoteSource(samples: speech())
        let call = SyntheticNoteSource(samples: speech())
        call.rebuildCures = true
        recorder.makeMicSource = { mic }
        recorder.makeCallSource = { call }
        try await recorder.start()
        let id = try #require(recorder.activeNote?.id)
        defer { if let path = try? store.note(id: id)?.audioPath { try? FileManager.default.removeItem(atPath: path) } }
        try await Task.sleep(for: .seconds(2))
        call.setFault(.stall)
        let warned = await eventually(within: .seconds(20)) { recorder.capture?.warning(now: Date()) != nil }
        #expect(warned, "the dead call side is warned about")
        #expect(await eventually(within: .seconds(10)) { call.rebuildCount >= 1 }, "and rebuilt")
        #expect(await eventually(within: .seconds(20)) { recorder.capture?.callProblem == nil }, "the rebuilt side comes back")
        recorder.stop()
        #expect(try await eventually { try store.finalizeState(noteId: id)?.step == .done })
        let gaps = try store.captureJournal(noteId: id).segments.filter { $0.kind == .gap && $0.stream == .system }
        #expect(gaps.contains { $0.gapReason == .stall && $0.duration >= 3 })
    }
}
