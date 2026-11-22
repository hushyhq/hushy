import CryptoKit
import Foundation
import Synchronization

/// Writes a recording to disk as it happens (meetings schema freeze section 3, notes audit B3 and B5). Each journal
/// tick appends one `hseg1` frame per side to that side's open `seg-<seq>-<stream>.hseg.part` and syncs it, so a
/// kill loses at most one tick. A segment is sealed at a pause once about 30 s have built up: the file is flushed to
/// the platter, renamed to `.hseg`, hashed, and its row set `sealed`; the call side is cut at the same moment as the
/// microphone. Each side keeps its own note clock, so a gap (a stall, a lost device) keeps both sides aligned.
///
/// Memory is bounded by the open segments: at most about 33 s per side.
public actor CaptureJournalWriter {
    public struct Sealed: Sendable {
        public let segment: CaptureSegment
        public let samples: [Float]
    }

    public static let segmentSeconds = 30.0
    /// From here a segment is cut at the first pause the tick holds.
    static let pauseSearchSeconds = 27.0
    /// A segment is cut here even with no pause in it.
    static let maxSegmentSeconds = 33.0
    /// A 100 ms window this quiet counts as a pause (below `MeetingCapture.heardFloor`).
    static let pauseRMS: Float = 0.01
    static let rate = 16_000.0

    private struct OpenSegment {
        var row: CaptureSegment
        let appender: HsegAppender
        var samples: [Float]
    }

    private struct Lane {
        var seq = 0
        var noteTime = 0.0
        var open: OpenSegment?
        var time: Double { open.map { $0.row.t0 + Double($0.samples.count) / CaptureJournalWriter.rate } ?? noteTime }
    }

    public let noteId: Int64
    private let store: Store
    private let folder: URL
    private let key: SymmetricKey?
    private var lanes: [CaptureStream: Lane] = [:]
    private let abandoned = Mutex(false)
    private let now: @Sendable () -> Date

    public init(store: Store, noteId: Int64, folder: URL, key: SymmetricKey?, streams: [CaptureStream],
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.noteId = noteId
        self.folder = folder
        self.key = key
        self.now = now
        for stream in streams { lanes[stream] = Lane() }
    }

    /// Stops all writing at once (a discarded recording): open files are closed where they are, nothing is sealed
    /// and no new file is created, so a folder being deleted is never brought back.
    public nonisolated func abandon() { abandoned.withLock { $0 = true } }
    private var isAbandoned: Bool { abandoned.withLock { $0 } }

    /// Note seconds the side has reached, counting its gaps.
    public func noteTime(_ stream: CaptureStream) -> Double { lanes[stream]?.time ?? 0 }

    /// Adds a side that starts late (the call's audio after the microphone), at the given note time.
    public func addStream(_ stream: CaptureStream, at time: Double) {
        guard lanes[stream] == nil else { return }
        lanes[stream] = Lane(seq: 0, noteTime: time, open: nil)
    }

    /// One journal tick: what each side delivered since the last. Returns the segments this tick sealed.
    public func tick(mic: [Float], system: [Float]?) throws -> [Sealed] {
        guard !isAbandoned else { closeAllForAbandon(); return [] }
        var sealed: [Sealed] = []
        let micCut = try feed(.mic, mic, cutLength: nil, follows: false, sealed: &sealed)
        if let system, lanes[.system] != nil {
            // The call side cuts where the microphone did; on its own only while the microphone delivers nothing.
            _ = try feed(.system, system, cutLength: micCut, follows: !mic.isEmpty, sealed: &sealed)
        }
        return sealed
    }

    /// One side on its own (an imported file's `file` side): appended and sealed at pauses exactly as the microphone
    /// is, a tick's worth at a time. Returns the segments this call sealed.
    public func append(_ stream: CaptureStream, _ samples: [Float]) throws -> [Sealed] {
        guard !isAbandoned else { closeAllForAbandon(); return [] }
        var sealed: [Sealed] = []
        _ = try feed(stream, samples, cutLength: nil, follows: false, sealed: &sealed)
        return sealed
    }

    /// Feeds a side; returns the length (samples) of the segment it sealed, if it sealed one.
    private func feed(
        _ stream: CaptureStream, _ incoming: [Float], cutLength: Int?, follows: Bool, sealed: inout [Sealed]
    ) throws -> Int? {
        guard var lane = lanes[stream] else { return nil }
        let current = lane.open?.samples.count ?? 0
        let cut: Int?
        if let cutLength {
            cut = max(0, min(incoming.count, cutLength - current))
        } else if follows {
            let total = Double(current + incoming.count) / Self.rate
            cut = total >= Self.maxSegmentSeconds + 3 ? incoming.count : nil
        } else {
            cut = Self.cutIndex(current: current, incoming: incoming)
        }
        guard let cut else {
            try append(incoming, to: &lane, stream: stream)
            lanes[stream] = lane
            return nil
        }
        try append(Array(incoming.prefix(cut)), to: &lane, stream: stream)
        let length = lane.open?.samples.count ?? 0
        if let done = try seal(&lane) { sealed.append(done) }
        let tail = Array(incoming.dropFirst(cut))
        try append(tail, to: &lane, stream: stream)
        lanes[stream] = lane
        return length
    }

    /// Where to cut this tick's samples to end the open segment, or nil to keep it open.
    static func cutIndex(current: Int, incoming: [Float]) -> Int? {
        let total = Double(current + incoming.count) / rate
        guard total >= pauseSearchSeconds, !incoming.isEmpty else { return nil }
        let window = Int(rate * 0.1)
        guard incoming.count > window * 2 else { return total >= maxSegmentSeconds ? incoming.count : nil }
        var best = (index: incoming.count, rms: Float.greatestFiniteMagnitude)
        var start = 0
        while start + window <= incoming.count {
            var energy: Float = 0
            for index in start..<(start + window) { energy += incoming[index] * incoming[index] }
            let rms = (energy / Float(window)).squareRoot()
            if rms < best.rms { best = (start + window / 2, rms) }
            start += window / 2
        }
        if best.rms < pauseRMS || total >= maxSegmentSeconds { return best.index }
        return nil
    }

    private func append(_ samples: [Float], to lane: inout Lane, stream: CaptureStream) throws {
        guard !samples.isEmpty else { return }
        if lane.open == nil { lane.open = try openSegment(stream, lane: lane) }
        guard var open = lane.open else { return }
        try open.appender.append(samples)
        open.samples += samples
        open.row.sampleCount = open.samples.count
        open.row.duration = Double(open.samples.count) / Self.rate
        if let id = open.row.id {
            try store.updateOpenSegment(id: id, duration: open.row.duration, sampleCount: open.row.sampleCount, now: now())
        }
        lane.open = open
    }

    private func openSegment(_ stream: CaptureStream, lane: Lane) throws -> OpenSegment {
        let name = Self.fileName(seq: lane.seq, stream: stream)
        let row = CaptureSegment(
            noteId: noteId, stream: stream, seq: lane.seq, kind: .audio, t0: lane.noteTime, duration: 0, file: name,
            format: .hseg1, state: .open, createdAt: now(), updatedAt: now())
        guard let inserted = try store.insertSegment(row) else { throw JournalError.noteGone }
        let appender = try HsegAppender(creating: folder.appendingPathComponent(name + ".part"), key: key)
        return OpenSegment(row: inserted, appender: appender, samples: [])
    }

    public static func fileName(seq: Int, stream: CaptureStream) -> String {
        String(format: "seg-%06d-%@.hseg", seq, stream.rawValue)
    }

    /// Seals the side's open segment, if any. Advances the side's sequence and clock.
    private func seal(_ lane: inout Lane) throws -> Sealed? {
        guard let open = lane.open else { return nil }
        lane.open = nil
        lane.seq = open.row.seq + 1
        lane.noteTime = open.row.t0 + Double(open.samples.count) / Self.rate
        try open.appender.close()
        guard let id = open.row.id else { return nil }
        guard !open.samples.isEmpty else {
            try? FileManager.default.removeItem(at: open.appender.url)
            try store.deleteEmptyOpenSegment(id: id)
            lane.seq = open.row.seq
            return nil
        }
        let final = folder.appendingPathComponent(open.row.file ?? Self.fileName(seq: open.row.seq, stream: open.row.stream))
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: open.appender.url, to: final)
        let summary = Self.describe(open.samples)
        let hash = Self.sha256(of: final)
        try store.sealSegment(
            id: id, duration: open.row.duration, sampleCount: open.samples.count, sha256: hash,
            speechRatio: summary.speechRatio, peak: summary.peak, now: now())
        var row = open.row
        row.state = .sealed
        row.sha256 = hash
        row.speechRatio = summary.speechRatio
        row.peak = summary.peak
        return Sealed(segment: row, samples: open.samples)
    }

    /// Seals every open segment (stop, quit, sleep). The next tick opens new ones.
    public func sealAll() throws -> [Sealed] {
        guard !isAbandoned else { closeAllForAbandon(); return [] }
        var sealed: [Sealed] = []
        for stream in lanes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var lane = lanes[stream] else { continue }
            if let done = try seal(&lane) { sealed.append(done) }
            lanes[stream] = lane
        }
        return sealed
    }

    /// A stretch a side did not deliver: seals its open segment and records a gap of `seconds` with `reason`, so
    /// the side's next audio sits at the right note time.
    public func gap(_ stream: CaptureStream, seconds: Double, reason: CaptureSegment.GapReason) throws -> [Sealed] {
        guard !isAbandoned, var lane = lanes[stream], seconds > 0 else { return [] }
        var sealed: [Sealed] = []
        if let done = try seal(&lane) { sealed.append(done) }
        let row = CaptureSegment(
            noteId: noteId, stream: stream, seq: lane.seq, kind: .gap, t0: lane.noteTime, duration: seconds,
            state: .transcribed, gapReason: reason, createdAt: now(), updatedAt: now())
        guard try store.insertSegment(row) != nil else { throw JournalError.noteGone }
        lane.seq += 1
        lane.noteTime += seconds
        lanes[stream] = lane
        return sealed
    }

    private func closeAllForAbandon() {
        for stream in lanes.keys {
            if let open = lanes[stream]?.open { try? open.appender.close() }
            lanes[stream]?.open = nil
        }
    }

    public enum JournalError: Error { case noteGone }

    static func describe(_ samples: [Float]) -> (speechRatio: Double, peak: Double) {
        let decision = SpeechGate.evaluate(samples)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        return (decision.activeFrameFraction, Double(peak))
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
