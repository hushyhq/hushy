import Testing
@testable import MurmurCore

@Suite("AudioSampleBuffer")
struct AudioSampleBufferTests {
    @Test("append then allSamples preserves order across chunk boundaries")
    func orderingAcrossChunks() {
        var buffer = AudioSampleBuffer(chunkSize: 4)
        buffer.append(contentsOf: [1, 2, 3])
        buffer.append(contentsOf: [4, 5, 6, 7])
        buffer.append(contentsOf: [8])
        #expect(buffer.allSamples() == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(buffer.totalCount == 8)
    }

    @Test("a single append spanning multiple chunk boundaries splits correctly")
    func singleAppendGrowsAcrossChunks() {
        var buffer = AudioSampleBuffer(chunkSize: 3)
        let samples: [Float] = Array(stride(from: Float(0), to: 10, by: 1))
        buffer.append(contentsOf: samples)
        #expect(buffer.allSamples() == samples)
        #expect(buffer.totalCount == 10)
    }

    @Test("drain returns only samples since the previous drain, in order")
    func drainReturnsOnlyFreshSamples() {
        var buffer = AudioSampleBuffer(chunkSize: 4)
        buffer.append(contentsOf: [1, 2, 3, 4, 5])
        let first = buffer.drain()
        #expect(first == [1, 2, 3, 4, 5])

        buffer.append(contentsOf: [6, 7])
        let second = buffer.drain()
        #expect(second == [6, 7])

        // Nothing new since the last drain.
        #expect(buffer.drain() == [])
    }

    @Test("drain does not lose samples retained for allSamples()")
    func drainPreservesFullRetention() {
        var buffer = AudioSampleBuffer(chunkSize: 4)
        buffer.append(contentsOf: [1, 2, 3, 4, 5, 6])
        _ = buffer.drain()
        buffer.append(contentsOf: [7, 8, 9])
        #expect(buffer.allSamples() == [1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(buffer.totalCount == 9)
    }

    @Test("allSamples() does not consume: a drain after it returns only what was never drained")
    func drainAfterAllSamplesReturnsOnlyTheRemainder() {
        var buffer = AudioSampleBuffer(chunkSize: 4)
        buffer.append(contentsOf: [1, 2, 3, 4, 5, 6])
        #expect(buffer.drain() == [1, 2, 3, 4, 5, 6])
        buffer.append(contentsOf: [7, 8, 9])
        // NoteRecorder.stop() reads the whole recording, then takes only the remainder.
        #expect(buffer.allSamples() == [1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(buffer.drain() == [7, 8, 9])
    }

    @Test("draining a partially-filled current chunk mid-stream then continuing preserves order")
    func drainMidChunkThenAppendMore() {
        var buffer = AudioSampleBuffer(chunkSize: 5)
        buffer.append(contentsOf: [1, 2]) // current chunk partially filled
        let drained1 = buffer.drain()
        #expect(drained1 == [1, 2])

        buffer.append(contentsOf: [3, 4, 5, 6, 7, 8]) // wraps a full chunk plus more
        let drained2 = buffer.drain()
        #expect(drained2 == [3, 4, 5, 6, 7, 8])
        #expect(buffer.allSamples() == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test("empty buffer reports isEmpty and drains to an empty array")
    func emptyBuffer() {
        var buffer = AudioSampleBuffer()
        #expect(buffer.isEmpty)
        #expect(buffer.drain().isEmpty)
        #expect(buffer.allSamples().isEmpty)
        #expect(buffer.totalCount == 0)
    }

    @Test("appending an empty collection is a no-op")
    func appendingEmptyIsNoop() {
        var buffer = AudioSampleBuffer(chunkSize: 4)
        buffer.append(contentsOf: [1, 2])
        buffer.append(contentsOf: [Float]())
        #expect(buffer.allSamples() == [1, 2])
        #expect(buffer.totalCount == 2)
    }

    @Test("large sequential fill simulates a long recording without losing samples")
    func longRecordingSimulation() {
        var buffer = AudioSampleBuffer(chunkSize: 16_000)
        var expected: [Float] = []
        expected.reserveCapacity(160_000)
        // Simulate ~10s of audio arriving as small tap callbacks (1024 frames each).
        var counter: Float = 0
        for _ in 0..<(160_000 / 1024 + 1) {
            let batch = (0..<1024).map { _ -> Float in
                defer { counter += 1 }
                return counter
            }
            buffer.append(contentsOf: batch)
            expected.append(contentsOf: batch)
        }
        #expect(buffer.totalCount == expected.count)
        #expect(buffer.allSamples() == expected)
    }

    @Test("interleaved drains during a long recording reconstruct the full stream")
    func interleavedDrainsReconstructFullStream() {
        var buffer = AudioSampleBuffer(chunkSize: 100)
        var expected: [Float] = []
        var drainedAll: [Float] = []
        var counter: Float = 0
        for batchIndex in 0..<50 {
            let batch = (0..<37).map { _ -> Float in
                defer { counter += 1 }
                return counter
            }
            buffer.append(contentsOf: batch)
            expected.append(contentsOf: batch)
            if batchIndex % 3 == 0 {
                drainedAll.append(contentsOf: buffer.drain())
            }
        }
        drainedAll.append(contentsOf: buffer.drain())
        #expect(drainedAll == expected)
        #expect(buffer.allSamples() == expected)
    }

    @Test("a note's buffer holds only what was not drained: an hour of audio never sits in memory (notes audit B5)")
    func noteBufferStaysBounded() {
        var buffer = AudioSampleBuffer(retainsFullRecording: false)
        var drained = 0
        var peak = 0
        // One hour at 16 kHz, appended in 10 ms taps and drained every 2 s, as the recorder's timer does.
        for tap in 0..<(3_600 * 100) {
            buffer.append(contentsOf: [Float](repeating: 0.1, count: 160))
            peak = max(peak, buffer.heldCount)
            if tap % 200 == 199 { drained += buffer.drain().count }
        }
        drained += buffer.drain().count
        #expect(drained == 3_600 * 16_000)
        #expect(peak <= 2 * 16_000 + AudioSampleBuffer.defaultChunkSize)
        buffer.append(contentsOf: [1, 2, 3])
        #expect(buffer.allSamples() == [1, 2, 3], "stop returns only the tail not drained yet")
        #expect(buffer.totalCount == 3_600 * 16_000 + 3)
    }
}
