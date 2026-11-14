import Foundation
import MurmurCore
import Observation
import os

/// Records long memos and meetings into the capture journal (meetings schema freeze section 3).
///
/// Every journal tick (1 s) each side's new audio is appended to its open segment file and synced, so a crash, a
/// kill or a quit loses at most one tick (notes audit B3). About every 30 s a segment is sealed at a pause and
/// recognised in the background, so the live screen fills in as the meeting goes. Capture health watches both
/// sides and rebuilds one that stalls (notes audit B4). On stop the journal is sealed and the `FinalizeRunner`
/// finishes the note in the background; on the next launch it resumes any note a quit or crash interrupted.
@MainActor
@Observable
final class NoteRecorder {
    /// The journal tick: how often audio reaches the disk.
    static let tickSeconds: Double = 1
    /// Recognition still works in about 30 s parts (the segment length).
    static let chunkSeconds: Double = CaptureJournalWriter.segmentSeconds

    var activeNote: Note?
    private(set) var isFinishing = false
    var liveTranscript = ""
    /// The note being recognised again after Try again.
    private(set) var retryingNoteID: Int64?
    /// When each side of the recording last heard speech, and whether a side has died, for the live screen.
    var capture: MeetingCapture?
    /// Seconds of the recording already transcribed (the end of the last recognised segment).
    var transcribedSeconds: Double = 0
    /// Both sides of the call as they are transcribed, one entry per side per segment, for the live screen.
    var liveTurns: [LiveTurn] = []

    struct LiveTurn: Identifiable, Equatable {
        enum Side { case you, call }
        var id: String { "\(part)-\(side)" }
        let part: Int
        let side: Side
        let startSeconds: Double
        let text: String
    }

    /// A note never keeps its whole recording in memory: drained audio is on disk (notes audit B5).
    @ObservationIgnored let audio: AudioCapture = {
        let capture = AudioCapture()
        capture.retainsFullRecording = false
        return capture
    }()
    /// Makes the microphone capture throw unless it is on the selected device. Off in the app.
    @ObservationIgnored var requiresSelectedInputDevice = false
    @ObservationIgnored let systemAudio: SystemAudioCapture = {
        let capture = SystemAudioCapture()
        capture.retainsFullRecording = false
        return capture
    }()
    /// The meeting-journal harness's sides in place of the microphone and the call tap. Nil in the app.
    @ObservationIgnored var makeMicSource: (() -> any NoteAudioSource)?
    @ObservationIgnored var makeCallSource: (() -> any NoteAudioSource)?

    @ObservationIgnored let speech: SpeechEngine
    @ObservationIgnored let pipeline: DictationPipeline
    @ObservationIgnored let modelStatus: SpeechModelStatus
    @ObservationIgnored let store: Store
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let pill: PillModel
    @ObservationIgnored let encryption: EncryptionController
    @ObservationIgnored let log = Logger(subsystem: "app.hushy", category: "notes")
    /// Finishes notes from their journal, live ones after stop and interrupted ones at launch.
    @ObservationIgnored let finalizer: FinalizeRunner

    // The recording in progress. All of it is reset by `start`.
    @ObservationIgnored var session: CaptureSession?
    @ObservationIgnored var chunkTimer: Timer?
    @ObservationIgnored var startedAt = Date()

    /// Kept in sync with `Library.onPersonalizationChange` (see `AppModel`), so note segments get the same
    /// vocabulary boosting as dictation.
    @ObservationIgnored var personalizer = Personalizer()

    var onChange: (() -> Void)?
    /// Usage numbers: a recording started, finished (ready) or was discarded. Whole minutes only.
    @ObservationIgnored var onMeetingMetric: ((MeetingMetricEvent) -> Void)?
    /// Titles a note after the calendar meeting it starts in.
    @ObservationIgnored var calendarNamer: NoteCalendarNamer?

    /// Title and transcript in, summary out (the finalize runner's).
    var summarize: (_ transcript: String, _ fallbackTitle: String) async -> ExtractiveSummarizer.Output {
        get { finalizer.summarize }
        set { finalizer.summarize = newValue }
    }
    var appleNotesScripter: any AppleNotesScripting {
        get { finalizer.appleNotesScripter }
        set { finalizer.appleNotesScripter = newValue }
    }
    var beforeExport: ((_ export: String) -> Void)? {
        get { finalizer.beforeExport }
        set { finalizer.beforeExport = newValue }
    }

    init(
        speech: SpeechEngine, modelStatus: SpeechModelStatus, store: Store, settings: AppSettings, pill: PillModel,
        encryption: EncryptionController
    ) {
        self.speech = speech
        let pipeline = DictationPipeline(transcriber: speech)
        self.pipeline = pipeline
        self.modelStatus = modelStatus
        self.store = store
        self.settings = settings
        self.pill = pill
        self.encryption = encryption
        finalizer = FinalizeRunner(
            store: store, pipeline: pipeline, settings: settings, encryption: encryption, diarizer: SpeakerDiarizer())
        finalizer.isLive = { [weak self] id in self?.activeNote?.id == id }
        finalizer.vocabulary = { [weak self] in PipelineSettings(personalizer: self?.personalizer ?? Personalizer()).vocabulary }
        finalizer.onChange = { [weak self] in self?.onChange?() }
    }

    var isRecording: Bool { activeNote != nil && !isFinishing }
    /// A note is being finished in the background (sealed, recognised, assembled or summarised).
    var isFinalizing: Bool { !finalizer.runningNoteIDs.isEmpty }
    var isCapturingSystemAudio: Bool { session?.callSource != nil }

    /// Seconds into the recording in progress, for stamping a typed line with its moment.
    var elapsedSeconds: Double? { isRecording ? max(0, Date().timeIntervalSince(startedAt)) : nil }

    /// - Parameter meetingApp: the app a call-detected note came from, for its meta line; nil for a manual start.
    func start(meetingApp: MeetingApp? = nil) async throws {
        guard activeNote == nil else { return }
        startedAt = Date()
        let title = "Note · " + startedAt.formatted(date: .omitted, time: .shortened)
        var note = Note(title: title, createdAt: startedAt, status: .recording, meetingApp: meetingApp)
        note = try store.save(note)
        guard let noteId = note.id else { throw CaptureSession.Failure.noNote }
        let folder = AppPaths.notesAudioDirectory.appendingPathComponent("\(noteId)", isDirectory: true)
        note.audioPath = folder.path
        do {
            note = try store.save(note)
            try store.advanceFinalize(noteId: noteId, from: nil, to: .capturing, pipelineVersion: Store.finalizePipelineVersion)
        } catch {
            try? store.setNoteStatus(id: noteId, .failed)
            throw error
        }

        let journal = CaptureJournalWriter(
            store: store, noteId: noteId, folder: folder, key: encryption.currentKey, streams: [.mic])
        let mic = makeMicSource?() ?? defaultMicSource()
        let session = CaptureSession(noteId: noteId, journal: journal, mic: mic)
        self.session = session
        liveTranscript = ""
        transcribedSeconds = 0
        liveTurns = []
        capture = MeetingCapture(startedAt: startedAt, isCapturingCall: false,
                                 callRequested: makeCallSource != nil || (settings.recordCallAudio && Entitlements.has(.systemAudio)))
        do {
            try await mic.start { [weak self] rms in
                Task { @MainActor in
                    guard let self, self.isRecording, self.activeNote?.id == noteId else { return }
                    self.pill.push(rms: rms)
                    self.noteHeard(.microphone, rms: rms)
                }
            }
        } catch {
            await mic.stop()
            journal.abandon()
            self.session = nil
            capture = nil
            try? store.setNoteStatus(id: noteId, .failed)
            try? store.setFinalize(noteId: noteId, step: .needsAttention, reason: "micStart")
            onChange?()
            throw error
        }
        await startCallSide(session, noteId: noteId)

        activeNote = note
        pill.resetLevels()
        pill.isCapturingCallAudio = session.callSource != nil
        pill.state = .recordingNote(startedAt: startedAt)
        chunkTimer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        onChange?()
        nameFromCalendar(note, defaultTitle: title)
        onMeetingMetric?(MeetingMetricEvent(outcome: .started, minutesRecorded: nil))
    }

    private func defaultMicSource() -> any NoteAudioSource {
        MicrophoneSelector.shared.prepare(audio, picked: settings.inputDeviceName)
        audio.strictDevice = requiresSelectedInputDevice
        audio.voiceProcessing = settings.reduceBackgroundNoise
        return MicrophoneNoteSource(capture: audio)
    }

    /// The call's audio is best-effort and additive: any failure falls back to a mic-only note.
    private func startCallSide(_ session: CaptureSession, noteId: Int64) async {
        let source: (any NoteAudioSource)?
        if let makeCallSource {
            source = makeCallSource()
        } else if settings.recordCallAudio, Entitlements.has(.systemAudio), SystemAudioCapture.permissionState().canCapture {
            source = CallNoteSource(capture: systemAudio)
        } else {
            source = nil
        }
        guard let source else { return }
        do {
            try await source.start { [weak self] rms in
                Task { @MainActor in
                    guard let self, self.isRecording, self.activeNote?.id == noteId else { return }
                    self.noteHeard(.call, rms: rms)
                }
            }
            let at = session.elapsed()
            await session.journal.addStream(.system, at: at)
            session.attachCall(source, at: at)
            capture?.isCapturingCall = true
        } catch {
            log.error("system audio capture unavailable, continuing mic-only: \(error.localizedDescription)")
        }
    }

    /// Writes a level reading into `capture`, at most about once a second per side.
    private func noteHeard(_ side: MeetingCapture.Side, rms: Float) {
        guard var current = capture, rms >= MeetingCapture.heardFloor else { return }
        let now = Date()
        let last = side == .microphone ? current.microphoneLastHeard : current.callLastHeard
        if let last, now.timeIntervalSince(last) < 1 { return }
        current.heard(side, rms: rms, at: now)
        capture = current
    }

    /// Looks for the calendar meeting this note started in, without holding up the recording.
    private func nameFromCalendar(_ note: Note, defaultTitle: String) {
        guard let noteID = note.id, let namer = calendarNamer else { return }
        namer.begin(noteID: noteID, startedAt: startedAt, defaultTitle: defaultTitle) { [weak self] title in
            guard let self, self.activeNote?.id == noteID else { return }
            self.activeNote?.title = title
            self.onChange?()
        }
    }

    /// Stops capture at once and hands back the note, with nothing transcribed or saved. The pill's cancel (which
    /// confirms first); the caller deletes the note's row and audio.
    @discardableResult
    func discardActive() -> Note? {
        guard let note = activeNote, !isFinishing else { return nil }
        onMeetingMetric?(MeetingMetricEvent(
            outcome: .discarded, minutesRecorded: Int(Date().timeIntervalSince(startedAt) / 60)))
        chunkTimer?.invalidate()
        chunkTimer = nil
        if let session {
            session.journal.abandon()
            session.cancel()
            Task { await session.stopSources() }
        }
        session = nil
        activeNote = nil
        liveTranscript = ""
        capture = nil
        clearCaptureNotice()
        pill.isCapturingCallAudio = false
        pill.state = .idle
        onChange?()
        return note
    }

    /// Uninstall: discards a recording in progress and returns once nothing of a note is still being written.
    /// The waiting comes first and destroys nothing; `isStillWanted` is asked after it, in the discard's turn.
    func discardForUninstall(isStillWanted: () -> Bool = { true }) async -> Note? {
        await waitUntilQuiet()
        guard isStillWanted() else { return nil }
        let pending = session?.recognitions
        let sources = session
        guard let discarded = discardActive() else { return nil }
        await sources?.stopSources()
        await pending?.value
        return discarded
    }

    /// Returns once no note is being finished or recognised again and no segment of a recording in progress is
    /// being recognised. Nothing is stopped to get there.
    private func waitUntilQuiet() async {
        var finished: Task<Void, Never>?
        while true {
            if isFinishing || retryingNoteID != nil || isFinalizing {
                try? await Task.sleep(for: Self.uninstallPoll)
            } else if let queue = session?.recognitions, queue != finished {
                await queue.value
                finished = queue
            } else {
                return
            }
        }
    }

    private static let uninstallPoll: Duration = .milliseconds(100)

    func stop() {
        guard let note = activeNote, let noteId = note.id, let session, !isFinishing else { return }
        isFinishing = true
        chunkTimer?.invalidate()
        chunkTimer = nil
        pill.isCapturingCallAudio = false
        pill.state = .processing()
        let shownRevision = pill.stateRevision
        onChange?()
        Task {
            await session.stopSources()
            await self.finishCapture(session)
            let minutes = Int(Date().timeIntervalSince(self.startedAt) / 60)
            self.activeNote = nil
            self.session = nil
            self.isFinishing = false
            self.liveTranscript = ""
            self.capture = nil
            self.clearCaptureNotice()
            self.onChange?()
            let step = await self.finalizer.run(noteId: noteId, after: session.recognitions).value
            self.reportFinished(noteId: noteId, step: step, minutes: minutes, shownRevision: shownRevision)
        }
    }

    /// The pill after a live note finished in the background, unless a dictation has taken the pill since.
    private func reportFinished(noteId: Int64, step: FinalizeStep, minutes: Int, shownRevision: UInt64) {
        let note = try? store.note(id: noteId)
        if step == .done, note?.status == .ready {
            onMeetingMetric?(MeetingMetricEvent(outcome: .completed, minutesRecorded: minutes))
        }
        guard pill.stateRevision == shownRevision, case .processing = pill.state else { return }
        guard let note else {
            pill.state = .idle
            return
        }
        if note.status == .ready {
            pill.state = .done(words: note.wordCount)
            let completionRevision = pill.stateRevision
            Task {
                try? await Task.sleep(for: .seconds(1))
                if self.pill.stateRevision == completionRevision { self.pill.state = .idle }
            }
        } else {
            pill.present(failure: .noteIncomplete)
        }
    }

    /// Quit, shutdown or an update's relaunch while recording: the last tick reaches the disk, every segment is
    /// sealed and the note is left at `sealing`, so the next launch finishes it with no click. Bounded by the caller.
    func flushForQuit() async {
        guard let session, !session.isCancelled else { return }
        chunkTimer?.invalidate()
        chunkTimer = nil
        isFinishing = true
        await session.stopSources()
        await finishCapture(session)
        log.notice("recording flushed and sealed for quit; it resumes at the next launch")
    }

    /// The Mac is going to sleep: seal what is open so a sleep that never wakes loses nothing. Recording goes on.
    func checkpoint() {
        guard let session, isRecording else { return }
        session.chain { [weak self] in
            do {
                let sealed = try await session.journal.sealAll()
                self?.recognize(sealed, in: session)
            } catch {
                self?.log.error("sealing before sleep failed: \(error.localizedDescription)")
            }
        }
    }

    /// Re-transcribes a failed or interrupted note from its saved audio, both sides, then assembles and summarises
    /// it again. Does nothing while that note is recording or already being retried.
    func retryTranscription(for note: Note) {
        guard let id = note.id, id != activeNote?.id, retryingNoteID == nil else { return }
        retryingNoteID = id
        onChange?()
        finalizer.retry(noteId: id)
        let task = finalizer.run(noteId: id)
        Task {
            _ = await task.value
            self.retryingNoteID = nil
            self.onChange?()
        }
    }

    /// Writing, exporting and the end status for a note whose turns are in (the finalize runner's).
    func summarizeAndFinalize(_ note: Note, chunkFailed _: Bool = false, persistenceFailed _: Bool = false) async -> Note? {
        await finalizer.summarizeAndFinalize(note)
    }

    /// Same cleanup level as dictation; voice commands stay off because in a recording "new line" or "scratch that"
    /// is something someone said, not an instruction.
    static func cleaner(level: CleanupLevel) -> @Sendable (String) -> String {
        { text in TextCleaner(options: CleanupOptions(level: level, voiceCommandsEnabled: false)).clean(text).text }
    }
}
