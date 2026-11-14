import CryptoKit
import Foundation
import MurmurCore
import Observation
import os

/// Transcribes an imported audio/video file into a `Note`, reusing the same 30 s progressive-
/// chunking shape as `NoteRecorder` (see its doc comment) so a multi-hour file transcribes with
/// constant memory rather than needing its whole decoded waveform in memory at once.
///
/// Decode → chunk → transcribe all run off the main actor at utility priority (`Task.detached`
/// plus a `nonisolated` `run()`), since a multi-hour import should not compete with UI work or
/// with an active dictation for scheduling priority. Progress and cancellation are surfaced
/// through `@Observable` state (updated via `MainActor.run` hops) so `ImportQueue`/the import UI
/// can show a progress bar with a Cancel button per file.
///
/// **Storage choice**: like `NoteRecorder`, this does not copy the *original* file into app
/// storage — only the re-encoded 16 kHz mono chunk WAVs it produces while transcribing (same
/// `chunk-%04d.wav` layout under `Notes/<noteId>/`), which is what History's retry-from-chunks
/// path already knows how to read. This keeps a multi-hour import from doubling the user's disk
/// usage (the file plus a full copy), matches the storage model recordings already use, and means
/// the note is fully self-contained afterward — the original file can move, be renamed, or be
/// deleted without breaking retry or the note's own audio playback. The trade-off is that "Show
/// original file" is only offered while `sourcePath` still resolves; if the user moves/deletes the
/// source after import, the note itself (transcript, summary, chunk audio) is unaffected. This is
/// documented instead of using a security-scoped bookmark because bookmarks are for *repeated,
/// indefinite* access to a user-picked location (e.g. an app that keeps reopening a folder) — this
/// feature reads the source file exactly once, during import, so a bookmark would only add API
/// surface without a matching benefit; a plain path (resolved once, at import time, while the
/// sandbox/Open Panel access grant is still active) is all this needs.
@MainActor
@Observable
final class FileTranscriber {
    /// One chunk of decoded audio waiting to be cut and transcribed, matching `NoteRecorder`'s
    /// pause-aware cut so an import's chunk boundaries don't land mid-word any more than a live
    /// recording's do.
    nonisolated static let chunkSeconds: Double = 30

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
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private nonisolated let log = Logger(subsystem: "app.hushy", category: "file-import")
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        fileURL: URL, speech: SpeechEngine, store: Store, settings: AppSettings,
        encryption: EncryptionController, vocabulary: VocabularyContext
    ) {
        self.fileURL = fileURL
        self.displayName = fileURL.deletingPathExtension().lastPathComponent
        self.pipeline = DictationPipeline(transcriber: speech)
        self.store = store
        self.settings = settings
        self.encryption = encryption
        self.vocabulary = vocabulary
        self.cleanupLevel = settings.noteCleanupLevel
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

    /// The whole decode/chunk/transcribe pipeline, `nonisolated` so it genuinely runs off the
    /// main actor (a `Task.detached` calling an `@MainActor` method would just hop back to the
    /// main actor for the method's whole body). Every touch of actor-isolated state — `store`,
    /// `settings`, `encryption`, and `self.state` itself — goes through an explicit
    /// `MainActor.run` hop; everything else (decoding, chunk splitting, ASR, cleanup) runs on
    /// whatever executor the detached task was given.
    nonisolated private func run() async {
        var noteID: Int64?
        do {
            let note = try await createNote()
            noteID = note.id
            let estimatedDuration = try? await MediaDecoder.duration(of: fileURL)

            let folder = URL(fileURLWithPath: note.audioPath ?? "", isDirectory: true)
            let key = await MainActor.run { self.encryption.currentKey }
            var chunkIndex = 0
            var pending: [Float] = []
            var totalSamples = 0
            var tally = ImportChunkTally()
            let sampleRate = StreamingResampler.targetRate
            let chunkSamples = Int(Self.chunkSeconds * sampleRate)

            await updateState(.decoding(progress: 0))

            for try await chunk in MediaDecoder.stream(contentsOf: fileURL) {
                try Task.checkCancellation()
                pending.append(contentsOf: chunk)
                totalSamples += chunk.count
                if let estimatedDuration, estimatedDuration > 0 {
                    let progress = min(1, Double(totalSamples) / sampleRate / estimatedDuration)
                    await updateState(.decoding(progress: progress))
                }
                let (readyChunks, leftover) = ImportChunker.cutChunks(
                    pending: pending, totalDecodedSamples: totalSamples, chunkSamples: chunkSamples, sampleRate: sampleRate)
                pending = leftover
                for readyChunk in readyChunks {
                    do {
                        let result = try await transcribe(
                            readyChunk.samples, chunkIndex: chunkIndex, folder: folder, key: key,
                            offsetSeconds: readyChunk.offsetSeconds)
                        tally.record(text: result.text, words: result.words)
                    } catch {
                        tally.recordFailure()
                        log.error("import chunk \(chunkIndex) failed: \(error.localizedDescription)")
                    }
                    chunkIndex += 1
                }
            }

            try Task.checkCancellation()

            // Final partial chunk.
            if !pending.isEmpty {
                let offsetSeconds = ImportChunker.finalChunkOffsetSeconds(
                    totalDecodedSamples: totalSamples, remainingSamples: pending.count, sampleRate: sampleRate)
                do {
                    let result = try await transcribe(pending, chunkIndex: chunkIndex, folder: folder, key: key, offsetSeconds: offsetSeconds)
                    tally.record(text: result.text, words: result.words)
                } catch {
                    tally.recordFailure()
                    log.error("import final chunk failed: \(error.localizedDescription)")
                }
            }

            let durationSeconds = Double(totalSamples) / sampleRate
            await updateState(.transcribing(progress: 1))
            try await finalize(note: note, tally: tally, durationSeconds: durationSeconds)
        } catch is CancellationError {
            await markFailed(noteID: noteID)
            await MainActor.run { self.state = .cancelled }
        } catch {
            log.error("import failed: \(error.localizedDescription)")
            await markFailed(noteID: noteID)
            let message = error.localizedDescription
            await MainActor.run { self.state = .failed(message) }
        }
    }

    nonisolated private func updateState(_ newState: State) async {
        await MainActor.run { self.state = newState }
    }

    nonisolated private func createNote() async throws -> Note {
        try await MainActor.run {
            var note = Note(
                title: self.displayName, createdAt: Date(), status: .recording,
                source: .file, sourcePath: self.fileURL.path)
            note = try self.store.save(note)
            let folder = AppPaths.notesAudioDirectory.appendingPathComponent("\(note.id ?? 0)", isDirectory: true)
            note.audioPath = folder.path
            note = try self.store.save(note)
            return note
        }
    }

    /// One chunk's cleaned text plus its word timings, shifted to whole-file-relative seconds.
    private struct ChunkResult {
        let text: String
        let words: [WordTiming]
        static let empty = ChunkResult(text: "", words: [])
    }

    /// Writes the chunk's WAV (same layout as `NoteRecorder`, so retry-from-chunks works
    /// identically) and transcribes it with word timings (`DictationPipeline.transcribeRawWithTimings`,
    /// the same shared path `NoteRecorder` uses for live recordings — see
    /// `.claude/DECISIONS.md`'s file-import/speaker-labels reconciliation entry), offsetting
    /// those timings by `offsetSeconds` so they read as absolute positions in the whole file.
    nonisolated private func transcribe(
        _ samples: [Float], chunkIndex: Int, folder: URL, key: SymmetricKey?, offsetSeconds: Double
    ) async throws -> ChunkResult {
        guard !samples.isEmpty else { return .empty }
        try WAVWriter.write(samples, to: folder.appendingPathComponent(String(format: "chunk-%04d.wav", chunkIndex)), key: key)
        let result = try await pipeline.transcribeRawWithTimings(samples, vocabulary: vocabulary)
        let options = CleanupOptions(level: cleanupLevel, voiceCommandsEnabled: false)
        let cleaned = TextCleaner(options: options).clean(result.text).text
        let words = (result.timings ?? []).map {
            WordTiming(word: $0.word, start: $0.start + offsetSeconds, end: $0.end + offsetSeconds)
        }
        return ChunkResult(text: cleaned, words: words)
    }

    nonisolated private func finalize(note: Note, tally: ImportChunkTally, durationSeconds: Double) async throws {
        let transcript = tally.transcript
        let words = tally.words
        let digest = await SmartCleaner.summarize(transcript, fallbackTitle: displayName)
        let finalStatus = tally.finalStatus

        let result: State = try await MainActor.run {
            var updated = note
            if let id = note.id {
                // The file's words are the note's one import turn; the transcript is its cache.
                let turn = NoteTurn(
                    noteId: id, ordinal: 0, stream: .file, t0: 0, t1: durationSeconds, text: transcript,
                    words: words.isEmpty ? nil : words.map { NoteTurn.Word(w: $0.word, start: $0.start, end: $0.end, conf: 1) },
                    origin: .imported)
                try self.store.replaceTurns(noteId: id, turns: transcript.isEmpty ? [] : [turn])
            }
            updated.durationSeconds = durationSeconds
            updated.summary = digest.summary
            updated.setActionItems(from: digest)
            // Unlike a live recording, an imported file keeps its original filename as the
            // title (per the feature spec) rather than adopting the summarizer's generated one.
            updated.status = finalStatus
            updated = try self.store.save(updated)
            if let id = updated.id, !words.isEmpty {
                // One note_segment row per word, speakerId nil (a file import never runs
                // diarization — see .claude/DECISIONS.md). Reuses the same
                // replaceSpeakerSegments(noteId:speakers:segments:) API SpeakerDiarizer uses for
                // live recordings, with an empty speaker roster and speakerIndex nil throughout;
                // AlignedSegment.speakerLabel is unused when speakerIndex is nil.
                let wordSegments = words.map { (speakerIndex: Int?.none, segment: AlignedSegment(speakerLabel: "", start: $0.start, end: $0.end, text: $0.word)) }
                try self.store.replaceSpeakerSegments(noteId: id, speakers: [], segments: wordSegments)
            }
            if updated.status == .ready, self.settings.exportNotesToMarkdown, let id = updated.id {
                _ = try? MarkdownExporter.export(updated, transcript: try? self.store.transcript(noteId: id), to: self.settings.exportDirectory)
            }
            return ImportChunkTally.finalState(noteID: updated.id, status: finalStatus)
        }
        await MainActor.run { self.state = result }
    }

    /// A cancelled or failed import keeps whatever chunk audio/transcript it produced so far —
    /// same "recover, don't discard" policy `NoteRecorder` uses for a failed recording — rather
    /// than deleting the note. The user can retry transcription from the saved chunks, or delete
    /// it from Notes like any other incomplete recording.
    nonisolated private func markFailed(noteID: Int64?) async {
        guard let noteID else { return }
        await MainActor.run {
            guard var note = try? self.store.note(id: noteID) else { return }
            note.status = .failed
            _ = try? self.store.save(note)
        }
    }
}
