import Foundation
import Testing
@testable import MurmurCore

/// Covers `ChunkAlignment`, the pure helper that reconciles the mic and system-audio chunk
/// timelines when a note records both streams (see `.claude/DECISIONS.md`'s system-audio entry).
@Suite("Chunk alignment")
struct ChunkAlignmentTests {
    @Test("start offsets accumulate from running sample counts")
    func startOffsetsAccumulate() {
        let chunks = [
            ChunkAlignment.ChunkInfo(index: 0, sampleCount: 16_000),
            ChunkAlignment.ChunkInfo(index: 1, sampleCount: 32_000),
            ChunkAlignment.ChunkInfo(index: 2, sampleCount: 16_000),
        ]
        let offsets = ChunkAlignment.startOffsets(chunks: chunks, sampleRate: 16_000)
        #expect(offsets[0] == 0)
        #expect(offsets[1] == 1)
        #expect(offsets[2] == 3)
    }

    @Test("start offsets are computed correctly regardless of input order")
    func startOffsetsSortByIndexFirst() {
        let chunks = [
            ChunkAlignment.ChunkInfo(index: 1, sampleCount: 32_000),
            ChunkAlignment.ChunkInfo(index: 0, sampleCount: 16_000),
        ]
        let offsets = ChunkAlignment.startOffsets(chunks: chunks, sampleRate: 16_000)
        #expect(offsets[0] == 0)
        #expect(offsets[1] == 1)
    }

    @Test("empty chunk list produces no offsets")
    func emptyChunksProduceNoOffsets() {
        #expect(ChunkAlignment.startOffsets(chunks: [], sampleRate: 16_000).isEmpty)
    }

    @Test("tail gap is the absolute duration difference")
    func tailGapComputation() {
        #expect(ChunkAlignment.tailGap(micDurationSeconds: 10, systemDurationSeconds: 9.5) == 0.5)
        #expect(ChunkAlignment.tailGap(micDurationSeconds: 9.5, systemDurationSeconds: 10) == 0.5)
        #expect(ChunkAlignment.tailGap(micDurationSeconds: 10, systemDurationSeconds: 10) == 0)
    }

    @Test("chunks in step when indices match exactly")
    func chunksInStepWhenIndicesMatch() {
        let mic = [ChunkAlignment.ChunkInfo(index: 0, sampleCount: 100), ChunkAlignment.ChunkInfo(index: 1, sampleCount: 100)]
        let system = [ChunkAlignment.ChunkInfo(index: 0, sampleCount: 90), ChunkAlignment.ChunkInfo(index: 1, sampleCount: 95)]
        #expect(ChunkAlignment.chunksInStep(mic: mic, system: system))
    }

    @Test("chunks not in step when the system stream is missing a chunk")
    func chunksNotInStepWhenMissing() {
        let mic = [ChunkAlignment.ChunkInfo(index: 0, sampleCount: 100), ChunkAlignment.ChunkInfo(index: 1, sampleCount: 100)]
        let system = [ChunkAlignment.ChunkInfo(index: 0, sampleCount: 90)]
        #expect(!ChunkAlignment.chunksInStep(mic: mic, system: system))
    }

    @Test("significant gap threshold is a fixed, documented constant")
    func significantGapThreshold() {
        #expect(ChunkAlignment.significantGapSeconds == 2.0)
        #expect(ChunkAlignment.tailGap(micDurationSeconds: 100, systemDurationSeconds: 100 - ChunkAlignment.significantGapSeconds - 0.1)
            > ChunkAlignment.significantGapSeconds)
    }
}
