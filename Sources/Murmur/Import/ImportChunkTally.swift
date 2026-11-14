import Foundation
import MurmurCore

/// What an import has heard so far, chunk by chunk. A chunk that returns no text (silence,
/// music) is a normal result. Only a chunk that threw counts as failed.
struct ImportChunkTally {
    private(set) var transcript = ""
    private(set) var words: [WordTiming] = []
    private(set) var failedChunks = 0

    var chunkFailed: Bool { failedChunks > 0 }

    mutating func record(text: String, words chunkWords: [WordTiming]) {
        if !text.isEmpty { transcript = transcript.isEmpty ? text : transcript + " " + text }
        words += chunkWords
    }

    mutating func recordFailure() {
        failedChunks += 1
    }

    var finalStatus: Note.Status {
        Note.finalizedStatus(transcript: transcript, chunkFailed: chunkFailed, persistenceFailed: false)
    }

    /// Shown on the queue row when the note ends failed. Placeholder: the founder owns the wording.
    static let incompleteMessage = "[placeholder] The file could not be fully transcribed."

    /// The queue row's end state for a saved note: done only when the note itself is ready, so
    /// the row and the note always agree.
    static func finalState(noteID: Int64?, status: Note.Status) -> FileTranscriber.State {
        guard let noteID else { return .failed("Couldn't save the imported note.") }
        return status == .ready ? .done(noteID: noteID) : .failed(incompleteMessage)
    }
}
