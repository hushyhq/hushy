import Foundation

/// The "Label: text" transcript of a legacy note's stored speaker segments (the meetings eval reads its golden
/// transcripts through it). The re-summary merge is gone: a meeting is summarized once after its turns are
/// assembled, and "Summarize again" replaces only the facts the person has not touched (`Store.replaceModelFacts`).
public enum DiarizedDigest {
    // MARK: - Transcript

    /// Speaker turns as "Label: text" lines (the label is the display label, so a renamed speaker
    /// is used by name), consecutive turns by one speaker joined. Nil unless at least two distinct
    /// speakers have text.
    public static func transcript(from segments: [NoteSegmentWithSpeaker]) -> String? {
        var lines: [(label: String?, text: String)] = []
        for row in segments {
            let text = row.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let label = row.speaker?.displayLabel
            if let last = lines.last, last.label == label {
                lines[lines.count - 1].text += " " + text
            } else {
                lines.append((label, text))
            }
        }
        guard Set(lines.compactMap(\.label)).count >= 2 else { return nil }
        return lines.map { line in line.label.map { "\($0): \(line.text)" } ?? line.text }.joined(separator: "\n")
    }
}
