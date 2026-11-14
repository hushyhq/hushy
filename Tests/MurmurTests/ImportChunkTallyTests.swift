import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// How an import's chunks decide the note's status and the queue row's end state. No audio, no
/// model: the decision is a value.
@Suite("Import chunk outcomes")
@MainActor
struct ImportChunkTallyTests {
    @Test("a silent stretch between spoken ones does not fail the note")
    func silentChunkIsNotAFailure() {
        var tally = ImportChunkTally()
        tally.record(text: "First part of the talk.", words: [])
        tally.record(text: "", words: [])
        tally.record(text: "Last part.", words: [])

        #expect(!tally.chunkFailed)
        #expect(tally.transcript == "First part of the talk. Last part.")
        #expect(tally.finalStatus == .ready)
    }

    @Test("a chunk that threw fails the note")
    func thrownChunkFails() {
        var tally = ImportChunkTally()
        tally.record(text: "Spoken part.", words: [])
        tally.recordFailure()

        #expect(tally.chunkFailed)
        #expect(tally.finalStatus == .failed)
    }

    @Test("a model that is not ready fails every chunk, and the queue row says failed, not done")
    func everyChunkFailing() {
        var tally = ImportChunkTally()
        for _ in 0..<4 { tally.recordFailure() }

        let state = ImportChunkTally.finalState(noteID: 7, status: tally.finalStatus)

        guard case .failed = state else { Issue.record("expected a failed row, got \(state)"); return }
    }

    @Test("a ready note ends as done and selects the note")
    func readyIsDone() {
        #expect(ImportChunkTally.finalState(noteID: 7, status: .ready) == .done(noteID: 7))
    }

    @Test("a note that was not saved ends as failed")
    func unsavedIsFailed() {
        guard case .failed = ImportChunkTally.finalState(noteID: nil, status: .ready) else {
            Issue.record("expected failed"); return
        }
    }
}
