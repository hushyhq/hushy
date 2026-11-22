import CryptoKit
import Foundation
import MurmurCore
import os

/// Finishes a note from its capture journal, and resumes one that a quit, crash or update left half done (meetings
/// schema freeze section 3; notes audit B3). Each step reads the journal, does its work and moves `note_finalize` on
/// with a compare-and-swap, so a killed run picks up at its step on the next launch and a repeated step changes
/// nothing. One run per note at a time.
///
/// Steps: sealing (adopt files, cut torn frames) → transcribing (both sides, segment by segment) → assembling (who
/// said what) → writing (the summary) → exporting → done. A note needs attention only when its journal holds no
/// audio and it has no turns, or a step's write failed three times.
@MainActor
final class FinalizeRunner {
    let store: Store
    private let pipeline: DictationPipeline
    let settings: AppSettings
    private let encryption: EncryptionController
    private let diarizer: SpeakerDiarizer
    let log = Logger(subsystem: "app.hushy", category: "notes")

    /// A dictation in progress (`CleanupModelController.foreground`): recognition and the summary wait for it, so a
    /// meeting finishing in the background never delays a dictation. Nil in tests.
    var foreground: ForegroundActivity?
    /// The vocabulary dictation uses, read when a run starts.
    var vocabulary: () -> VocabularyContext = { .empty }
    /// Whether a recorder still owns the note (its step stays `capturing`).
    var isLive: (Int64) -> Bool = { _ in false }
    /// Title and transcript in, summary out. Tests replace it to hold a summary open while something else happens.
    var summarize: (_ transcript: String, _ fallbackTitle: String) async -> ExtractiveSummarizer.Output = {
        await FinalizeRunner.summary($0, fallbackTitle: $1)
    }
    /// The note's facts from its turns (`MeetingFactExtractor`), with the extractor's name; `ran` is false when no
    /// model could answer, and then nothing is replaced. Tests replace it.
    var extractFacts: (_ turns: NoteTranscript, _ noteId: Int64, _ title: String, _ kind: String) async
        -> (facts: [MeetingFact], extractor: String, ran: Bool) = { turns, id, title, kind in
        await FinalizeRunner.facts(turns, noteId: id, title: title, kind: kind)
    }
    /// What the Apple Notes export runs through. Tests replace it so no export reaches the Notes app.
    var appleNotesScripter: any AppleNotesScripting = AppleNotesExporter.defaultScripter
    /// Runs just before each export, with the export's name. Tests erase the meeting here.
    var beforeExport: ((_ export: String) -> Void)?
    /// A note's state changed (for the list and the live screen).
    var onChange: (() -> Void)?

    private var running: [Int64: Task<FinalizeStep, Never>] = [:]
    var runningNoteIDs: Set<Int64> { Set(running.keys) }

    init(store: Store, pipeline: DictationPipeline, settings: AppSettings, encryption: EncryptionController,
         diarizer: SpeakerDiarizer) {
        self.store = store
        self.pipeline = pipeline
        self.settings = settings
        self.encryption = encryption
        self.diarizer = diarizer
    }

    /// Runs the note to an end, after `after` (the recorder's last live recognitions). A second call while one runs
    /// returns the same task.
    @discardableResult
    func run(noteId: Int64, after previous: Task<Void, Never>? = nil) -> Task<FinalizeStep, Never> {
        if let current = running[noteId] { return current }
        let task = Task { [weak self] () -> FinalizeStep in
            await previous?.value
            guard let self else { return .needsAttention }
            let step = await self.execute(noteId: noteId)
            self.running[noteId] = nil
            self.onChange?()
            return step
        }
        running[noteId] = task
        onChange?()
        return task
    }

    /// At launch: every note a quit, crash or update left between capture and done, oldest first, with no click.
    @discardableResult
    func resumeInterrupted() -> [Int64] {
        let ids: [Int64]
        do { ids = try store.notesToResume() } catch {
            log.error("listing notes to resume failed: \(error.localizedDescription)")
            return []
        }
        guard !ids.isEmpty else { return [] }
        log.notice("resuming \(ids.count) interrupted note(s)")
        var previous: Task<Void, Never>?
        for id in ids where !isLive(id) {
            let before = previous
            let task = run(noteId: id, after: before)
            previous = Task { _ = await task.value }
        }
        return ids
    }

    /// Try again: the note's saved audio is recognised again, both sides (notes audit B2), from sealing.
    func retry(noteId: Int64) {
        guard running[noteId] == nil, !isLive(noteId) else { return }
        do {
            try store.resetSegmentsForRetranscription(noteId: noteId)
            try store.setFinalize(noteId: noteId, step: .sealing, reason: "retry")
        } catch {
            log.error("retry of note \(noteId) could not start: \(error.localizedDescription)")
            return
        }
        run(noteId: noteId)
    }

    // MARK: - The loop

    private func execute(noteId: Int64) async -> FinalizeStep {
        var statusSet = false
        // Each pass does one step; a step that cannot finish (recognition retrying) repeats, bounded here.
        for _ in 0..<64 {
            guard let state = try? store.finalizeState(noteId: noteId), let note = try? store.note(id: noteId) else {
                return .done   // the note was erased: nothing left to finish
            }
            let step = state.step
            switch step {
            case .done, .needsAttention:
                _ = try? store.setNoteStatus(id: noteId, step.noteStatus)
                return step
            case .capturing:
                if isLive(noteId) { return .capturing }
                _ = try? store.advanceFinalize(noteId: noteId, from: .capturing, to: .sealing,
                                               pipelineVersion: Store.finalizePipelineVersion)
                continue
            default:
                break
            }
            if !statusSet, note.status != .processing {
                _ = try? store.setNoteStatus(id: noteId, .processing)
                onChange?()
            }
            statusSet = true
            do {
                try await perform(step, note: note)
                let journal = try store.captureJournal(noteId: noteId)
                let hasTurns = try store.hasTurns(noteId: noteId)
                let next = FinalizePlan.next(after: step, journal: journal, hasTurns: hasTurns, isLive: false)
                if next == .done { _ = try store.setNoteStatus(id: noteId, .ready) }
                if next != step {
                    try store.advanceFinalize(noteId: noteId, from: step, to: next, pipelineVersion: Store.finalizePipelineVersion)
                    onChange?()
                }
            } catch {
                log.error("note \(noteId) step \(step.rawValue, privacy: .public) failed: \(error.localizedDescription)")
                let attempts = (try? store.recordFinalizeAttempt(noteId: noteId, step: step, reason: "storeWrite")) ?? nil
                if (attempts ?? FinalizePlan.maxStepAttempts) >= FinalizePlan.maxStepAttempts {
                    _ = try? store.advanceFinalize(noteId: noteId, from: step, to: .needsAttention,
                                                   reason: "storeWrite", pipelineVersion: Store.finalizePipelineVersion)
                }
            }
        }
        log.error("note \(noteId) did not reach an end in one run; it resumes at the next launch")
        return (try? store.finalizeState(noteId: noteId)?.step) ?? .needsAttention
    }

    private func perform(_ step: FinalizeStep, note: Note) async throws {
        guard let id = note.id else { return }
        switch step {
        case .sealing:
            guard let folder = note.audioPath.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
            let outcome = try CaptureJournalAdopter.adopt(
                store: store, noteId: id, folder: folder, key: encryption.currentKey, readLegacy: Self.readLegacy,
                legacyStream: note.source == .file ? .file : .mic)
            // Audio adopted from a build before the journal supersedes the transcript it saved: the one legacy turn
            // goes, and both sides are recognised again into capture turns (whose places it would otherwise hold).
            if outcome.legacy > 0 { try store.replaceTurns(noteId: id, turns: []) }
            log.notice("""
                note \(id) sealed: \(outcome.sealed) adopted, \(outcome.tornBytes) torn bytes cut, \(outcome.interrupted) \
                interrupted, \(outcome.orphans) orphan file(s), \(outcome.legacy) legacy chunk(s)
                """)
        case .transcribing:
            await transcribeSealed(note)
        case .assembling:
            await assemble(note)
        case .writing:
            guard try store.note(id: id) != nil else { return }
            _ = await write(note)
            if note.source == .file { try keepFileTitle(note) }
        case .exporting:
            if let current = try store.note(id: id) { export(current) }
        case .capturing, .done, .needsAttention:
            return
        }
    }

    /// An imported file keeps its file name as its title (the import spec), not the summary's.
    private func keepFileTitle(_ note: Note) throws {
        guard let id = note.id, var current = try store.note(id: id), current.title != note.title else { return }
        current.title = note.title
        _ = try store.update(current)
    }

    /// The summary over the turns, without decision lines: decisions are facts now, with their quotes.
    nonisolated static func summary(_ transcript: String, fallbackTitle: String) async -> ExtractiveSummarizer.Output {
        var configuration = NoteSummarizer.Configuration()
        configuration.decisionsInSummary = false
        return await NoteSummarizer.summarize(
            transcript, fallbackTitle: fallbackTitle, model: LanguageModels.meeting, configuration: configuration).output
    }

    nonisolated static func facts(_ turns: NoteTranscript, noteId: Int64, title: String, kind: String) async
        -> (facts: [MeetingFact], extractor: String, ran: Bool) {
        let model = LanguageModels.meeting
        guard model.isAvailable, !turns.isEmpty else { return ([], "", false) }
        let extractor = MeetingFactExtractor(model: model)
        let (facts, report) = await extractor.extract(turns, noteId: noteId, title: title, kind: kind)
        // Every call failed: keep what the note had rather than replace it with nothing.
        let ran = report.chunks > 0 && report.failedChunks < report.chunks
        return (facts, MeetingFactExtractor.extractorName(for: model), ran)
    }

    nonisolated static let readLegacy: CaptureJournalAdopter.LegacyReader = { url, key in try WAVWriter.read(url, key: key) }

    // MARK: - Steps

    private func transcribeSealed(_ note: Note) async {
        guard let id = note.id, let folder = note.audioPath.map({ URL(fileURLWithPath: $0, isDirectory: true) }),
              let journal = try? store.captureJournal(noteId: id) else { return }
        let transcriber = SegmentTranscriber(
            pipeline: pipeline, store: store, vocabulary: vocabulary(), clean: NoteRecorder.cleaner(level: settings.noteCleanupLevel))
        let key = encryption.currentKey
        for segment in journal.sealedAudio {
            await foreground?.waitUntilIdle(pollInterval: .milliseconds(50))
            guard (try? store.note(id: id)) != nil else { return }
            let samples: [Float]
            do {
                samples = try await Task.detached(priority: .utility) {
                    try CaptureSegmentAudio.samples(segment, folder: folder, key: key, readLegacy: Self.readLegacy)
                }.value
            } catch {
                log.error("note \(id) segment \(segment.seq) could not be read: \(error.localizedDescription)")
                if let segmentId = segment.id {
                    _ = try? store.recordSegmentFailure(id: segmentId, errorCode: "read", maxAttempts: FinalizePlan.maxSegmentAttempts)
                }
                continue
            }
            _ = await transcriber.transcribe(segment, samples: samples)
        }
    }

    /// Who said what, both sides, saved as the note's turns before its one summary. Never fails the note.
    private func assemble(_ note: Note) async {
        guard let id = note.id, let journal = try? store.captureJournal(noteId: id),
              let turns = try? store.turns(noteId: id) else { return }
        let isTwoChannel = journal.capturesCall
        guard isTwoChannel || FeatureFlags.speakerLabels else { return }
        let capture = turns.filter { $0.origin == .capture }
        let micWords = Self.timings(capture.filter { $0.stream == .mic })
        let systemWords = Self.timings(capture.filter { $0.stream == .system })
        let folder = note.audioPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let audio = SideAudio.journal(journal, folder: folder, key: encryption.currentKey, readLegacy: Self.readLegacy)
        let diarizer = self.diarizer
        let store = self.store
        let owner = settings.userName
        let clean = NoteRecorder.cleaner(level: settings.noteCleanupLevel)
        let shouldDiarize = FeatureFlags.speakerLabels
        let voices = encryption.voiceSignatureStore
        // Diarization pauses at its next window while a dictation is in progress, and goes on where it stopped.
        let yield = Self.yield(to: foreground)
        await yield()
        await Task.detached(priority: .utility) {
            await diarizer.assembleAndSave(
                note: note, micWords: micWords, systemWords: systemWords, isTwoChannel: isTwoChannel, ownerName: owner,
                diarize: shouldDiarize, clean: clean, store: store, audio: audio, yield: yield, voiceSignatureStore: voices)
        }.value
    }

    /// Waits while a dictation is in progress: the safe point heavy finalize work calls between its pieces.
    nonisolated static func yield(to foreground: ForegroundActivity?) -> @Sendable () async -> Void {
        { await foreground?.waitUntilIdle(pollInterval: .milliseconds(50)) }
    }

    /// The non-echo words of turns, in time order, as the assembler reads them.
    static func timings(_ turns: [NoteTurn]) -> [MurmurCore.WordTiming] {
        turns.flatMap { turn in (turn.words ?? []).filter { $0.flags & NoteTurn.Word.echo == 0 } }
            .sorted { $0.start < $1.start }
            .map { MurmurCore.WordTiming(word: $0.w, start: $0.start, end: $0.end) }
    }
}
