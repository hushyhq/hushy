import Foundation
import Testing
@testable import MurmurCore

/// Covers the note-folders storage API added in migration "v5-note-folders": creating,
/// renaming, deleting folders, moving notes between them, and the per-folder/unfiled counts
/// the UI's folder strip reads. Uses an in-memory store (see `Store.init()`), never the user's
/// real database.
@Suite("Store note folders")
struct StoreNoteFoldersTests {
    @Test("createFolder trims whitespace and persists the folder")
    func createFolderTrims() throws {
        let store = try Store()
        let folder = try store.createFolder(name: "  Work  ")
        #expect(folder.name == "Work")
        #expect(folder.id != nil)
        #expect(try store.folders().map(\.name) == ["Work"])
    }

    @Test("createFolder rejects an empty or whitespace-only name")
    func createFolderRejectsEmpty() throws {
        let store = try Store()
        #expect(throws: Store.FolderError.emptyName) {
            try store.createFolder(name: "   ")
        }
        #expect(try store.folders().isEmpty)
    }

    @Test("createFolder rejects a duplicate name case-insensitively")
    func createFolderRejectsDuplicate() throws {
        let store = try Store()
        _ = try store.createFolder(name: "Work")
        #expect(throws: Store.FolderError.duplicateName("WORK")) {
            try store.createFolder(name: "WORK")
        }
        #expect(try store.folders().count == 1)
    }

    @Test("folders are returned alphabetically")
    func foldersAreSortedAlphabetically() throws {
        let store = try Store()
        _ = try store.createFolder(name: "Zeta")
        _ = try store.createFolder(name: "alpha")
        _ = try store.createFolder(name: "Mid")
        #expect(try store.folders().map(\.name) == ["alpha", "Mid", "Zeta"])
    }

    @Test("renameFolder trims, validates, and updates the name")
    func renameFolderUpdatesName() throws {
        let store = try Store()
        let folder = try store.createFolder(name: "Work")
        let renamed = try store.renameFolder(id: folder.id!, to: "  Projects  ")
        #expect(renamed.name == "Projects")
        #expect(try store.folders().map(\.name) == ["Projects"])
    }

    @Test("renameFolder to its own current name (any case) is a no-op, not a duplicate error")
    func renameFolderToOwnNameIsNoOp() throws {
        let store = try Store()
        let folder = try store.createFolder(name: "Work")
        let renamed = try store.renameFolder(id: folder.id!, to: "WORK")
        #expect(renamed.name == "WORK")
    }

    @Test("renameFolder rejects a name that collides with a different folder")
    func renameFolderRejectsCollision() throws {
        let store = try Store()
        _ = try store.createFolder(name: "Work")
        let personal = try store.createFolder(name: "Personal")
        #expect(throws: Store.FolderError.duplicateName("work")) {
            try store.renameFolder(id: personal.id!, to: "work")
        }
    }

    @Test("renameFolder rejects an empty name")
    func renameFolderRejectsEmpty() throws {
        let store = try Store()
        let folder = try store.createFolder(name: "Work")
        #expect(throws: Store.FolderError.emptyName) {
            try store.renameFolder(id: folder.id!, to: "  ")
        }
    }

    @Test("deleteFolder removes the folder but keeps its notes, now unfiled")
    func deleteFolderKeepsNotes() throws {
        let store = try Store()
        let folder = try store.createFolder(name: "Work")
        let saved = try store.save(Note(title: "Standup", folderId: folder.id))
        #expect(try store.note(id: saved.id!)?.folderId == folder.id)

        try store.deleteFolder(id: folder.id!)

        #expect(try store.folders().isEmpty)
        let survivor = try store.note(id: saved.id!)
        #expect(survivor != nil)
        #expect(survivor?.folderId == nil)
    }

    @Test("moveNote assigns a note to a folder, and nil moves it back to unfiled")
    func moveNoteAssignsAndUnfiles() throws {
        let store = try Store()
        let folder = try store.createFolder(name: "Work")
        let note = try store.save(Note(title: "Standup"))
        #expect(note.folderId == nil)

        try store.moveNote(id: note.id!, toFolder: folder.id)
        #expect(try store.note(id: note.id!)?.folderId == folder.id)

        try store.moveNote(id: note.id!, toFolder: nil)
        #expect(try store.note(id: note.id!)?.folderId == nil)
    }

    @Test("noteCountsByFolder counts notes per folder and omits empty folders")
    func noteCountsByFolder() throws {
        let store = try Store()
        let work = try store.createFolder(name: "Work")
        let personal = try store.createFolder(name: "Personal")
        _ = try store.save(Note(title: "A", folderId: work.id))
        _ = try store.save(Note(title: "B", folderId: work.id))
        _ = try store.save(Note(title: "C", folderId: personal.id))
        _ = try store.save(Note(title: "D")) // unfiled

        let counts = try store.noteCountsByFolder()
        #expect(counts[work.id!] == 2)
        #expect(counts[personal.id!] == 1)
    }

    @Test("unfiledNoteCount counts only notes with no folder")
    func unfiledNoteCount() throws {
        let store = try Store()
        let folder = try store.createFolder(name: "Work")
        _ = try store.save(Note(title: "Filed", folderId: folder.id))
        _ = try store.save(Note(title: "Loose one"))
        _ = try store.save(Note(title: "Loose two"))

        #expect(try store.unfiledNoteCount() == 2)
    }

    @Test("saving a stale copy of a note keeps the folder it was moved to")
    func staleSaveKeepsFolder() throws {
        let store = try Store()
        let folder = try store.createFolder(name: "Work")
        var stale = try store.save(Note(title: "Standup"))
        try store.moveNote(id: stale.id!, toFolder: folder.id)
        stale.title = "Standup, renamed"
        _ = try store.save(stale)
        #expect(try store.note(id: stale.id!)?.folderId == folder.id)
        #expect(try store.note(id: stale.id!)?.title == "Standup, renamed")
    }

    @Test("clearing action item status forgets every checked item for that note only")
    func clearActionItemStatus() throws {
        let store = try Store()
        let a = try store.save(Note(title: "A"))
        let b = try store.save(Note(title: "B"))
        try store.setActionItemDone(noteId: a.id!, itemIndex: 0, isDone: true)
        try store.setActionItemDone(noteId: b.id!, itemIndex: 1, isDone: true)
        try store.clearActionItemStatus(noteId: a.id!)
        #expect(try store.doneActionItemIndexes(noteId: a.id!).isEmpty)
        #expect(try store.doneActionItemIndexes(noteId: b.id!) == [1])
    }
}
