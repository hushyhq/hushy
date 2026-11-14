import Foundation

/// Where a note's restyle state is kept: `restyle.json` in the note's own folder (the one its audio chunks live in,
/// `AppPaths.notesAudioDirectory/<id>`). No schema change: the database is frozen at v29, and the note's stored text is
/// never written. Deleting the note removes the folder and this file with it; the uninstall's "Notes" step covers it.
/// Every reader of that folder looks only at `.wav` names, so the file is never taken for audio.
///
/// The file holds the note's text in other styles, as private as the transcript in the database beside it; it is
/// written with owner-only permissions and never logged.
public struct NoteStyleFile: Sendable, Equatable {
    public static let fileName = "restyle.json"

    public let url: URL

    public init(folder: URL) {
        url = folder.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// The file for `note`: in its audio folder, or the folder its id would have when it has none.
    public init?(note: Note, notesDirectory: URL = AppPaths.notesAudioDirectory) {
        if let path = note.audioPath {
            self.init(folder: URL(fileURLWithPath: path, isDirectory: true))
        } else if let id = note.id {
            self.init(folder: notesDirectory.appendingPathComponent("\(id)", isDirectory: true))
        } else {
            return nil
        }
    }

    /// The saved state when it was written from `body`; nil when there is none, it cannot be read, it is from another
    /// format, or the note's text has changed since (the versions no longer fit it).
    public func read(body: String) -> NoteStyleState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(NoteStyleState.self, from: data),
              state.format == NoteStyleState.currentFormat, state.fits(body) else { return nil }
        return state
    }

    /// Saves `state`, replacing the file in one step.
    public func write(_ state: NoteStyleState) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
