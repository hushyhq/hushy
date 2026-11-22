import Foundation
import MurmurCore

/// How an import's queue row ends, from the note the finalize runner finished.
enum ImportOutcome {
    /// Shown on the queue row when the note ends failed. Placeholder: the founder owns the wording.
    static let incompleteMessage = "[placeholder] The file could not be fully transcribed."

    /// Done only when the note itself is ready, so the row and the note always agree.
    static func finalState(noteID: Int64?, status: Note.Status) -> FileTranscriber.State {
        guard let noteID else { return .failed("Couldn't save the imported note.") }
        return status == .ready ? .done(noteID: noteID) : .failed(incompleteMessage)
    }
}
