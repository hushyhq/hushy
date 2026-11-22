import Foundation
import Testing
@testable import MurmurCore

/// The live screen reads a recording's turns from the store (meetings T4b): the capture rows by `t0`, only new rows
/// on each refresh, everything again only when the rows were replaced.
@Suite("Live turns from the store")
struct LiveTurnReaderTests {
    private func sealed(_ store: Store, note: Int64, seq: Int, stream: CaptureStream, t0: Double) throws -> Int64 {
        let row = try #require(try store.insertSegment(CaptureSegment(
            noteId: note, stream: stream, seq: seq, kind: .audio, t0: t0, duration: 30, sampleCount: 480_000,
            file: CaptureJournalWriter.fileName(seq: seq, stream: stream), format: .hseg1, state: .sealed)))
        return try #require(row.id)
    }

    @Test("turns arrive in time order as segments are recognised, both sides, and a refresh with nothing new changes nothing")
    func incremental() throws {
        let store = try Store()
        let id = try #require(try store.save(Note(title: "live", status: .recording)).id)
        var reader = LiveTurnReader()
        #expect(try !reader.refresh(noteId: id, store: store))
        #expect(reader.turns.isEmpty)

        let call0 = try sealed(store, note: id, seq: 0, stream: .system, t0: 0)
        let mic0 = try sealed(store, note: id, seq: 0, stream: .mic, t0: 0)
        try store.insertSegmentTurn(segmentId: call0, text: "first from the call", words: [NoteTurn.Word(w: "first", start: 1, end: 2, conf: 1)])
        try store.insertSegmentTurn(segmentId: mic0, text: "first from me", words: nil)
        #expect(try reader.refresh(noteId: id, store: store))
        #expect(reader.turns.map(\.text) == ["first from me", "first from the call"], "same t0: the microphone's ordinal first")
        #expect(reader.turns.allSatisfy { $0.words == nil }, "the screen shows text only")
        #expect(try !reader.refresh(noteId: id, store: store))

        let mic1 = try sealed(store, note: id, seq: 1, stream: .mic, t0: 30)
        try store.insertSegmentTurn(segmentId: mic1, text: "second from me", words: nil)
        #expect(try reader.refresh(noteId: id, store: store))
        #expect(reader.turns.map(\.text).last == "second from me")
        #expect(reader.turns.count == 3)
    }

    @Test("replaced rows (an assembly) or another note are read again from the start")
    func replacedRowsReload() throws {
        let store = try Store()
        let id = try #require(try store.save(Note(title: "live", status: .recording)).id)
        let other = try #require(try store.save(Note(title: "other", status: .recording)).id)
        let mic0 = try sealed(store, note: id, seq: 0, stream: .mic, t0: 0)
        try store.insertSegmentTurn(segmentId: mic0, text: "before", words: nil)
        var reader = LiveTurnReader()
        try reader.refresh(noteId: id, store: store)
        try store.replaceTurns(noteId: id, turns: [
            NoteTurn(noteId: id, ordinal: 0, stream: .mic, t0: 0, t1: 10, text: "after one", origin: .capture),
            NoteTurn(noteId: id, ordinal: 1, stream: .system, t0: 10, t1: 20, text: "after two", origin: .capture),
        ])
        #expect(try reader.refresh(noteId: id, store: store))
        #expect(reader.turns.map(\.text) == ["after one", "after two"])
        try reader.refresh(noteId: other, store: store)
        #expect(reader.turns.isEmpty)
        #expect(reader.noteId == other)
    }
}
