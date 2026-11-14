import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The failure and Try again wiring exercised through `DictationController` itself: a recording
/// that has just ended is handed in through the controller's test seam, recognition throws
/// because the speech model was never loaded, and everything after that is the real code.
///
/// Nothing here can reach a person's Mac: no microphone (the seam takes samples), no event tap
/// (the monitor is never started), no sound, an in-memory store and key store, a throwaway
/// defaults suite, and an engine with no model, so recognition always throws and nothing is ever
/// delivered, pasted or copied. Audio files are written only under a temp `HUSHY_HOME`.
@Suite("Recovery through the dictation controller", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DictationRecoveryControllerTests {
    @MainActor
    final class Harness {
        let pill = PillModel()
        let hotkeys = HotkeyMonitor()
        let modelStatus = SpeechModelStatus()
        let store: Store
        let settings: AppSettings
        let controller: DictationController
        private let suite = "hushy-test-recovery-\(UUID().uuidString)"

        /// Audio is written only when the run has a temp home; otherwise nothing touches disk.
        static var hasTempHome: Bool {
            let environment = ProcessInfo.processInfo.environment
            return environment["HUSHY_HOME"] != nil || environment["MURMUR_HOME"] != nil
        }

        init(keepAudio: Bool = false) throws {
            store = try Store()
            let defaults = try #require(UserDefaults(suiteName: suite))
            settings = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
            settings.audioRetentionDays = keepAudio && Self.hasTempHome ? 7 : 0
            let sounds = Sounds()
            sounds.isEnabled = false
            let integrity = SpeechModelIntegrity(fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: suite)
            controller = DictationController(
                speech: SpeechEngine(status: modelStatus, integrity: integrity), modelStatus: modelStatus, store: store,
                settings: settings, pill: pill, sounds: sounds, hotkeys: hotkeys,
                encryption: EncryptionController(settings: settings, keyManager: EncryptionKeyManager(keyStore: InMemoryKeyStore())),
                cleanupModel: NullLanguageModel())
            // Its own selector with no devices: nothing asks the Mac, and no test leaves a
            // microphone on trial for the next.
            controller.microphones = MicrophoneSelector(probe: { .init(inputs: [], systemDefault: nil) })
        }

        deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

        /// Two seconds of a clear tone: it passes the speech gate, so recognition is reached.
        static let speech: [Float] = (0..<32_000).map { 0.2 * sin(2 * Float.pi * 220 * Float($0) / 16_000) }

        var rows: [Dictation] { (try? store.allDictations()) ?? [] }

        /// The limit bounds a hang, not a speed: in the full suite the whole test process stalls for 15 to 20 s
        /// at a stretch (every test reports that long), and a 10 s limit here failed on that alone.
        func eventually(within limit: Duration = .seconds(60), _ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while !condition() {
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }

        /// A dictation whose recognition throws: the failure row is up and its History row is saved.
        func failOnce() async -> Bool {
            controller.finishForTests(samples: Self.speech)
            return await eventually { self.pill.state == .failed(.transcription(recordingKept: true)) && self.rows.count == 1 }
        }
    }

    @Test("a second UI toggle while the mic opens queues a stop without beginning again")
    func toggleDuringStart() throws {
        let harness = try Harness()
        harness.controller.startPending = true
        harness.controller.toggleHandsFree()
        #expect(harness.controller.startPending)
        #expect(harness.controller.pendingStartEvents.map(\.0) == [.stopLatched])
        #expect(harness.pill.state == .idle, "no second begin or model-readiness failure")
    }

    // MARK: A failure, through the controller

    @Test("recognition that throws leaves the failure row with Try again, one failed row, and the controller free")
    func failureIsWired() async throws {
        let harness = try Harness()
        #expect(!harness.modelStatus.isReady, "no model: recognition can only throw, so nothing is ever delivered")
        #expect(await harness.failOnce())
        #expect(!harness.controller.isBusy, "the next dictation is not blocked")
        #expect(harness.rows.map(\.status) == [.failed])
        #expect(harness.rows.first?.text == "")
        #expect(harness.pill.selfDismissDelay == nil, "and it stays")
    }

    @Test("the controller reports busy then idle, so a summary can yield the shared model to a dictation")
    func reportsBusy() async throws {
        final class Seen { var values: [Bool] = [] }
        let seen = Seen()
        let harness = try Harness()
        harness.controller.onBusyChanged = { seen.values.append($0) }
        #expect(await harness.failOnce())
        #expect(await harness.eventually { !harness.controller.isBusy })
        #expect(seen.values == [true, false], "once going in, once coming out; no repeats while the phase changes inside")
    }

    @Test("a recording with no speech in it is the heard-nothing failure, with no Try again")
    func silenceIsWired() async throws {
        let harness = try Harness()
        harness.controller.finishForTests(samples: [Float](repeating: 0.000_1, count: 32_000))
        #expect(harness.pill.state == .failed(.heardNothing))
        #expect(!harness.controller.isBusy)
        harness.controller.finishForTests(samples: [Float](repeating: 0, count: 32_000))
        #expect(harness.pill.state == .failed(.micSilent))
    }

    @Test("an accidental tap with no speech energy collapses: no row, nothing in History")
    func accidentalTapIsSilent() async throws {
        let harness = try Harness()
        harness.controller.finishForTests(samples: [Float](repeating: 0.000_5, count: 6_400), heldFor: 0.4)
        #expect(harness.pill.state == .idle)
        #expect(!harness.controller.isBusy)
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.rows.isEmpty)
    }

    @Test("a real hold the microphone heard, with no speech, is the brief line, not the mic hint")
    func heardButNoSpeechIsBrief() async throws {
        let harness = try Harness()
        var state: UInt64 = 3
        let office: [Float] = (0..<32_000).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * 0.002
        }
        harness.controller.finishForTests(samples: office)
        #expect(harness.pill.state == .failed(.missedWords(heardSpeech: false)))
        #expect(!harness.controller.isBusy)
    }

    // MARK: Try again, through the controller

    @Test("Try again runs the dictation again; when it fails again the row is back and History still has one row")
    func retryFailsAgain() async throws {
        let harness = try Harness()
        #expect(await harness.failOnce())
        harness.pill.retryFailure()
        #expect(harness.controller.isBusy, "the kept audio is being processed")
        #expect(harness.pill.state == .processing())
        #expect(await harness.eventually { harness.pill.state == .failed(.transcription(recordingKept: true)) && !harness.controller.isBusy })
        try await Task.sleep(for: .milliseconds(200)) // any stray second save would land by now
        #expect(harness.rows.count == 1)
        harness.pill.retryFailure()
        #expect(harness.controller.isBusy, "and it can be tried again")
    }

    @Test("Esc during a retry adds no second row and no second audio file")
    func retryCancelled() async throws {
        let harness = try Harness(keepAudio: true)
        var saves = 0
        harness.controller.onSaved = { saves += 1 }
        #expect(await harness.failOnce())
        #expect(await harness.eventually { saves == 1 }, "the failure's own save has reported back")
        let saved = try #require(harness.rows.first)
        harness.pill.retryFailure()
        harness.controller.handle(.cancel)
        #expect(harness.pill.state == .idle)
        #expect(await harness.eventually { !harness.controller.isBusy })
        // The controller is free before the cancelled run's save lands: that save re-reads the audio through the
        // recogniser lane and writes on a utility-priority task, so under load it can come seconds later. Wait for
        // the row to say so, and for the save to report back, instead of guessing how long it takes.
        #expect(await harness.eventually { harness.rows.first?.status == .cancelled && saves >= 2 })
        #expect(saves == 2, "one save for the cancelled run, not a second one")
        #expect(harness.rows.count == 1, "one History row for one dictation")
        #expect(harness.rows.first?.id == saved.id)
        #expect(harness.rows.first?.audioPath == saved.audioPath, "and the one audio file it already had")
        #expect(harness.rows.first?.status == .cancelled, "the row says what the person did, as Esc on a first attempt does")
        if Harness.hasTempHome {
            let path = try #require(saved.audioPath)
            #expect(FileManager.default.fileExists(atPath: path))
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    @Test("a retry that fails again keeps the audio file the first failure wrote, and writes no other")
    func retryKeepsOneFile() async throws {
        try #require(Harness.hasTempHome, "needs a temp HUSHY_HOME; never writes audio to the real one")
        let harness = try Harness(keepAudio: true)
        #expect(await harness.failOnce())
        let saved = try #require(harness.rows.first)
        let path = try #require(saved.audioPath)
        harness.pill.retryFailure()
        #expect(await harness.eventually { harness.pill.state.isFailure && !harness.controller.isBusy })
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.rows.count == 1)
        #expect(harness.rows.first?.audioPath == path)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("a retry that produces text fills in the failed row: same row, same place, same audio file, nothing new written")
    func retryThatSucceedsFillsTheRow() async throws {
        let harness = try Harness(keepAudio: true)
        #expect(await harness.failOnce())
        let first = try #require(harness.rows.first)
        // The model cannot be loaded in a test, so the successful run's own save is called as
        // `process` calls it: the dictation it would store, with the retry's session settings.
        let retry = DictationController.SessionSettings(
            cleanupOptions: harness.settings.cleanupOptions, tone: harness.settings.toneSettings, retainAudio: true,
            personalizer: Personalizer(), mode: harness.settings.previewActiveMode(bundleID: nil), projectVocabulary: nil,
            retryOf: Task { first })
        let text = Dictation(rawText: "ship it thursday", text: "Ship it on Thursday.", durationSeconds: 2, status: .inserted)
        let id = await harness.controller.persist(text, samples: Harness.speech, settings: retry)
        #expect(id == first.id)
        #expect(harness.rows.count == 1, "one History row for one dictation")
        let row = try #require(harness.rows.first)
        #expect(row.text == "Ship it on Thursday.")
        #expect(row.status == .inserted)
        #expect(row.audioPath == first.audioPath, "no second audio file")
        #expect(row.createdAt == first.createdAt, "it keeps its place in History")
        if let path = first.audioPath { try? FileManager.default.removeItem(atPath: path) }
    }

    // MARK: The first attempt's row changed while the retry ran

    /// What `process` stores for a retry that produced text, with the retry's session settings.
    private func saveRetryResult(_ harness: Harness, of first: Dictation) async -> Int64? {
        let retry = DictationController.SessionSettings(
            cleanupOptions: harness.settings.cleanupOptions, tone: harness.settings.toneSettings, retainAudio: true,
            personalizer: Personalizer(), mode: harness.settings.previewActiveMode(bundleID: nil), projectVocabulary: nil,
            retryOf: Task { first })
        let text = Dictation(createdAt: Date(timeIntervalSince1970: 2_000_000_000), rawText: "ship it thursday",
                             text: "Ship it on Thursday.", durationSeconds: 2, status: .inserted)
        return await harness.controller.persist(text, samples: Harness.speech, settings: retry)
    }

    @Test("a row the person deleted is not brought back: the retry's text is a fresh row with no audio path")
    func deletedRowStaysDeleted() async throws {
        let harness = try Harness(keepAudio: true)
        #expect(await harness.failOnce())
        let first = try #require(harness.rows.first)
        let firstID = try #require(first.id)
        // A later row, so the database cannot hand the deleted id out again.
        _ = try harness.store.save(Dictation(rawText: "later", text: "Later.", durationSeconds: 1))
        try harness.store.deleteDictation(id: firstID)
        if let path = first.audioPath { try? FileManager.default.removeItem(atPath: path) }

        let id = await saveRetryResult(harness, of: first)
        #expect(id != nil)
        #expect(id != firstID, "never re-inserted under the old id")
        #expect(harness.rows.count == 2)
        let row = try #require(harness.rows.first { $0.id == id })
        #expect(row.text == "Ship it on Thursday.")
        #expect(row.audioPath == nil, "the old file is gone; no path to it is written back")
        #expect(row.createdAt != first.createdAt, "it is a new entry, not the old one's place in History")
        #expect(!harness.rows.contains { $0.id == firstID })
    }

    @Test("Esc on a retry whose row was deleted brings nothing back either")
    func deletedRowAndEsc() async throws {
        let harness = try Harness(keepAudio: true)
        #expect(await harness.failOnce())
        let first = try #require(harness.rows.first)
        try harness.store.deleteDictation(id: try #require(first.id))
        if let path = first.audioPath { try? FileManager.default.removeItem(atPath: path) }
        harness.pill.retryFailure()
        harness.controller.handle(.cancel)
        #expect(await harness.eventually { !harness.controller.isBusy && harness.rows.count == 1 })
        let row = try #require(harness.rows.first)
        #expect(row.status == .cancelled)
        #expect(row.audioPath == nil, "no path to a file that no longer exists")
        #expect(row.createdAt != first.createdAt)
    }

    @Test("a row History's own Retry already filled in is left alone: the retry's text is a fresh row")
    func filledRowIsNotOverwritten() async throws {
        let harness = try Harness(keepAudio: true)
        #expect(await harness.failOnce())
        let first = try #require(harness.rows.first)
        let firstID = try #require(first.id)
        try harness.store.updateTranscription(id: firstID, rawText: "from history", text: "From History.", status: .notInserted)

        let id = await saveRetryResult(harness, of: first)
        #expect(id != firstID)
        #expect(harness.rows.count == 2)
        let kept = try #require(harness.rows.first { $0.id == firstID })
        #expect(kept.text == "From History.", "what History wrote is not overwritten")
        #expect(kept.audioPath == first.audioPath, "and it keeps its audio")
        let fresh = try #require(harness.rows.first { $0.id == id })
        #expect(fresh.text == "Ship it on Thursday.")
        #expect(fresh.audioPath == nil, "one audio file for the recording: the retry writes no second one")
        if let path = first.audioPath { try? FileManager.default.removeItem(atPath: path) }
    }

    @Test("a first attempt still saves a new row each time")
    func firstAttemptsAreSeparateRows() async throws {
        let harness = try Harness()
        #expect(await harness.failOnce())
        harness.pill.dismissFailure()
        harness.controller.finishForTests(samples: Harness.speech)
        #expect(await harness.eventually { harness.rows.count == 2 })
    }

    // MARK: The next dictation, through the hotkey path

    @Test("a key press that reaches the controller replaces the failure row and lets its audio go")
    func keyPressReplacesTheRow() async throws {
        let harness = try Harness()
        #expect(await harness.failOnce())
        // The monitor's own callback, as the event tap calls it. With no model the press goes no
        // further than the model check (a microphone is never opened in a test).
        harness.hotkeys.onEvent?(.pressed)
        #expect(harness.pill.state == .error(harness.modelStatus.label))
        harness.pill.retryFailure()
        #expect(!harness.controller.isBusy, "the kept audio went with the row")
    }

    @Test("dismissing the row lets the audio go: Try again has nothing left to run")
    func dismissedRowKeepsNothing() async throws {
        let harness = try Harness()
        #expect(await harness.failOnce())
        harness.pill.dismissFailure()
        harness.pill.state = .failed(.transcription(recordingKept: true))
        harness.pill.retryFailure()
        #expect(!harness.controller.isBusy)
    }
}
