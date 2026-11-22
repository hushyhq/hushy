import CryptoKit
import Foundation

/// One side of a recording laid out on the note clock (each segment at its `t0`, gaps as zeros), handed out in
/// windows of at most `window` samples so the whole side is never in memory at once. An hour of one side is 230 MB of
/// Float samples; diarizing it window by window holds one segment and one window.
///
/// Placement rule (what `CaptureSegmentAudio.timeline` returns, which is built on this type):
/// - a segment that starts after the end so far is preceded by zeros up to its start;
/// - a segment that starts before the end (a rounding overlap of a few samples) writes over the overlap rather than
///   shifting everything after it. The last `holdback` samples stay unsent for this; an overlap reaching further back
///   than that keeps the samples already sent and drops the new segment's samples for those positions. The side never
///   gets shorter (a segment that ends inside the one before leaves that one's end in place).
public struct CaptureTimeline: Sendable {
    private enum Piece: Sendable {
        case samples([Float])
        case zeros(Int)

        var count: Int {
            switch self {
            case .samples(let values): values.count
            case .zeros(let count): count
            }
        }
    }

    public let window: Int
    public let holdback: Int
    /// Samples placed so far on the note clock, sent or not.
    public private(set) var placedEnd = 0
    private var pieces: [Piece] = []
    private var queued = 0

    /// - Parameters:
    ///   - window: the most samples one `next` returns (10 s at 16 kHz by default).
    ///   - holdback: how many trailing samples wait for a possible overlap (0.5 s by default).
    public init(window: Int = 160_000, holdback: Int = 8_000) {
        self.window = max(1, window)
        self.holdback = max(0, holdback)
    }

    /// Places a segment's samples at sample `start` of the note clock.
    public mutating func place(_ samples: [Float], at start: Int) {
        let start = max(0, start)
        if start > placedEnd {
            append(.zeros(start - placedEnd))
        } else if start < placedEnd {
            // New samples that land on positions already placed: written over the held-back tail, dropped before it.
            let inside = min(placedEnd - start, samples.count)
            let firstWritable = placedEnd - overwritable
            if inside > 0, overwritable > 0, case .samples(var last) = pieces.last {
                let base = placedEnd - last.count
                for index in 0..<inside where start + index >= firstWritable { last[start + index - base] = samples[index] }
                pieces[pieces.count - 1] = .samples(last)
            }
            if inside < samples.count { append(.samples(Array(samples[inside...]))) }
            return
        }
        if !samples.isEmpty { append(.samples(samples)) }
    }

    /// The next window that no later placement can change, or with `final` whatever is left; nil when there is none.
    public mutating func next(final: Bool = false) -> [Float]? {
        let ready = final ? queued : queued - overwritable
        guard ready >= window || (final && ready > 0) else { return nil }
        var out: [Float] = []
        out.reserveCapacity(min(window, ready))
        var wanted = min(window, ready)
        while wanted > 0, let first = pieces.first {
            let take = min(wanted, first.count)
            switch first {
            case .samples(let values):
                out.append(contentsOf: values[0..<take])
                pieces[0] = .samples(Array(values[take...]))
            case .zeros(let count):
                out.append(contentsOf: repeatElement(0, count: take))
                pieces[0] = .zeros(count - take)
            }
            if pieces[0].count == 0 { pieces.removeFirst() }
            wanted -= take
        }
        queued -= out.count
        return out
    }

    /// Trailing samples a rounding overlap may still write over: the end of the last segment, up to `holdback`.
    private var overwritable: Int {
        guard case .samples(let last) = pieces.last else { return 0 }
        return min(holdback, last.count)
    }

    private mutating func append(_ piece: Piece) {
        guard piece.count > 0 else { return }
        if case .zeros(let added) = piece, case .zeros(let existing) = pieces.last {
            pieces[pieces.count - 1] = .zeros(existing + added)
        } else {
            pieces.append(piece)
        }
        queued += piece.count
        placedEnd += piece.count
    }
}

extension CaptureSegmentAudio {
    /// One side of the journal on the note clock, window by window (`CaptureTimeline`): segments are read from disk one
    /// at a time, as the windows are asked for. What diarization reads, so its times line up with the turns' word times.
    public static func windows(
        _ journal: CaptureJournal, stream: CaptureStream, folder: URL, key: SymmetricKey?,
        readLegacy: @escaping CaptureJournalAdopter.LegacyReader, window: Int = 160_000
    ) -> AsyncThrowingStream<[Float], any Error> {
        let reader = TimelineReader(
            segments: journal.audio(stream).filter { $0.state != .open }, folder: folder, key: key, readLegacy: readLegacy,
            timeline: CaptureTimeline(window: window))
        return AsyncThrowingStream(unfolding: { try reader.next() })
    }

    /// The side's samples from `from` to `to` seconds on the note clock (zeros where nothing was recorded, cut at the
    /// side's end as the whole side would be), reading only the segments that overlap the range: what voice matching
    /// needs from an hour without loading the hour.
    public static func range(
        _ journal: CaptureJournal, stream: CaptureStream, from: Double, to: Double, folder: URL, key: SymmetricKey?,
        readLegacy: CaptureJournalAdopter.LegacyReader
    ) throws -> [Float] {
        let rate = CaptureJournalWriter.rate
        let lo = max(0, Int((from * rate).rounded())), hi = Int((to * rate).rounded())
        guard lo < hi else { return [] }
        var timeline = CaptureTimeline(window: hi - lo)
        var sideEnd = 0
        for segment in journal.audio(stream) where segment.state != .open {
            let start = Int((segment.t0 * rate).rounded())
            let length = max(segment.sampleCount, Int((segment.duration * rate).rounded()))
            sideEnd = max(sideEnd, start + length)
            guard start < hi, start + length > lo else { continue }
            let samples = try samples(segment, folder: folder, key: key, readLegacy: readLegacy)
            let first = max(0, lo - start), last = min(samples.count, hi - start)
            guard first < last else { continue }
            timeline.place(Array(samples[first..<last]), at: start + first - lo)
        }
        var out = timeline.next(final: true) ?? []
        let wanted = max(0, min(hi, sideEnd) - lo)
        if out.count < wanted { out += [Float](repeating: 0, count: wanted - out.count) }
        return Array(out.prefix(wanted))
    }

    /// Pulls segments into a timeline only when it runs dry, so at most one segment is read ahead.
    private final class TimelineReader: @unchecked Sendable {
        private var segments: ArraySlice<CaptureSegment>
        private let folder: URL
        private let key: SymmetricKey?
        private let readLegacy: CaptureJournalAdopter.LegacyReader
        private var timeline: CaptureTimeline
        private var finished = false

        init(segments: [CaptureSegment], folder: URL, key: SymmetricKey?,
             readLegacy: @escaping CaptureJournalAdopter.LegacyReader, timeline: CaptureTimeline) {
            self.segments = segments[...]
            self.folder = folder
            self.key = key
            self.readLegacy = readLegacy
            self.timeline = timeline
        }

        func next() throws -> [Float]? {
            while true {
                if let window = timeline.next(final: finished) { return window }
                if finished { return nil }
                guard let segment = segments.popFirst() else {
                    finished = true
                    continue
                }
                let samples = try CaptureSegmentAudio.samples(segment, folder: folder, key: key, readLegacy: readLegacy)
                timeline.place(samples, at: Int((segment.t0 * CaptureJournalWriter.rate).rounded()))
            }
        }
    }
}
