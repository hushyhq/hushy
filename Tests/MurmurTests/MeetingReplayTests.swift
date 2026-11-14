import CryptoKit
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The after-the-call path on synthetic audio: chunk files laid out the way `NoteRecorder` writes
/// them (mic and call side, plain and encrypted), a typed line stamped mid-meeting, the page built
/// from the store, and a replay from the typed line's moment that contains the sound said then.
@Suite("Meeting replay from a moment")
struct MeetingReplayTests {
    private static let rate = AudioCapture.sampleRate

    /// One second of a tone at `frequency`, so each second of the recording can be told apart.
    private static func tone(_ frequency: Double, seconds: Double, level: Float = 0.3) -> [Float] {
        (0..<Int(seconds * rate)).map { level * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("chunks line up end to end, both sides are mixed, and an excerpt starts where asked",
          arguments: [false, true])
    func excerptFromMoment(encrypted: Bool) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = encrypted ? SymmetricKey(size: .bits256) : nil
        // Two parts as the recorder cuts them: 12 s then 9 s; the call side only talks in part two.
        try WAVWriter.write(Self.tone(220, seconds: 12), to: dir.appendingPathComponent("chunk-0000.wav"), key: key)
        try WAVWriter.write([Float](repeating: 0, count: Int(12 * Self.rate)), to: dir.appendingPathComponent("chunk-0000-system.wav"), key: key)
        try WAVWriter.write([Float](repeating: 0, count: Int(9 * Self.rate)), to: dir.appendingPathComponent("chunk-0001.wav"), key: key)
        try WAVWriter.write(Self.tone(440, seconds: 9), to: dir.appendingPathComponent("chunk-0001-system.wav"), key: key)

        let spans = MeetingAudioPlayer.spans(in: dir, key: key)
        #expect(spans.count == 2)
        #expect(abs(spans[1].start - 12) < 0.05, "the second part starts where the first ends")
        #expect(spans.allSatisfy { $0.systemURL != nil })

        let data = try #require(MeetingAudioPlayer.excerpt(spans: spans, from: 13, key: key))
        let samples = Self.samples(fromWAV: data)
        #expect(abs(Double(samples.count) / Self.rate - 8) < 0.1, "from 0:13 to the end is 8 s, under the 45 s cap")
        #expect(samples.prefix(Int(Self.rate)).map(abs).max() ?? 0 > 0.1, "the call side is heard in the mix")
    }

    @Test("a line typed during the meeting opens the turn said then, and the page keeps it as yours")
    func typedLineOnThePage() throws {
        let store = try Store()
        var note = Note(title: "Pilot call", createdAt: Date(), transcript: "We agree on the pilot price. Legal signs next week.", status: .ready)
        note.summary = "- Decided: pilot price agreed"
        let id = try #require(try store.save(note).id)
        _ = try store.replaceSpeakerSegments(
            noteId: id, speakers: [NoteSpeaker(noteId: id, label: "You"), NoteSpeaker(noteId: id, label: "Speaker 1", displayName: "Dana")],
            segments: [(0, AlignedSegment(speakerLabel: "You", start: 0, end: 11, text: "We agree on the pilot price.")),
                       (1, AlignedSegment(speakerLabel: "Speaker 1", start: 12, end: 20, text: "Legal signs next week."))])
        try store.addJot(noteId: id, text: "legal timing?", atSeconds: 14)

        let saved = try #require(try store.note(id: id))
        let page = MeetingPage.build(
            rows: StoredSummaryDigest().rows(for: saved), lines: MeetingLine.lines(from: try store.noteSegments(noteId: id)),
            jots: try store.jots(noteId: id), doneIndexes: [], myNames: ["You"])
        #expect(page.yourNotes.first?.moment?.lineIndex == 1)
        #expect(page.yourNotes.first?.moment?.speaker == "Dana")
        #expect(page.openQuestions.first?.author == .you)
        #expect(page.decisions.first?.moment?.lineIndex == 0)
    }

    /// 16-bit mono samples back out of `HistoryPlaybackAudio.wavData`.
    private static func samples(fromWAV data: Data) -> [Float] {
        let body = data.dropFirst(HistoryPlaybackAudio.headerByteCount)
        return stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { index in
            let value = Int16(bitPattern: UInt16(body[index]) | UInt16(body[index + 1]) << 8)
            return Float(value) / Float(Int16.max)
        }
    }
}
