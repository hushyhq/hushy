import CryptoKit
import Foundation
import MurmurCore

/// The app's `SpeakerVoiceEmbedder`: reads a note's retained chunk files and runs the diarizer's
/// embedding model over just the selected ranges. Never downloads a model (see
/// `SpeakerDiarizer.extractEmbeddingFromCachedModels`) and never logs or reports audio or vectors.
struct DiarizerVoiceEmbedder: SpeakerVoiceEmbedder {
    let diarizer: SpeakerDiarizer
    /// The recording key at the moment the action started; `nil` when audio is not encrypted.
    let key: SymmetricKey?
    /// Where a journal-recorded note's segments are listed; nil reads only legacy chunk files.
    var store: Store?

    /// A side's audio pieces in order, each with its start on the note clock (samples) and how to read it.
    private struct Piece {
        let start: Int
        let read: () throws -> [Float]
    }

    func audioStream(for note: Note) -> SpeakerAudioStream? {
        if let journal = journal(of: note), !journal.audio(.mic).isEmpty {
            return journal.audio(.system).isEmpty ? .mic : .system
        }
        guard let path = note.audioPath else { return nil }
        if hasChunks(path, suffix: "-system") { return .system }
        return hasChunks(path, suffix: "") ? .mic : nil
    }

    func embeddings(note: Note, stream: SpeakerAudioStream, ranges: [SpeechRange]) async throws -> [[Float]] {
        guard let path = note.audioPath else { return [] }
        let pieces = try self.pieces(note: note, path: path, stream: stream)
        var results: [[Float]] = []
        for slice in try Self.slices(ranges, from: pieces) {
            results.append(slice.isEmpty ? [] : try await diarizer.extractEmbeddingFromCachedModels(samples: slice))
        }
        return results
    }

    private func journal(of note: Note) -> CaptureJournal? {
        guard let store, let id = note.id else { return nil }
        return try? store.captureJournal(noteId: id)
    }

    private func pieces(note: Note, path: String, stream: SpeakerAudioStream) throws -> [Piece] {
        let rate = SpeakerDiarizerConstants.sampleRate
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let key = self.key
        if let journal = journal(of: note), !journal.audio(.mic).isEmpty {
            return journal.audio(stream == .system ? .system : .mic).filter { $0.state != .open }.map { segment in
                Piece(start: Int(segment.t0 * rate)) {
                    try CaptureSegmentAudio.samples(segment, folder: folder, key: key, readLegacy: FinalizeRunner.readLegacy)
                }
            }
        }
        // Legacy chunks lie end to end; each piece's start is known only after reading the ones before it, so they
        // are read here one at a time and only their lengths kept.
        var start = 0
        return try SpeakerDiarizer.chunkFileURLs(audioPath: path, suffix: stream == .system ? "-system" : "").map { url in
            let count = try WAVWriter.read(url, key: key).count
            defer { start += count }
            return Piece(start: start) { try WAVWriter.read(url, key: key) }
        }
    }

    private func hasChunks(_ path: String, suffix: String) -> Bool {
        ((try? SpeakerDiarizer.chunkFileURLs(audioPath: path, suffix: suffix)) ?? []).isEmpty == false
    }

    /// One sample slice per range, in order, cut from the pieces at their places on the note clock. Pieces are read
    /// one at a time and only the parts a range needs are kept, so a long meeting is never fully in memory. A range
    /// past the end of the audio comes back empty.
    private static func slices(_ ranges: [SpeechRange], from pieces: [Piece]) throws -> [[Float]] {
        let rate = SpeakerDiarizerConstants.sampleRate
        var out = Array(repeating: [Float](), count: ranges.count)
        for piece in pieces {
            let needed = ranges.contains { Int($0.end * rate) > piece.start }
            guard needed else { continue }
            let samples = try piece.read()
            let pieceEnd = piece.start + samples.count
            for (index, range) in ranges.enumerated() {
                let from = max(Int(range.start * rate), piece.start)
                let to = min(Int(range.end * rate), pieceEnd)
                if from < to { out[index] += samples[(from - piece.start)..<(to - piece.start)] }
            }
        }
        return out
    }
}
