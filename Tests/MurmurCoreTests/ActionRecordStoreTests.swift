import Foundation
import Testing
@testable import MurmurCore

@Suite("ActionRecord + Store (v9-actions migration)")
struct ActionRecordStoreTests {
    @Test("migration v9-actions creates a usable actionRecord table")
    func migrationCreatesTable() throws {
        let store = try Store()
        let record = ActionRecord(kind: .createEvent, title: "Dentist", detail: "Tomorrow · 3:00 PM", sourceText: "add a dentist appointment tomorrow at 3")
        let saved = try store.save(record)
        #expect(saved.id != nil)
    }

    @Test("recentActions returns newest first")
    func recentActionsOrdering() throws {
        let store = try Store()
        let first = try store.save(ActionRecord(createdAt: Date().addingTimeInterval(-100), kind: .createReminder, title: "Older", sourceText: "x"))
        let second = try store.save(ActionRecord(createdAt: Date(), kind: .createReminder, title: "Newer", sourceText: "y"))
        let recent = try store.recentActions()
        #expect(recent.first?.id == second.id)
        #expect(recent.last?.id == first.id)
    }

    @Test("markActionUndone flips status and clears the undo token")
    func markUndone() throws {
        let store = try Store()
        let saved = try store.save(ActionRecord(kind: .createEvent, title: "Dentist", sourceText: "x", undoBackendID: "abc"))
        try store.markActionUndone(id: saved.id!)
        let recent = try store.recentActions()
        #expect(recent.first?.status == .undone)
        #expect(recent.first?.undoBackendID == nil)
    }

    @Test("expireActionUndo clears the undo token but keeps the completed status")
    func expireUndo() throws {
        let store = try Store()
        let saved = try store.save(ActionRecord(kind: .createReminder, title: "Send the deck", sourceText: "x", undoBackendID: "abc"))
        try store.expireActionUndo(id: saved.id!)
        let fetched = try #require(try store.actionRecord(id: saved.id!))
        #expect(fetched.status == .completed)
        #expect(fetched.undoBackendID == nil)
    }

    @Test("actionRecord.dictationID sets null when the referenced dictation is deleted")
    func dictationDeletionSetsNull() throws {
        let store = try Store()
        let dictation = try store.save(Dictation(rawText: "hello", text: "hello", durationSeconds: 1))
        let action = try store.save(ActionRecord(kind: .createReminder, title: "Buy flowers", sourceText: "remind me to buy flowers", dictationID: dictation.id))
        try store.deleteDictation(id: dictation.id!)
        let recent = try store.recentActions()
        #expect(recent.first?.id == action.id)
        #expect(recent.first?.dictationID == nil)
    }
}
