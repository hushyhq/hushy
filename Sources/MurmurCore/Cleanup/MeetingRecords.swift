import Foundation

/// The typed rows a meeting's notes are made of, and where each one lives. Cross-meeting memory
/// and anything else that reads meeting notes builds on these; keep their shapes stable.
///
/// - Action item: `ActionItemDetail` (owner, task, due phrase), stored line for line beside
///   `Note.actionItems`. An empty owner means
///   nobody took it (the summary leaves a name it cannot find in the meeting unassigned,
///   `DigestGrounding`). An empty due means no time was said.
/// - Status: `NoteActionItemStatus`, one row per checked-off item, keyed by note and item index.
/// - Decision: `MeetingDecision`, read from the summary's "- Decided: …" lines (`decisions(in:)`).
/// - Person: a speaker, `NoteSpeaker` (label, and the name the user gave it), per note.
/// - Timestamp and quote anchor: not stored yet. A quote field on action items cost the 4B real
///   items on the AMI test set (DECISIONS 2026-11-06), so it was taken out again.
/// - Company: not extracted yet.
public enum MeetingRecords {
    /// The summary's decisions, in the order the summary lists them.
    public static func decisions(in summary: String) -> [MeetingDecision] {
        summary.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(decidedPrefix) else { return nil }
            let decision = text.dropFirst(decidedPrefix.count).trimmingCharacters(in: .whitespaces)
            return decision.isEmpty ? nil : MeetingDecision(text: decision)
        }
    }

    static let decidedPrefix = "- Decided:"
}

/// One decision from a meeting, as the summary wrote it.
public struct MeetingDecision: Codable, Sendable, Equatable, Hashable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}
