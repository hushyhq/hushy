import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// The thin Store APIs over the frozen meetings tables, and the pre-v26 backup.
@Suite("Meetings store APIs", .timeLimit(.minutes(1)))
struct MeetingsStoreAPITests {
    private func note(_ store: Store, transcript: String = "") throws -> Int64 {
        try store.save(Note(title: "Call", transcript: transcript, status: .recording)).id!
    }

    @Test("the finalize step only moves from the step it is at")
    func finalizeCompareAndSwap() throws {
        let store = try Store()
        let id = try note(store)
        #expect(try store.advanceFinalize(noteId: id, from: nil, to: .capturing, pipelineVersion: 1))
        #expect(try !store.advanceFinalize(noteId: id, from: nil, to: .sealing, pipelineVersion: 1))
        #expect(try store.advanceFinalize(noteId: id, from: .capturing, to: .sealing, pipelineVersion: 1))
        #expect(try !store.advanceFinalize(noteId: id, from: .capturing, to: .transcribing, pipelineVersion: 1))
        #expect(try store.finalizeState(noteId: id)?.step == .sealing)
    }

    @Test("a sealed segment's turn is written once and the segment is marked transcribed")
    func segmentTurn() throws {
        let store = try Store()
        let id = try note(store)
        let segment = try store.writer.write { db -> CaptureSegment in
            var row = CaptureSegment(
                noteId: id, stream: .system, seq: 3, kind: .audio, t0: 90, duration: 30, file: "seg-3-system.hseg",
                format: .hseg1, state: .sealed)
            try row.insert(db)
            return row
        }
        let words = [NoteTurn.Word(w: "hello", start: 90.1, end: 90.4, conf: 0.9, flags: NoteTurn.Word.echo)]
        #expect(try store.insertSegmentTurn(segmentId: segment.id!, text: "hello", words: words))
        #expect(try !store.insertSegmentTurn(segmentId: segment.id!, text: "hello", words: words))
        let turns = try store.turns(noteId: id)
        #expect(turns.count == 1)
        #expect(turns.first?.ordinal == 7)
        #expect(turns.first?.t1 == 120)
        #expect(turns.first?.words == words)
        #expect(try store.captureJournal(noteId: id).segments.map(\.state) == [.transcribed])
    }

    @Test("replacing turns rewrites the transcript cache from them")
    func replaceTurnsMaterializes() throws {
        let store = try Store()
        let id = try note(store, transcript: "old text")
        try store.replaceTurns(noteId: id, turns: [
            NoteTurn(noteId: id, ordinal: 5, stream: .mic, t0: 0, t1: 2, text: "First line.", origin: .capture),
            NoteTurn(noteId: id, ordinal: 2, stream: .system, t0: 2, t1: 4, text: "Second line.", origin: .capture),
        ])
        #expect(try store.turns(noteId: id).map(\.ordinal) == [0, 1])
        #expect(try store.note(id: id)?.transcript == "You: First line.\nSpeaker 1: Second line.")
    }

    @Test("model facts are replaced, but checked or edited ones stay and are not repeated")
    func replaceModelFacts() throws {
        let store = try Store()
        let id = try note(store)
        func fact(_ text: String, quote: String) -> MeetingFact {
            MeetingFact(noteId: id, kind: .action, ordinal: 0, text: text, quote: quote, grounding: .verified,
                        origin: .model, extractor: "x")
        }
        let first = try store.replaceModelFacts(noteId: id, extractor: "e1", facts: [
            fact("Send the deck", quote: "I'll send the deck"), fact("Book a room", quote: "book a room"),
        ])
        #expect(try store.setFactStatus(uuid: first[0].uuid, status: .done))
        try store.replaceModelFacts(noteId: id, extractor: "e2", facts: [
            fact("Send the deck", quote: "I'll send the deck."), fact("Call legal", quote: "call legal"),
        ])
        let facts = try store.facts(noteId: id)
        #expect(Set(facts.map(\.text)) == ["Send the deck", "Call legal"])
        #expect(facts.first { $0.text == "Send the deck" }?.status == .done)
        #expect(try !store.setFactStatus(uuid: "missing", status: .done))
    }

    @Test("an unsupported model fact is kept but not visible")
    func visibility() throws {
        let store = try Store()
        let id = try note(store)
        try store.replaceModelFacts(noteId: id, extractor: "e", facts: [
            MeetingFact(noteId: id, kind: .decision, ordinal: 0, text: "Invented", grounding: .unsupported, origin: .model, extractor: "e"),
        ])
        #expect(try store.facts(noteId: id).isEmpty)
        #expect(try store.facts(noteId: id, visibleOnly: false).map(\.isVisible) == [false])
    }
}
