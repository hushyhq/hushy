import Testing
@testable import Murmur

/// Covers `ImportChunker`'s pure chunk-boundary math: how a fully-decoded import buffer is cut
/// into ~30s pieces and what absolute offset (from the start of the file) each piece gets, which
/// is what makes an imported file's word timings and subtitle timestamps line up with the real
/// audio.
@Suite("ImportChunker")
struct ImportChunkerTests {
    let sampleRate = 16_000.0

    @Test("A buffer shorter than one chunk produces no chunks")
    func shortBufferProducesNoChunks() {
        let pending = [Float](repeating: 0, count: 1_000)
        let (chunks, remaining) = ImportChunker.cutChunks(
            pending: pending, totalDecodedSamples: 1_000, chunkSamples: 16_000, sampleRate: sampleRate)
        #expect(chunks.isEmpty)
        #expect(remaining.count == 1_000)
    }

    @Test("A buffer of exactly one chunk cuts one chunk with zero leftover")
    func exactlyOneChunk() {
        let pending = [Float](repeating: 0.01, count: 16_000)
        let (chunks, remaining) = ImportChunker.cutChunks(
            pending: pending, totalDecodedSamples: 16_000, chunkSamples: 16_000, sampleRate: sampleRate)
        #expect(chunks.count == 1)
        #expect(remaining.isEmpty)
    }

    @Test("The first chunk starts at offset zero")
    func firstChunkOffsetIsZero() {
        let pending = [Float](repeating: 0.01, count: 16_000)
        let (chunks, _) = ImportChunker.cutChunks(
            pending: pending, totalDecodedSamples: 16_000, chunkSamples: 16_000, sampleRate: sampleRate)
        #expect(chunks[0].offsetSeconds == 0)
    }

    @Test("A second chunk's offset accounts for samples already consumed before this buffer")
    func offsetAccountsForPriorConsumption() {
        // Simulate a second call where 32,000 samples (2s) were already consumed by earlier
        // chunks and this buffer holds one more full chunk (1s at 16kHz).
        let pending = [Float](repeating: 0.01, count: 16_000)
        let (chunks, _) = ImportChunker.cutChunks(
            pending: pending, totalDecodedSamples: 48_000, chunkSamples: 16_000, sampleRate: sampleRate)
        #expect(chunks[0].offsetSeconds == 2.0)
    }

    @Test("Multiple full chunks in one buffer get increasing offsets")
    func multipleChunksIncreasingOffsets() {
        let pending = [Float](repeating: 0.01, count: 48_000) // 3 chunks of 1s each
        let (chunks, remaining) = ImportChunker.cutChunks(
            pending: pending, totalDecodedSamples: 48_000, chunkSamples: 16_000, sampleRate: sampleRate)
        #expect(chunks.count == 3)
        #expect(remaining.isEmpty)
        #expect(chunks.map(\.offsetSeconds) == [0.0, 1.0, 2.0])
    }

    @Test("Leftover samples after cutting full chunks are returned unmodified")
    func leftoverSamplesPreserved() {
        let pending = [Float](repeating: 0.01, count: 16_000 + 500)
        let (chunks, remaining) = ImportChunker.cutChunks(
            pending: pending, totalDecodedSamples: 16_500, chunkSamples: 16_000, sampleRate: sampleRate)
        #expect(chunks.count == 1)
        // The split point search may cut slightly before the exact chunk boundary (pause-aware
        // cut), so remaining can be slightly more than 500 samples, but never the whole buffer.
        #expect(remaining.count >= 500)
        #expect(remaining.count < pending.count)
    }

    @Test("Cutting preserves total sample count (no samples dropped or duplicated)")
    func noSamplesLostOrDuplicated() {
        let pending = (0..<50_000).map { Float($0) }
        let (chunks, remaining) = ImportChunker.cutChunks(
            pending: pending, totalDecodedSamples: 50_000, chunkSamples: 16_000, sampleRate: sampleRate)
        let totalCut = chunks.reduce(0) { $0 + $1.samples.count } + remaining.count
        #expect(totalCut == pending.count)
    }

    @Test("Chunks appear in the same sample order as the input")
    func chunksPreserveOrder() {
        let pending = (0..<32_000).map { Float($0) }
        let (chunks, remaining) = ImportChunker.cutChunks(
            pending: pending, totalDecodedSamples: 32_000, chunkSamples: 16_000, sampleRate: sampleRate)
        let reassembled = chunks.flatMap(\.samples) + remaining
        #expect(reassembled == pending)
    }

    @Test("Final chunk offset accounts for everything already consumed")
    func finalChunkOffset() {
        let offset = ImportChunker.finalChunkOffsetSeconds(totalDecodedSamples: 80_000, remainingSamples: 4_000, sampleRate: sampleRate)
        #expect(offset == 4.75) // (80000 - 4000) / 16000
    }

    @Test("Final chunk offset with no prior consumption is zero")
    func finalChunkOffsetZero() {
        let offset = ImportChunker.finalChunkOffsetSeconds(totalDecodedSamples: 8_000, remainingSamples: 8_000, sampleRate: sampleRate)
        #expect(offset == 0)
    }

    @Test("Empty pending buffer produces no chunks and no remaining samples")
    func emptyBuffer() {
        let (chunks, remaining) = ImportChunker.cutChunks(
            pending: [], totalDecodedSamples: 0, chunkSamples: 16_000, sampleRate: sampleRate)
        #expect(chunks.isEmpty)
        #expect(remaining.isEmpty)
    }
}
