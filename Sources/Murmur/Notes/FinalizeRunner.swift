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
        await SmartCleaner.summarize($0, fallbackTitle: $1)
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
                let hasTurns = !(try store.turns(noteId: noteId)).isEmpty
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
                store: store, noteId: id, folder: folder, key: encryption.currentKey, readLegacy: Self.readLegacy)
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
        case .exporting:
            if let current = try store.note(id: id) { export(current) }
        case .capturing, .done, .needsAttention:
            return
        }
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
        let key = encryption.currentKey
        let diarizer = self.diarizer
        let store = self.store
        let owner = settings.userName
        let clean = NoteRecorder.cleaner(level: settings.noteCleanupLevel)
        let shouldDiarize = FeatureFlags.speakerLabels
        let voices = encryption.voiceSignatureStore
        await foreground?.waitUntilIdle(pollInterval: .milliseconds(50))
        await Task.detached(priority: .utility) {
            await diarizer.assembleAndSave(
                note: note, micWords: micWords, systemWords: systemWords, isTwoChannel: isTwoChannel, ownerName: owner,
                diarize: shouldDiarize, clean: clean, store: store,
                loadAudio: { stream in
                    guard let folder else { return [] }
                    return try CaptureSegmentAudio.timeline(journal, stream: stream, folder: folder, key: key,
                                                            readLegacy: FinalizeRunner.readLegacy)
                },
                voiceSignatureStore: voices)
        }.value
    }

    /// The non-echo words of turns, in time order, as the assembler reads them.
    static func timings(_ turns: [NoteTurn]) -> [MurmurCore.WordTiming] {
        turns.flatMap { turn in (turn.words ?? []).filter { $0.flags & NoteTurn.Word.echo == 0 } }
            .sorted { $0.start < $1.start }
            .map { MurmurCore.WordTiming(word: $0.w, start: $0.start, end: $0.end) }
    }
}
