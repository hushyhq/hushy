import Foundation
import Testing
@testable import MurmurCore

@Suite("Dictation edit observation storage")
struct DictationEditObservationStoreTests {
    @Test("new saved dictations start with explicit not attempted coverage")
    func initializesCoverage() throws {
        let store = try Store()
        let inserted = try store.save(Dictation(rawText: "raw", text: "pasted", durationSeconds: 1))
        let failed = try store.save(Dictation(rawText: "", text: "", durationSeconds: 1, status: .failed))
        let insertedID = try #require(inserted.id)
        let failedID = try #require(failed.id)

        #expect(try store.editObservation(forDictation: insertedID)?.verdict == .unknown)
        #expect(try store.editObservation(forDictation: insertedID)?.coverage == .notAttempted)
        #expect(try store.editObservation(forDictation: failedID)?.coverage == .notAttempted)
    }

    @Test("latest observation replaces earlier coverage and keeps editState compatibility")
    func replacesLatestAndMirrorsLegacyState() throws {
        let store = try Store()
        let dictation = try store.save(Dictation(rawText: "raw", text: "pasted", durationSeconds: 1))
        let id = try #require(dictation.id)

        #expect(try store.recordEditObservation(.init(dictationID: id, verdict: .kept, coverage: .observed)))
        #expect(try store.editObservation(forDictation: id)?.verdict == .kept)
        #expect(try store.recentDictations().first(where: { $0.id == id })?.editState == .kept)

        #expect(try store.recordEditObservation(.init(dictationID: id, verdict: .unknown, coverage: .fieldCleared)))
        #expect(try store.editObservation(forDictation: id)?.coverage == .fieldCleared)
        #expect(try store.recentDictations().first(where: { $0.id == id })?.editState == nil)
    }

    @Test("secure and unknown security are retained as distinct content-free reasons")
    func persistsSecurityReasons() throws {
        let store = try Store()
        let dictation = try store.save(Dictation(rawText: "raw", text: "pasted", durationSeconds: 1))
        let id = try #require(dictation.id)

        for reason in [DictationEditObservation.Coverage.secure, .unknownSecurity] {
            #expect(try store.recordEditObservation(.init(dictationID: id, verdict: .unknown, coverage: reason)))
            #expect(try store.editObservation(forDictation: id)?.coverage == reason)
        }
    }

    @Test("failed, clipboard-only and empty dictations cannot gain edit observations")
    func rejectsIneligibleRows() throws {
        let store = try Store()
        let failed = try store.save(Dictation(rawText: "raw", text: "text", durationSeconds: 1, status: .failed))
        let copied = try store.save(Dictation(rawText: "raw", text: "text", durationSeconds: 1, status: .notInserted))
        let empty = try store.save(Dictation(rawText: "", text: "", durationSeconds: 1, status: .inserted))
        let failedID = try #require(failed.id)
        let copiedID = try #require(copied.id)
        let emptyID = try #require(empty.id)
        #expect(try store.recordEditObservation(.init(dictationID: failedID, verdict: .unknown, coverage: .fieldUnreadable)) == false)
        #expect(try store.recordEditObservation(.init(dictationID: copiedID, verdict: .unknown, coverage: .fieldUnreadable)) == false)
        #expect(try store.recordEditObservation(.init(dictationID: emptyID, verdict: .unknown, coverage: .fieldUnreadable)) == false)
        #expect(try store.editObservation(forDictation: copiedID)?.coverage == .notAttempted)
    }

    @Test("deleted history rows make delayed watcher updates harmless")
    func deletedRowIsStaleSafe() throws {
        let store = try Store()
        let dictation = try store.save(Dictation(rawText: "raw", text: "pasted", durationSeconds: 1))
        let id = try #require(dictation.id)
        try store.deleteDictation(id: id)

        #expect(try store.recordEditObservation(.init(dictationID: id, verdict: .kept, coverage: .observed)) == false)
        #expect(try store.editObservation(forDictation: id) == nil)
    }

    @Test("retranscription resets observations and retires old callbacks")
    func retranscriptionRetiresObservation() throws {
        let store = try Store()
        let row = try store.save(Dictation(rawText: "raw", text: "original paste", durationSeconds: 1))
        let id = try #require(row.id)
        let observed = try DictationEditObservation(dictationID: id, verdict: .kept, coverage: .observed)
        #expect(try store.recordEditObservation(observed, expectedInsertedText: "original paste"))
        try store.updateTranscription(id: id, rawText: "retry", text: "new transcript", status: .inserted)
        #expect(try store.isCurrentEditObservation(dictationID: id, expectedInsertedText: "original paste") == false)
        #expect(try store.recordEditObservation(observed, expectedInsertedText: "original paste") == false)
        #expect(try store.editObservation(forDictation: id)?.coverage == .notAttempted)
        #expect(try store.recentDictations().first?.editState == nil)
    }

    @Test("same-text retry rotates the observation generation")
    func sameTextGeneration() throws {
        let store = try Store()
        let id = try #require(store.save(Dictation(rawText: "raw", text: "paste", durationSeconds: 1)).id)
        let generation = try #require(try store.editObservationGeneration(forDictation: id))
        try store.updateTranscription(id: id, rawText: "raw", text: "paste", status: .inserted)
        #expect(try store.editObservationGeneration(forDictation: id) != generation)
        #expect(try store.recordEditObservation(.init(dictationID: id, verdict: .kept, coverage: .observed), expectedInsertedText: "paste", expectedGeneration: generation) == false)
    }

    @Test("detached learning writes reject retired generations atomically")
    func staleLearning() throws {
        let store = try Store()
        let id = try #require(store.save(Dictation(rawText: "Call Pria today", text: "Call Pria today", durationSeconds: 1)).id)
        let generation = try #require(try store.editObservationGeneration(forDictation: id))
        let capture = CorrectionCapture(dictationID: id, appBundleID: nil, capturedAt: Date(),
            events: [CorrectionEvent(kind: .asrTerm, before: "Pria", after: "Priya")])
        try store.updateTranscription(id: id, rawText: "Call Pria today", text: "Call Pria today", status: .inserted)
        #expect(try store.recordCorrections(capture, expectedInsertedText: "Call Pria today", expectedObservationGeneration: generation).isEmpty)
        #expect(try store.learnedItems().isEmpty)
        let current = try #require(try store.editObservationGeneration(forDictation: id))
        _ = try store.recordCorrections(capture, expectedInsertedText: "Call Pria today", expectedObservationGeneration: current)
        #expect(try store.learnedItems().count == 1)
    }

    @Test("coverage and verdict invariants reject impossible persisted pairs")
    func validatesPair() {
        #expect(throws: DictationEditObservation.ValidationError.verdictDoesNotMatchCoverage) {
            try DictationEditObservation(dictationID: 1, verdict: .kept, coverage: .secure)
        }
        #expect(throws: DictationEditObservation.ValidationError.verdictDoesNotMatchCoverage) {
            try DictationEditObservation(dictationID: 1, verdict: .unknown, coverage: .observed)
        }
    }
}
