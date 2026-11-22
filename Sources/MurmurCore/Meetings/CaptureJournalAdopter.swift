import CryptoKit
import Foundation

/// The finalize runner's sealing step (meetings schema freeze section 3): after a stop, a quit or a kill, every row
/// of the journal ends sealed or as a gap, and every file on disk has its row.
///
/// - An open row with a `.part` file: the torn last frame is cut off, the file flushed, renamed and hashed, the row
///   sealed with what the file really holds.
/// - An open row whose file was already renamed (a kill between the rename and the row update): sealed from the file.
/// - An open row with no file: a gap of its recorded length (`interrupted`).
/// - A segment file with no row: a row is inserted after the side's last segment.
/// - A note from before the journal (`chunk-0000.wav`, `chunk-0000-system.wav`, either `.enc`): each chunk is adopted
///   as a sealed row (`format` `wav` or `wav.enc`) at its place on the note clock, on `legacyStream` (the microphone
///   for a recording, `file` for an imported file).
public enum CaptureJournalAdopter {
    public struct Outcome: Sendable, Equatable {
        public var sealed = 0
        public var tornBytes = 0
        public var interrupted = 0
        public var orphans = 0
        public var legacy = 0
    }

    /// Reads a legacy chunk (a WAV path, plain or with `.enc` beside it). Supplied by the app, which owns WAV.
    public typealias LegacyReader = @Sendable (_ url: URL, _ key: SymmetricKey?) throws -> [Float]

    public static func adopt(
        store: Store, noteId: Int64, folder: URL, key: SymmetricKey?, readLegacy: LegacyReader,
        legacyStream: CaptureStream = .mic, now: Date = Date()
    ) throws -> Outcome {
        var outcome = Outcome()
        var journal = try store.captureJournal(noteId: noteId)
        if journal.segments.isEmpty {
            outcome.legacy = try adoptLegacy(
                store: store, noteId: noteId, folder: folder, key: key, read: readLegacy, stream: legacyStream, now: now)
            journal = try store.captureJournal(noteId: noteId)
        }
        for row in journal.segments where row.state == .open {
            guard let id = row.id else { continue }
            guard let file = row.file else {
                try store.convertOpenSegmentToGap(id: id, reason: .interrupted, now: now)
                outcome.interrupted += 1
                continue
            }
            let final = folder.appendingPathComponent(file)
            let part = folder.appendingPathComponent(file + ".part")
            let source = FileManager.default.fileExists(atPath: part.path) ? part
                : FileManager.default.fileExists(atPath: final.path) ? final : nil
            guard let source, let contents = try? HsegFile.read(source, key: key) else {
                try store.convertOpenSegmentToGap(id: id, reason: .interrupted, now: now)
                outcome.interrupted += 1
                continue
            }
            guard !contents.samples.isEmpty else {
                try? FileManager.default.removeItem(at: source)
                if row.duration > 0 {
                    try store.convertOpenSegmentToGap(id: id, reason: .interrupted, now: now)
                    outcome.interrupted += 1
                } else {
                    try store.deleteEmptyOpenSegment(id: id)
                }
                continue
            }
            if contents.isTorn {
                try truncate(source, to: contents.validLength)
                outcome.tornBytes += contents.fileLength - contents.validLength
            }
            if source != final {
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: source, to: final)
            }
            let described = CaptureJournalWriter.describe(contents.samples)
            try store.sealSegment(
                id: id, duration: Double(contents.samples.count) / CaptureJournalWriter.rate,
                sampleCount: contents.samples.count, sha256: CaptureJournalWriter.sha256(of: final),
                speechRatio: described.speechRatio, peak: described.peak, now: now)
            outcome.sealed += 1
        }
        outcome.orphans = try adoptOrphans(store: store, noteId: noteId, folder: folder, key: key, now: now)
        return outcome
    }

    /// Cuts a torn last frame off and flushes the file to the platter.
    static func truncate(_ url: URL, to length: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
    }

    /// `seg-000004-mic.hseg` or its `.part`, for a file no row names.
    static func parse(_ name: String) -> (seq: Int, stream: CaptureStream)? {
        let base = name.hasSuffix(".part") ? String(name.dropLast(5)) : name
        guard base.hasPrefix("seg-"), base.hasSuffix(".hseg") else { return nil }
        let parts = base.dropFirst(4).dropLast(5).split(separator: "-")
        guard parts.count == 2, let seq = Int(parts[0]), let stream = CaptureStream(rawValue: String(parts[1])) else { return nil }
        return (seq, stream)
    }

    private static func adoptOrphans(store: Store, noteId: Int64, folder: URL, key: SymmetricKey?, now: Date) throws -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let journal = try store.captureJournal(noteId: noteId)
        let known = Set(journal.segments.compactMap(\.file))
        var adopted = 0
        for name in names.sorted() {
            guard let (seq, stream) = parse(name) else { continue }
            let final = name.hasSuffix(".part") ? String(name.dropLast(5)) : name
            guard !known.contains(final), !journal.segments.contains(where: { $0.stream == stream && $0.seq == seq }) else { continue }
            let url = folder.appendingPathComponent(name)
            guard let contents = try? HsegFile.read(url, key: key), !contents.samples.isEmpty else { continue }
            if contents.isTorn { try truncate(url, to: contents.validLength) }
            let finalURL = folder.appendingPathComponent(final)
            if url != finalURL { try FileManager.default.moveItem(at: url, to: finalURL) }
            let before = try store.captureJournal(noteId: noteId).segments.filter { $0.stream == stream && $0.seq < seq }
            let t0 = before.map { $0.t0 + $0.duration }.max() ?? 0
            let described = CaptureJournalWriter.describe(contents.samples)
            let row = CaptureSegment(
                noteId: noteId, stream: stream, seq: seq, kind: .audio, t0: t0,
                duration: Double(contents.samples.count) / CaptureJournalWriter.rate, sampleCount: contents.samples.count,
                file: final, format: .hseg1, sha256: CaptureJournalWriter.sha256(of: finalURL), state: .sealed,
                speechRatio: described.speechRatio, peak: described.peak, createdAt: now, updatedAt: now)
            if try store.insertSegment(row) != nil { adopted += 1 }
        }
        return adopted
    }

    /// Chunk files a build without the journal wrote, as sealed rows. The call side of chunk N starts where the
    /// microphone's chunk N does, as it was cut.
    private static func adoptLegacy(
        store: Store, noteId: Int64, folder: URL, key: SymmetricKey?, read: LegacyReader, stream: CaptureStream, now: Date
    ) throws -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let chunks = Set(names.compactMap(legacyIndex)).sorted()
        var t0 = 0.0
        var adopted = 0
        for index in chunks {
            let mic = String(format: "chunk-%04d.wav", index)
            guard let samples = try? read(folder.appendingPathComponent(mic), key) else { continue }
            let duration = Double(samples.count) / CaptureJournalWriter.rate
            let encrypted = names.contains(mic + ".enc")
            let described = CaptureJournalWriter.describe(samples)
            let row = CaptureSegment(
                noteId: noteId, stream: stream, seq: index, kind: .audio, t0: t0, duration: duration, sampleCount: samples.count,
                file: mic, format: encrypted ? .wavEncrypted : .wav, state: .sealed, speechRatio: described.speechRatio,
                peak: described.peak, createdAt: now, updatedAt: now)
            if try store.insertSegment(row) != nil { adopted += 1 }
            let system = String(format: "chunk-%04d-system.wav", index)
            if names.contains(system) || names.contains(system + ".enc"),
               let callSamples = try? read(folder.appendingPathComponent(system), key) {
                let callRow = CaptureSegment(
                    noteId: noteId, stream: .system, seq: index, kind: .audio, t0: t0,
                    duration: Double(callSamples.count) / CaptureJournalWriter.rate, sampleCount: callSamples.count,
                    file: system, format: names.contains(system + ".enc") ? .wavEncrypted : .wav, state: .sealed,
                    createdAt: now, updatedAt: now)
                if try store.insertSegment(callRow) != nil { adopted += 1 }
            }
            t0 += duration
        }
        return adopted
    }

    /// `chunk-0004.wav` or `chunk-0004.wav.enc` → 4; the call side's files are not counted here.
    static func legacyIndex(_ name: String) -> Int? {
        let base = name.hasSuffix(".enc") ? String(name.dropLast(4)) : name
        guard base.hasPrefix("chunk-"), base.hasSuffix(".wav"), !base.hasSuffix("-system.wav") else { return nil }
        return Int(base.dropFirst(6).dropLast(4))
    }
}

/// Reads a journal row's audio, whatever wrote it.
public enum CaptureSegmentAudio {
    public static func samples(
        _ segment: CaptureSegment, folder: URL, key: SymmetricKey?, readLegacy: CaptureJournalAdopter.LegacyReader
    ) throws -> [Float] {
        guard segment.kind == .audio, let file = segment.file else { return [] }
        let url = folder.appendingPathComponent(file)
        switch segment.format ?? .hseg1 {
        case .hseg1: return try HsegFile.read(url, key: key).samples
        case .wav, .wavEncrypted: return try readLegacy(url, key)
        }
    }

    /// One side laid out on the note clock: each segment at its `t0`, gaps as zeros (`CaptureTimeline`'s placement).
    /// The whole side at once: for the legacy diarizer and voice matching only, which need it; diarization otherwise
    /// reads `windows`.
    public static func timeline(
        _ journal: CaptureJournal, stream: CaptureStream, folder: URL, key: SymmetricKey?,
        readLegacy: CaptureJournalAdopter.LegacyReader
    ) throws -> [Float] {
        var timeline = CaptureTimeline()
        var out: [Float] = []
        for segment in journal.audio(stream) where segment.state != .open {
            let samples = try samples(segment, folder: folder, key: key, readLegacy: readLegacy)
            timeline.place(samples, at: Int((segment.t0 * CaptureJournalWriter.rate).rounded()))
            while let window = timeline.next() { out += window }
        }
        while let window = timeline.next(final: true) { out += window }
        return out
    }
}
