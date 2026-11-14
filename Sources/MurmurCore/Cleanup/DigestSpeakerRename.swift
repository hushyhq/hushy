import Foundation

/// When the user renames (or merges) a speaker, rewrites that speaker's old name in the note's
/// summary lines and action items — deterministically, with no model call.
///
/// Why this is safe to do without knowing who wrote the text: the app has no way to edit summary
/// or action-item text. Every writer is a model digest (`NoteRecorder`, `DiarizedDigest`,
/// `Library.resummarize`, `FileTranscriber`), so a "Speaker 3" in them is the label as the model
/// wrote it. What the user *can* change is untouched: the title is never rewritten, and
/// check-offs are keyed by item index, which a rewrite never moves. An item's owner and task
/// fields (`ActionItemDetail`) change with its line, so the two never name different people.
///
/// Only whole-word occurrences of the exact old name change ("Speaker 1" never touches
/// "Speaker 12"). A name that `SpeakerNameInference` guessed for the speaker is left alone: it can
/// be another person's real name, and that ambiguity is not resolvable without the model.
public enum DigestSpeakerRename {
    /// `note` with every whole-word `oldNames` occurrence in its summary and action items replaced
    /// by `newName`, or nil when nothing changed.
    public static func rewrite(_ note: Note, from oldNames: [String], to newName: String) -> Note? {
        let target = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let olds = Set(oldNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter { !$0.isEmpty && $0 != target }
        guard !target.isEmpty, !olds.isEmpty else { return nil }
        var copy = note
        copy.summary = replacing(olds, with: target, in: note.summary)
        let details = note.actionItemDetails?.map { detail in
            ActionItemDetail(
                owner: replacing(olds, with: target, in: detail.owner),
                task: replacing(olds, with: target, in: detail.task), due: detail.due)
        }
        copy.setActionItems(note.actionItems.map { replacing(olds, with: target, in: $0) }, details: details)
        let unchanged = copy.summary == note.summary && copy.actionItems == note.actionItems
            && copy.actionItemDetails == note.actionItemDetails
        return unchanged ? nil : copy
    }

    static func replacing(_ olds: Set<String>, with new: String, in text: String) -> String {
        // Longest first, so "Speaker 12" is handled before a shorter name that shares a prefix.
        olds.sorted { $0.count > $1.count }.reduce(text) { result, old in
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: old) + "(?![\\p{L}\\p{N}])"
            return result.replacingOccurrences(
                of: pattern, with: NSRegularExpression.escapedTemplate(for: new), options: .regularExpression)
        }
    }
}
