import Foundation
import Testing
@testable import MurmurCore

/// One side of a recording on the note clock, handed out window by window (`CaptureTimeline`), so diarizing an hour
/// never holds the hour: the windows join to exactly the side the old whole-side reader built.
@Suite("Capture timeline windows")
struct CaptureTimelineTests {
    /// The placement the whole-side reader used before windows (zeros up to a late start, an overlap written over).
    private func reference(_ placements: [(start: Int, samples: [Float])]) -> [Float] {
        var out: [Float] = []
        for (start, samples) in placements {
            if start > out.count { out += [Float](repeating: 0, count: start - out.count) }
            if start < out.count {
                let overlap = out.count - start
                out.replaceSubrange(start..<out.count, with: samples.prefix(overlap))
                out += samples.dropFirst(overlap)
            } else {
                out += samples
            }
        }
        return out
    }

    private func streamed(_ placements: [(start: Int, samples: [Float])], window: Int) -> (joined: [Float], largest: Int) {
        var timeline = CaptureTimeline(window: window, holdback: 50)
        var joined: [Float] = []
        var largest = 0
        for (start, samples) in placements {
            timeline.place(samples, at: start)
            while let next = timeline.next() { joined += next; largest = max(largest, next.count) }
        }
        while let next = timeline.next(final: true) { joined += next; largest = max(largest, next.count) }
        return (joined, largest)
    }

    private func segment(_ count: Int, seed: Int) -> [Float] {
        (0..<count).map { Float(($0 * 31 + seed * 17) % 97) / 97 }
    }

    @Test("segments, gaps and small rounding overlaps join to the same side, never more than a window at a time")
    func matchesWholeSide() {
        let placements: [(start: Int, samples: [Float])] = [
            (0, segment(480, seed: 1)), (477, segment(510, seed: 2)), (2_000, segment(300, seed: 3)),
            (2_300, segment(10, seed: 4)), (2_309, segment(700, seed: 5)), (9_000, segment(64, seed: 6)),
        ]
        let (joined, largest) = streamed(placements, window: 128)
        #expect(joined == reference(placements))
        #expect(largest <= 128)
    }

    @Test("a long gap is handed out as zeros a window at a time, not built whole")
    func longGapIsWindowed() {
        var timeline = CaptureTimeline(window: 1_000, holdback: 10)
        timeline.place([1, 2, 3], at: 0)
        timeline.place([4], at: 1_000_000)
        var count = 0, windows = 0, largest = 0
        while let next = timeline.next(final: true) { count += next.count; windows += 1; largest = max(largest, next.count) }
        #expect(count == 1_000_001)
        #expect(largest == 1_000)
        #expect(windows == 1_001)
    }

    @Test("the held-back tail waits for a later overlap; the final call sends it")
    func holdbackWaits() {
        var timeline = CaptureTimeline(window: 4, holdback: 2)
        timeline.place([1, 1, 1, 1, 1, 1], at: 0)
        #expect(timeline.next() == [1, 1, 1, 1])
        #expect(timeline.next() == nil, "the last two samples may still be written over")
        timeline.place([2, 2, 2], at: 5)
        #expect(timeline.next(final: true) == [1, 2, 2, 2])
        #expect(timeline.next(final: true) == nil)
    }

    @Test("a range reads only the segments it overlaps and pads what was never recorded")
    func rangeReadsOnlyOverlap() throws {
        let store = try Store()
        let note = try store.save(Note(title: "range", status: .ready))
        let id = try #require(note.id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var rows: [CaptureSegment] = []
        for seq in 0..<3 {
            let name = CaptureJournalWriter.fileName(seq: seq, stream: .mic)
            let samples = [Float](repeating: Float(seq + 1) / 10, count: 16_000)
            let appender = try HsegAppender(creating: folder.appendingPathComponent(name), key: nil)
            try appender.append(samples)
            try appender.close()
            let row = CaptureSegment(
                noteId: id, stream: .mic, seq: seq, kind: .audio, t0: Double(seq) * 2, duration: 1, sampleCount: 16_000,
                file: name, format: .hseg1, state: .sealed, createdAt: Date(), updatedAt: Date())
            rows.append(try #require(try store.insertSegment(row)))
        }
        let journal = try store.captureJournal(noteId: id)
        let read = try CaptureSegmentAudio.range(
            journal, stream: .mic, from: 2.5, to: 3.5, folder: folder, key: nil, readLegacy: { _, _ in [] })
        #expect(read.count == 16_000)
        #expect(read.prefix(8_000).allSatisfy { abs($0 - 0.2) < 0.001 }, "the second segment's second half")
        #expect(read.suffix(8_000).allSatisfy { $0 == 0 }, "nothing was recorded from 3 s to 3.5 s")
        let whole = try CaptureSegmentAudio.timeline(journal, stream: .mic, folder: folder, key: nil, readLegacy: { _, _ in [] })
        #expect(whole.count == 5 * 16_000)
    }
}
