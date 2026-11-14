import Foundation

/// How History gets a dictation's words back. One answer per row, so the list, the detail pane
/// and the tests agree on it.
public enum DictationRecovery {
    public enum Action: Sendable, Equatable {
        /// The row has text: copy it (a cancelled row is also kept for good, see `Library.recover`).
        case copy
        /// No text, but the recording was kept: read it again.
        case retryTranscription
        /// Nothing to get back: no text and no audio.
        case none
    }

    /// A cancelled or failed take whose words were never read has audio and no text; copying it
    /// would put an empty string on the clipboard. Reading the recording again is the way back.
    public static func action(for dictation: Dictation) -> Action {
        if !dictation.text.isEmpty { return .copy }
        switch dictation.status {
        case .cancelled, .failed: return dictation.audioPath == nil ? .none : .retryTranscription
        case .inserted, .notInserted: return .none
        }
    }
}
