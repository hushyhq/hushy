import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// How an import's queue row ends, from the status the finalize runner left on the note.
@Suite("Import outcomes")
@MainActor
struct ImportOutcomeTests {
    @Test("a ready note ends as done and selects the note")
    func readyIsDone() {
        #expect(ImportOutcome.finalState(noteID: 7, status: .ready) == .done(noteID: 7))
    }

    @Test("a note the runner left failed ends as failed, not done")
    func failedIsFailed() {
        #expect(ImportOutcome.finalState(noteID: 7, status: .failed) == .failed(ImportOutcome.incompleteMessage))
    }

    @Test("a note that was not saved ends as failed")
    func unsavedIsFailed() {
        guard case .failed = ImportOutcome.finalState(noteID: nil, status: .ready) else {
            Issue.record("expected failed"); return
        }
    }
}
