import Foundation
import MurmurCore
import Observation
import os

/// Transcribes an imported audio/video file into a `Note` the way a recording is made (meetings schema freeze
/// sections 3 and 4): the decoded audio goes into the capture journal as `capture_segment(stream = 'file')` rows and
/// `seg-<seq>-file.hseg` files (`CaptureJournalWriter`, cut at pauses about every 30 s), each sealed segment is
/// recognised into its import turn as it comes (`SegmentTranscriber`), and the note is finished by the same
/// `FinalizeRunner` steps as a recording (sealing, transcribing, assembling, writing, exporting). So Try again,
/// playback and Erase read the same journal, and a multi-hour file never sits in memory: at most one open segment.
///
/// Decode → journal → recognise run off the main actor at utility priority (`Task.detached` plus a `nonisolated`
/// `run()`), and recognition waits for a dictation in progress before each segment, as a recording's does. Progress
/// and cancellation are surfaced through `@Observable` state so `ImportQueue`/the import UI can show a progress bar
/// with a Cancel button per file.
///
/// **Storage choice**: the original file is not copied into app storage, only the 16 kHz mono journal segments
/// under `Notes/<noteId>/`, so a multi-hour import does not double the user's disk usage and the note is
/// self-contained afterward: the original can move or be deleted without breaking retry or playback. "Show original
/// file" is offered only while `sourcePath` still resolves. The source is read exactly once, during import, so a
/// plain path is all this needs (a security-scoped bookmark is for repeated access).
///
/// A cancelled or failed import keeps the segments it wrote and ends needing attention (failed, with Try again),
/// which recognises what was saved. Imports from before the journal (`chunk-%04d.wav` files) are adopted as `file`
/// rows by the runner's sealing step on Try again, and play from their chunk files until then.
@MainActor
@Observable
final class FileTranscriber {
    enum State: Equatable {
        case idle
        case decoding(progress: Double?)
        case transcribing(progress: Double?)
        case done(noteID: Int64)
        case failed(String)
        case cancelled
    }

    private(set) var state: State = .idle
    nonisolated let fileURL: URL
    /// Display name for the queue UI; the original filename without its extension, matching
    /// how the created note's title is chosen (see `createNote()`).
    nonisolated let displayName: String

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let pipeline: DictationPipeline
    @ObservationIgnored private let encryption: EncryptionController
    @ObservationIgnored private let vocabulary: VocabularyContext
    @ObservationIgnored private let cleanupLevel: CleanupLevel
    @ObservationIgnored private let finalizer: FinalizeRunner
    @ObservationIgnored private nonisolated let log = Logger(subsystem: "app.hushy", category: "file-import")
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        fileURL: URL, speech: SpeechEngine, store: Store, settings: AppSettings,
        encryption: EncryptionController, vocabulary: VocabularyContext, finalizer: FinalizeRunner
    ) {
        self.fileURL = fileURL
        self.displayName = fileURL.deletingPathExtension().lastPathComponent
        self.pipeline = DictationPipeline(transcriber: speech)
        self.store = store
        self.encryption = encryption
        self.vocabulary = vocabulary
        self.cleanupLevel = settings.noteCleanupLevel
        self.finalizer = finalizer
    }

    var isRunning: Bool {
        switch state {
        case .decoding, .transcribing: true
        default: false
        }
    }

    /// Starts decoding/transcribing. Safe to call once; a second call while already running is a
    /// no-op, matching `NoteRecorder.start()`'s guard.
    func start() {
        guard case .idle = state else { return }
        state = .decoding(progress: nil)
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Decoded audio goes to the journal a tick at a time, so the writer can cut each segment at a pause.
    nonisolated static let tickSamples = Int(StreamingResampler.targetRate)

    /// The whole decode/journal/recognise pipeline, `nonisolated` so it genuinely runs off the main actor (a
    /// `Task.detached` calling an `@MainActor` method would just hop back to the main actor for the method's whole
    /// body). Every touch of actor-isolated state goes through an explicit `MainActor.run` hop.
    nonisolated private func run() async {
        var started: (note: Note, journal: CaptureJournalWriter)?
        do {
            let (note, journal, foreground) = try await createNote()
            started = (note, journal)
            guard let id = note.id else { throw CaptureSession.Failure.noNote }
            let estimatedDuration = try? await MediaDecoder.duration(of: fileURL)
            let transcriber = SegmentTranscriber(
                pipeline: pipeline, store: store, vocabulary: vocabulary, clean: NoteRecorder.cleaner(level: cleanupLevel))
            let sampleRate = StreamingResampler.targetRate
            var totalSamples = 0
            await updateState(.decoding(progress: 0))
            for try await chunk in MediaDecoder.stream(contentsOf: fileURL) {
                try Task.checkCancellation()
                totalSamples += chunk.count
                if let estimatedDuration, estimatedDuration > 0 {
                    await updateState(.decoding(progress: min(1, Double(totalSamples) / sampleRate / estimatedDuration)))
                }
                var offset = 0
                while offset < chunk.count {
                    let end = min(chunk.count, offset + Self.tickSamples)
                    await recognise(try await journal.append(.file, Array(chunk[offset..<end])), transcriber, foreground)
                    offset = end
                }
            }
            try Task.checkCancellation()
            await recognise(try await journal.sealAll(), transcriber, foreground)
            await updateState(.transcribing(progress: 1))
            let status = try await finish(noteId: id, durationSeconds: Double(totalSamples) / sampleRate)
            await updateState(ImportOutcome.finalState(noteID: id, status: status))
        } catch is CancellationError {
            await markIncomplete(started, reason: "cancelled")
            await MainActor.run { self.state = .cancelled }
        } catch {
            log.error("import failed: \(error.localizedDescription)")
            await markIncomplete(started, reason: "importFailed")
            let message = error.localizedDescription
            await MainActor.run { self.state = .failed(message) }
        }
    }

    nonisolated private func updateState(_ newState: State) async {
        await MainActor.run { self.state = newState }
    }

    /// The note (titled with the file's name), its journal at `capturing`, and the dictation flag recognition yields to.
    nonisolated private func createNote() async throws -> (Note, CaptureJournalWriter, ForegroundActivity?) {
        try await MainActor.run {
            var note = Note(
                title: self.displayName, createdAt: Date(), status: .recording,
                source: .file, sourcePath: self.fileURL.path)
            note = try self.store.save(note)
            guard let id = note.id else { throw CaptureSession.Failure.noNote }
            let folder = AppPaths.notesAudioDirectory.appendingPathComponent("\(id)", isDirectory: true)
            note.audioPath = folder.path
            note = try self.store.save(note)
            try self.store.advanceFinalize(noteId: id, from: nil, to: .capturing, pipelineVersion: Store.finalizePipelineVersion)
            let journal = CaptureJournalWriter(
                store: self.store, noteId: id, folder: folder, key: self.encryption.currentKey, streams: [.file])
            return (note, journal, self.finalizer.foreground)
        }
    }

    /// Recognises sealed segments in order, each after any dictation in progress. A segment that fails three times is
    /// a failed gap and the note goes on, as a recording's does.
    nonisolated private func recognise(
        _ sealed: [CaptureJournalWriter.Sealed], _ transcriber: SegmentTranscriber, _ foreground: ForegroundActivity?
    ) async {
        for part in sealed {
            await foreground?.waitUntilIdle(pollInterval: .milliseconds(50))
            _ = await transcriber.transcribe(part.segment, samples: part.samples)
        }
    }

    /// Hands the note to the finalize runner (the steps a recording takes after stop) and returns its end status.
    nonisolated private func finish(noteId: Int64, durationSeconds: Double) async throws -> Note.Status {
        let run = try await MainActor.run { () -> Task<FinalizeStep, Never> in
            if var note = try self.store.note(id: noteId) {
                note.durationSeconds = durationSeconds
                _ = try self.store.update(note)
            }
            try self.store.advanceFinalize(
                noteId: noteId, from: .capturing, to: .sealing, pipelineVersion: Store.finalizePipelineVersion)
            return self.finalizer.run(noteId: noteId)
        }
        _ = await run.value
        return await MainActor.run { (try? self.store.note(id: noteId))?.status ?? .failed }
    }

    /// A cancelled or failed import: what was decoded is sealed and kept, and the note ends needing attention (failed,
    /// with Try again), so the runner never finishes it on its own as if it were the whole file.
    nonisolated private func markIncomplete(_ started: (note: Note, journal: CaptureJournalWriter)?, reason: String) async {
        guard let started, let id = started.note.id else { return }
        _ = try? await started.journal.sealAll()
        await MainActor.run {
            try? self.store.setFinalize(noteId: id, step: .needsAttention, reason: reason)
            _ = try? self.store.setNoteStatus(id: id, .failed)
        }
    }
}
