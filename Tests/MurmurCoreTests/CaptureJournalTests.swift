import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// The capture journal (meetings schema freeze section 3): the `hseg1` file, the writer, adoption after a kill,
/// the finalize plan and capture health. Temp folders and in-memory stores only.
@Suite("Capture journal", .timeLimit(.minutes(1)))
struct CaptureJournalTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.05) }
    }

    private func note(_ store: Store) throws -> Int64 {
        try store.save(Note(title: "Call", status: .recording)).id!
    }

    // MARK: hseg1

    @Test("a plaintext and an encrypted segment read back what was written, to Int16 precision")
    func roundTrip() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples = tone(1.5)
        for key in [nil, SymmetricKey(size: .bits256)] {
            let url = dir.appendingPathComponent("seg-\(key == nil ? "p" : "e").hseg.part")
            let appender = try HsegAppender(creating: url, key: key)
            try appender.append(Array(samples.prefix(16_000)))
            try appender.append(Array(samples.dropFirst(16_000)))
            try appender.close()
            let back = try HsegFile.read(url, key: key)
            #expect(back.samples.count == samples.count)
            #expect(!back.isTorn)
            #expect(back.encrypted == (key != nil))
            #expect(zip(back.samples, samples).allSatisfy { abs($0 - $1) < 0.0001 })
        }
    }

    @Test("a torn last frame is cut off and the frames before it are kept")
    func tornFrame() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("seg.hseg.part")
        let appender = try HsegAppender(creating: url, key: nil)
        try appender.append(tone(1))
        try appender.close()
        var data = try Data(contentsOf: url)
        let whole = data.count
        data.append(try HsegFile.frame(tone(1), key: nil).prefix(900))
        try data.write(to: url)
        let back = try HsegFile.read(url, key: nil)
        #expect(back.samples.count == 16_000)
        #expect(back.isTorn)
        #expect(back.validLength == whole)
    }

    @Test("an encrypted segment does not open without its key")
    func wrongKey() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("seg.hseg")
        let appender = try HsegAppender(creating: url, key: SymmetricKey(size: .bits256))
        try appender.append(tone(0.5))
        try appender.close()
        #expect(throws: HsegFile.Failure.wrongKey) { try HsegFile.read(url, key: SymmetricKey(size: .bits256)) }
        #expect(throws: HsegFile.Failure.wrongKey) { try HsegFile.read(url, key: nil) }
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("RIFF"), "no plaintext WAV inside")
    }

    // MARK: Writer

    @Test("ticks become sealed ~30 s segments on both sides, cut at the same moment, on disk and in rows")
    func writerSeals() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store()
        let id = try note(store)
        let writer = CaptureJournalWriter(store: store, noteId: id, folder: dir, key: nil, streams: [.mic])
        await writer.addStream(.system, at: 0)
        var sealed: [CaptureJournalWriter.Sealed] = []
        for _ in 0..<70 { sealed += try await writer.tick(mic: tone(1), system: tone(1, amplitude: 0.1)) }
        sealed += try await writer.sealAll()
        let journal = try store.captureJournal(noteId: id)
        let mic = journal.audio(.mic)
        let call = journal.audio(.system)
        #expect(mic.count == 3 && call.count == 3)
        #expect(mic.allSatisfy { $0.state == .sealed && $0.sha256 != nil })
        #expect(abs(journal.sealedSeconds(.mic) - 70) < 0.01, "nothing lost or doubled")
        #expect(zip(mic, call).allSatisfy { abs($0.duration - $1.duration) < 0.01 && abs($0.t0 - $1.t0) < 0.01 })
        #expect(mic[0].duration >= 30 && mic[0].duration <= 33)
        #expect(abs(mic[1].t0 - mic[0].duration) < 0.001)
        #expect(sealed.count == 6)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.filter { $0.hasSuffix(".hseg") }.count == 6)
        #expect(!files.contains { $0.hasSuffix(".part") })
    }

    @Test("a gap seals the side's segment and moves its clock, so later audio sits at the right time")
    func writerGap() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store()
        let id = try note(store)
        let writer = CaptureJournalWriter(store: store, noteId: id, folder: dir, key: nil, streams: [.mic])
        _ = try await writer.tick(mic: tone(5), system: nil)
        _ = try await writer.gap(.mic, seconds: 7, reason: .stall)
        _ = try await writer.tick(mic: tone(3), system: nil)
        _ = try await writer.sealAll()
        let rows = try store.captureJournal(noteId: id).segments
        #expect(rows.map(\.kind) == [.audio, .gap, .audio])
        #expect(rows[1].gapReason == .stall && rows[1].t0 == 5 && rows[1].duration == 7)
        #expect(abs(rows[2].t0 - 12) < 0.001)
    }

    @Test("a discarded recording writes nothing more and creates no file")
    func writerAbandon() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store()
        let id = try note(store)
        let writer = CaptureJournalWriter(store: store, noteId: id, folder: dir, key: nil, streams: [.mic])
        writer.abandon()
        _ = try await writer.tick(mic: tone(2), system: nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    // MARK: Adoption after a kill

    @Test("after a kill: an open .part is sealed with its torn frame cut, a missing file becomes a gap")
    func adoptAfterKill() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store()
        let id = try note(store)
        let writer = CaptureJournalWriter(store: store, noteId: id, folder: dir, key: nil, streams: [.mic])
        for _ in 0..<40 { _ = try await writer.tick(mic: tone(1), system: nil) }
        // The kill: the open segment's file is torn mid-frame, and one row never got its file.
        let open = try #require(try store.captureJournal(noteId: id).segments.first { $0.state == .open })
        let part = dir.appendingPathComponent(open.file! + ".part")
        let handle = try FileHandle(forWritingTo: part)
        try handle.seekToEnd()
        try handle.write(contentsOf: try HsegFile.frame(tone(1), key: nil).prefix(500))
        try handle.close()
        try store.insertSegment(CaptureSegment(
            noteId: id, stream: .mic, seq: 9, kind: .audio, t0: 50, duration: 2, file: "seg-000009-mic.hseg",
            format: .hseg1, state: .open))
        let outcome = try CaptureJournalAdopter.adopt(store: store, noteId: id, folder: dir, key: nil, readLegacy: { _, _ in [] })
        #expect(outcome.sealed == 1 && outcome.interrupted == 1 && outcome.tornBytes == 500)
        let journal = try store.captureJournal(noteId: id)
        #expect(!journal.hasOpenRows)
        #expect(abs(journal.sealedSeconds(.mic) - 40) < 0.01, "every synced tick is kept")
        #expect(journal.segments.contains { $0.kind == .gap && $0.gapReason == .interrupted })
        #expect(FinalizePlan.next(after: .sealing, journal: journal, hasTurns: false, isLive: false) == .transcribing)
        #expect(try CaptureJournalAdopter.adopt(store: store, noteId: id, folder: dir, key: nil, readLegacy: { _, _ in [] })
            == CaptureJournalAdopter.Outcome(), "adopting again changes nothing")
    }

    @Test("a legacy note's chunk files are adopted in order, the call side beside the microphone")
    func adoptLegacy() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store()
        let id = try note(store)
        for name in ["chunk-0000.wav", "chunk-0001.wav", "chunk-0000-system.wav", "chunk-0001-system.wav.enc"] {
            try Data([1]).write(to: dir.appendingPathComponent(name))
        }
        let outcome = try CaptureJournalAdopter.adopt(store: store, noteId: id, folder: dir, key: nil) { url, _ in
            [Float](repeating: 0.1, count: url.lastPathComponent.contains("0000") ? 16_000 * 30 : 16_000 * 12)
        }
        #expect(outcome.legacy == 4)
        let journal = try store.captureJournal(noteId: id)
        #expect(journal.audio(.mic).map(\.t0) == [0, 30])
        #expect(journal.audio(.system).map(\.t0) == [0, 30])
        #expect(journal.audio(.mic).allSatisfy { $0.state == .sealed && $0.format == .wav })
    }

    // MARK: Plan

    @Test("the plan finishes a note with audio, and needs attention only with no audio and no turns")
    func plan() {
        let empty = CaptureJournal(noteId: 1, segments: [])
        #expect(FinalizePlan.next(after: .capturing, journal: empty, hasTurns: false, isLive: true) == .capturing)
        #expect(FinalizePlan.next(after: .capturing, journal: empty, hasTurns: false, isLive: false) == .sealing)
        #expect(FinalizePlan.next(after: .transcribing, journal: empty, hasTurns: false, isLive: false) == .needsAttention)
        #expect(FinalizePlan.next(after: .transcribing, journal: empty, hasTurns: true, isLive: false) == .assembling)
        let silent = CaptureJournal(noteId: 1, segments: [CaptureSegment(
            noteId: 1, stream: .mic, seq: 0, kind: .audio, t0: 0, duration: 30, sampleCount: 480_000, file: "a",
            state: .transcribed, gapReason: .silence)])
        #expect(FinalizePlan.next(after: .transcribing, journal: silent, hasTurns: false, isLive: false) == .assembling,
                "a silent recording is a gap, never a failure")
        #expect(FinalizePlan.next(after: .exporting, journal: silent, hasTurns: false, isLive: false) == .done)
    }

    // MARK: Health

    private func feed(_ health: inout CaptureHealth, from: Int, to: Int, mic: (Int) -> (Int, Bool, Float),
                      call: ((Int) -> (Int, Bool, Float))? = nil) -> [CaptureHealth.Event] {
        var events: [CaptureHealth.Event] = []
        for second in from..<to {
            let t = Double(second)
            let (count, zero, rms) = mic(second)
            health.observe(.mic, samples: count, allZero: zero, rms: rms, at: t)
            if let call {
                let (c, z, r) = call(second)
                health.observe(.system, samples: c, allZero: z, rms: r, at: t)
            }
            events += health.evaluate(at: t)
        }
        return events
    }

    @Test("a stalled side is found within 8 s, stays stalled through a rebuild that does not help, and recovers")
    func healthStall() {
        var health = CaptureHealth(streams: [.mic], startedAt: 0)
        let speech: (Int) -> (Int, Bool, Float) = { _ in (16_000, false, 0.05) }
        #expect(feed(&health, from: 1, to: 30, mic: speech).isEmpty)
        let events = feed(&health, from: 30, to: 40, mic: { _ in (0, false, 0) })
        let stalled = try? #require(events.first)
        #expect(stalled?.problem == .stalled)
        #expect((stalled?.at ?? 99) <= 38)
        health.restarted(.mic, at: 40)
        #expect(feed(&health, from: 41, to: 45, mic: { _ in (0, false, 0) }).isEmpty)
        #expect(health.problem(.mic) == .stalled)
        let back = feed(&health, from: 45, to: 50, mic: speech)
        #expect(back.first?.problem == nil && back.count == 1)
    }

    @Test("exact zeros warn after 8 s on the microphone, on the call only while the microphone hears someone")
    func healthZeros() {
        var health = CaptureHealth(streams: [.mic, .system], startedAt: 0)
        let speech: (Int) -> (Int, Bool, Float) = { _ in (16_000, false, 0.05) }
        let zeros: (Int) -> (Int, Bool, Float) = { _ in (16_000, true, 0) }
        let room: (Int) -> (Int, Bool, Float) = { _ in (16_000, false, 0.002) }
        // A listener: room noise on the mic, the call quiet as exact zeros between sentences. Never a warning.
        #expect(feed(&health, from: 1, to: 120, mic: room, call: { $0 % 20 < 12 ? speech($0) : zeros($0) }).isEmpty)
        // The call's audio dies while the person talks.
        let dead = feed(&health, from: 120, to: 135, mic: speech, call: zeros)
        #expect(dead.first?.stream == .system && dead.first?.problem == .digitalSilence)
        #expect((dead.first?.at ?? 99) <= 129)
        var micOnly = CaptureHealth(streams: [.mic], startedAt: 0)
        let muted = feed(&micOnly, from: 1, to: 15, mic: zeros)
        #expect(muted.first?.problem == .digitalSilence && (muted.first?.at ?? 99) <= 10)
    }
}
