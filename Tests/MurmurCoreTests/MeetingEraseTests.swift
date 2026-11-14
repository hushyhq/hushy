import Foundation
import Testing
@testable import MurmurCore

@Suite("Erase meetings")
struct MeetingEraseTests {
    private struct Library {
        let store: Store
        let folder: URL
        var memo: Note, imported: Note, locked: Note, zoom: Note, teams: Note, recording: Note
    }

    private func audioFolder(_ root: URL, _ name: String, bytes: Int) throws -> String {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: folder.appendingPathComponent("chunk-0000.wav"))
        return folder.path
    }

    private func library() throws -> Library {
        let store = try Store()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erase-\(UUID().uuidString)", isDirectory: true)
        func save(_ title: String, app: MeetingApp?, source: Note.Source = .recording, age: TimeInterval = 0, bytes: Int = 0) throws -> Note {
            let path = bytes > 0 ? try audioFolder(root, title, bytes: bytes) : nil
            return try store.save(Note(title: title, createdAt: Date().addingTimeInterval(-age), status: .ready,
                                       audioPath: path, source: source, meetingApp: app))
        }
        return Library(
            store: store, folder: root,
            memo: try save("memo", app: nil, bytes: 100),
            imported: try save("import", app: nil, source: .file, bytes: 100),
            locked: try save("old memo", app: nil, age: 90 * 86_400),
            zoom: try save("zoom", app: .zoom, bytes: 1_000),
            teams: try save("teams", app: .teams, age: 90 * 86_400, bytes: 500),
            recording: try save("live", app: .zoom))
    }

    @Test("only notes recorded from a detected call are counted, and the one recording now is kept out")
    func countsMeetingsOnly() throws {
        let lib = try library()
        defer { try? FileManager.default.removeItem(at: lib.folder) }
        let plan = try lib.store.meetingErasePlan(keeping: [lib.recording.id!])
        #expect(Set(plan.noteIDs) == [lib.zoom.id!, lib.teams.id!])
        #expect(plan.count == 2)
        #expect(plan.audioBytes == 1_500)
    }

    @Test("erasing removes exactly the counted meetings and their audio; memos, imports and old notes stay")
    func erasesExactlyThePlan() throws {
        let lib = try library()
        defer { try? FileManager.default.removeItem(at: lib.folder) }
        _ = try lib.store.addJot(noteId: lib.zoom.id!, text: "! pilot is 4k", atSeconds: 3)
        let plan = try lib.store.meetingErasePlan(keeping: [lib.recording.id!])
        #expect(try lib.store.eraseMeetings(plan) == plan.count)
        let left = Set(try lib.store.notes(limit: 100).compactMap(\.id))
        #expect(left == [lib.memo.id!, lib.imported.id!, lib.locked.id!, lib.recording.id!])
        #expect(try lib.store.jots(noteId: lib.zoom.id!).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: lib.zoom.audioPath!))
        #expect(!FileManager.default.fileExists(atPath: lib.teams.audioPath!))
        #expect(FileManager.default.fileExists(atPath: lib.memo.audioPath!))
        #expect(FileManager.default.fileExists(atPath: lib.imported.audioPath!))
        #expect(try lib.store.meetingErasePlan(keeping: [lib.recording.id!]).count == 0)
    }

    @Test("a plan never erases a note it did not count, even one asked for by id")
    func planIsTheLimit() throws {
        let lib = try library()
        defer { try? FileManager.default.removeItem(at: lib.folder) }
        let forged = MeetingErasePlan(noteIDs: [lib.memo.id!, lib.zoom.id!], audioBytes: 0)
        #expect(try lib.store.eraseMeetings(forged) == 1)
        #expect(try lib.store.note(id: lib.memo.id!) != nil, "a memo is not a meeting")
        #expect(try lib.store.note(id: lib.zoom.id!) == nil)
    }
}
