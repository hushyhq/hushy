import Foundation
import MurmurCore

/// Pure chunk-boundary bookkeeping for `FileTranscriber`, split out so it can be unit tested
/// without decoding real audio: given how many samples have been decoded so far and how many are
/// still pending (not yet cut into a chunk), computes where the next chunk should be cut and what
/// absolute offset (in seconds, from the start of the whole file) that chunk starts at. This is
/// the same pause-aware cut `NoteRecorder`/`ChunkSplitter` use for live recordings, applied here
/// to a fully-decoded (not live) buffer.
enum ImportChunker {
    /// One chunk ready to transcribe: its samples, and its start offset in seconds from the
    /// beginning of the source file (for stitching word timings back into a whole-file timeline).
    struct Chunk: Equatable {
        let samples: [Float]
        let offsetSeconds: Double
    }

    /// Cuts as many full chunks as possible out of `pending`, returning them in order plus the
    /// samples still left over (fewer than one chunk's worth). `totalDecodedSamples` is the
    /// count of every sample decoded so far, including ones already cut into earlier chunks —
    /// used only to compute each returned chunk's absolute offset.
    static func cutChunks(
        pending: [Float], totalDecodedSamples: Int, chunkSamples: Int, sampleRate: Double
    ) -> (chunks: [Chunk], remaining: [Float]) {
        var remaining = pending
        var chunks: [Chunk] = []
        // How many samples have been consumed by chunks already cut before this buffer, i.e.
        // "decoded so far" minus "still sitting in `pending` at the start of this call".
        var consumedBeforePending = totalDecodedSamples - pending.count

        while remaining.count >= chunkSamples {
            let cut = ChunkSplitter.splitIndex(Array(remaining.prefix(chunkSamples)))
            let piece = Array(remaining.prefix(cut))
            remaining.removeFirst(cut)
            let offsetSeconds = Double(consumedBeforePending) / sampleRate
            chunks.append(Chunk(samples: piece, offsetSeconds: offsetSeconds))
            consumedBeforePending += piece.count
        }
        return (chunks, remaining)
    }

    /// The offset (in seconds) for one final, partial chunk — everything left over once decoding
    /// finishes, which is always cut whole (no pause-aware search: there is nothing after it).
    static func finalChunkOffsetSeconds(totalDecodedSamples: Int, remainingSamples: Int, sampleRate: Double) -> Double {
        Double(totalDecodedSamples - remainingSamples) / sampleRate
    }
}
