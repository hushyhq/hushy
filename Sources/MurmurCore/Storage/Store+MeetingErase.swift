import Foundation
import GRDB

/// "Erase meetings" on the Meetings screen. A meeting here is what the data model calls one: a note started
/// from the call-detected prompt (`meetingApp` set), `meetingApp` is the only mark. Memos,
/// imported files and recordings started by hand are not told apart from each other in the data, so none of them
/// is ever erased by it.
public struct MeetingErasePlan: Sendable, Equatable {
    /// Exactly the notes the confirmation counts and the erase removes.
    public let noteIDs: [Int64]
    public let audioBytes: Int64
    public var count: Int { noteIDs.count }

    public init(noteIDs: [Int64], audioBytes: Int64) {
        self.noteIDs = noteIDs
        self.audioBytes = audioBytes
    }
}

extension Store {
    static var meetingNotes: QueryInterfaceRequest<Note> { Note.filter(Column("meetingApp") != nil) }

    /// Every meeting except the notes in `keeping` (the one recording now). `audioBytes` counts their audio folders.
    public func meetingErasePlan(keeping: Set<Int64> = []) throws -> MeetingErasePlan {
        let notes = try writer.read { db in try Self.meetingNotes.order(Column("createdAt").desc).fetchAll(db) }
            .filter { $0.id.map { !keeping.contains($0) } ?? false }
        return MeetingErasePlan(
            noteIDs: notes.compactMap(\.id),
            audioBytes: notes.compactMap(\.audioPath).reduce(0) { $0 + Self.diskBytes(atPath: $1) })
    }

    /// Deletes the plan's notes in one transaction (their segments, lines and consent go with them), then their
    /// audio folders. A note that is no longer a meeting, or is gone, is left alone. Returns how many were erased.
    @discardableResult
    public func eraseMeetings(_ plan: MeetingErasePlan) throws -> Int {
        discardPreMeetingsBackup()
        let removed = try writer.write { db -> [Note] in
            let notes = try Self.meetingNotes.filter(keys: plan.noteIDs).fetchAll(db)
            for note in notes { _ = try note.delete(db) }
            return notes
        }
        for path in removed.compactMap(\.audioPath) { try? FileManager.default.removeItem(atPath: path) }
        return removed.count
    }

    static func diskBytes(atPath path: String) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
