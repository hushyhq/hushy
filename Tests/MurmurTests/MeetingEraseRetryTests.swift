import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Erase meetings against a Try again that is still running, through `NoteRecorder.retryTranscription` itself.
///
/// Nothing here reaches a person's Mac: an in-memory store and key store, a throwaway defaults suite, an engine with
/// no speech model, exports to Markdown and Apple Notes off, and the meeting's audio in a temp folder.
@MainActor
@Suite("Erase meetings wins over a retry in flight", .serialized, .timeLimit(.minutes(1)))
struct MeetingEraseRetryTests {
    /// Both exports are off unless `exportsTo` names a throwaway folder for the Markdown one (Apple Notes then goes
    /// through the recorder's `appleNotesScripter`, which the test replaces).
    private func recorder(store: Store, suite: String, exportsTo exports: URL? = nil) throws -> NoteRecorder {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
        settings.exportNotesToMarkdown = exports != nil
        settings.saveNotesToAppleNotes = exports != nil
        if let exports { settings.exportDirectory = exports }
        let status = SpeechModelStatus()
        let integrity = SpeechModelIntegrity(fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: suite)
        return NoteRecorder(
            speech: SpeechEngine(status: status, integrity: integrity), modelStatus: status, store: store,
            settings: settings, pill: PillModel(),
            encryption: EncryptionController(settings: settings, keyManager: EncryptionKeyManager(keyStore: InMemoryKeyStore())))
    }

    private func eventually(within limit: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test("Try again pressed while the Erase confirmation is open never brings the erased meeting back")
    func retryDoesNotRecreateErasedMeeting() async throws {
        let suite = "hushy-test-erase-retry-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erase-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("call", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data(count: 64).write(to: audio.appendingPathComponent("chunk-0000.wav"))

        let store = try Store()
        let meeting = try store.save(Note(title: "Zoom call", createdAt: Date(), status: .failed,
                                          audioPath: audio.path, source: .recording, meetingApp: .zoom))
        let id = try #require(meeting.id)
        let recorder = try recorder(store: store, suite: suite)

        let plan = try store.meetingErasePlan()
        #expect(plan.noteIDs == [id], "the confirmation counts the meeting")
        recorder.retryTranscription(for: meeting)
        #expect(recorder.retryingNoteID == id, "the retry is in flight")
        #expect(try store.eraseMeetings(plan) == 1, "Erase is confirmed while it runs")

        #expect(await eventually { recorder.retryingNoteID == nil }, "the retry ends")
        #expect(try store.note(id: id) == nil, "the erased meeting stays erased")
        #expect(try store.meetingErasePlan().count == 0)
        #expect(!FileManager.default.fileExists(atPath: audio.path), "and so does its audio")
    }

    // MARK: Erase while the summary is still being written

    /// Holds a summary open until the test lets it go.
    private actor SummaryHold {
        private var entered = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?

        func hold() async {
            entered = true
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func waitUntilHeld() async {
            while !entered { try? await Task.sleep(for: .milliseconds(5)) }
        }

        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    private struct Rig {
        let recorder: NoteRecorder
        let store: Store
        let scripter: FakeAppleNotesScripter
        let exports: URL
        let note: Note
        let id: Int64
    }

    /// A stored meeting whose transcript is in and whose summary is about to be written, with both exports on.
    private func rig(suite: String, root: URL) throws -> Rig {
        let store = try Store()
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        let note = Note(
            title: "Zoom call", createdAt: Date(),
            transcript: "Priya will send the deck to the team by Friday and Ben agreed to review the budget.",
            status: .processing, source: .recording, meetingApp: .zoom)
        let stored = try store.save(note)
        let recorder = try recorder(store: store, suite: suite, exportsTo: exports)
        let scripter = FakeAppleNotesScripter()
        recorder.appleNotesScripter = scripter
        return Rig(recorder: recorder, store: store, scripter: scripter, exports: exports, note: stored, id: try #require(stored.id))
    }

    private let output = ExtractiveSummarizer.Output(title: "Deck and budget", summary: "- Deck by Friday", actionItems: ["Priya: send the deck"])

    private func exported(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }
    }

    @Test("a summary that finishes normally saves the note ready and exports it to Markdown and Apple Notes")
    func summaryFinishingNormallyExports() async throws {
        let suite = "hushy-test-erase-summary-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erase-summary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(suite: suite, root: root)
        let summary = output
        rig.recorder.summarize = { _, _ in summary }

        let finished = await rig.recorder.summarizeAndFinalize(rig.note, chunkFailed: false, persistenceFailed: false)
        #expect(finished?.status == .ready)
        #expect(try rig.store.note(id: rig.id)?.title == "Deck and budget")
        #expect(exported(in: rig.exports).count == 1, "the Markdown export happened")
        #expect(rig.scripter.sources.count == 1, "the Apple Notes export happened")
    }

    @Test("Erase confirmed while the summary is still being written: the summary finishes, and neither the meeting nor an export comes back")
    func erasedDuringSummaryStaysErased() async throws {
        let suite = "hushy-test-erase-summary-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erase-summary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(suite: suite, root: root)
        let hold = SummaryHold()
        let summary = output
        rig.recorder.summarize = { _, _ in await hold.hold(); return summary }

        let plan = try rig.store.meetingErasePlan()
        #expect(plan.noteIDs == [rig.id], "the first write is in and the meeting is counted")
        let finishing = Task { await rig.recorder.summarizeAndFinalize(rig.note, chunkFailed: false, persistenceFailed: false) }
        await hold.waitUntilHeld()
        #expect(try rig.store.eraseMeetings(plan) == 1, "Erase is confirmed while the summary is being written")
        await hold.release()
        let finished = await finishing.value

        #expect(finished == nil, "the summary learned the meeting was gone")
        #expect(try rig.store.note(id: rig.id) == nil, "the erased meeting is not written back")
        #expect(try rig.store.meetingErasePlan().count == 0)
        #expect(exported(in: rig.exports).isEmpty, "no Markdown export")
        #expect(rig.scripter.sources.isEmpty, "no Apple Notes export")
    }

    // MARK: Erase landing between the summary's write and an export

    @Test("Erase confirmed after the summary is written but before the Markdown export: neither export comes back")
    func erasedBeforeMarkdownExport() async throws {
        let suite = "hushy-test-erase-export-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erase-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(suite: suite, root: root)
        let summary = output
        rig.recorder.summarize = { _, _ in summary }
        let plan = try rig.store.meetingErasePlan()
        let store = rig.store
        rig.recorder.beforeExport = { export in
            if export == "Markdown" { #expect((try? store.eraseMeetings(plan)) == 1) }
        }

        let finished = await rig.recorder.summarizeAndFinalize(rig.note, chunkFailed: false, persistenceFailed: false)

        #expect(finished?.status == .ready, "the summary itself was written before the erase")
        #expect(try rig.store.note(id: rig.id) == nil)
        #expect(exported(in: rig.exports).isEmpty, "no Markdown export of an erased meeting")
        #expect(rig.scripter.sources.isEmpty, "no Apple Notes export of an erased meeting")
    }

    @Test("Erase confirmed between the two exports: the Markdown one happened, the Apple Notes one does not")
    func erasedBetweenExports() async throws {
        let suite = "hushy-test-erase-export-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erase-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(suite: suite, root: root)
        let summary = output
        rig.recorder.summarize = { _, _ in summary }
        let plan = try rig.store.meetingErasePlan()
        let store = rig.store
        rig.recorder.beforeExport = { export in
            if export == "Apple Notes" { #expect((try? store.eraseMeetings(plan)) == 1) }
        }

        _ = await rig.recorder.summarizeAndFinalize(rig.note, chunkFailed: false, persistenceFailed: false)

        #expect(exported(in: rig.exports).count == 1, "the meeting still existed for the first export")
        #expect(rig.scripter.sources.isEmpty, "and was gone for the second")
    }
}
