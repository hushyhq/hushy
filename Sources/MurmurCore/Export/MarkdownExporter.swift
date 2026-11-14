import Foundation

/// Writes notes as Markdown files with YAML front-matter, so any tool (Claude Code, Codex,
/// Obsidian) can read them straight from disk.
public enum MarkdownExporter {
    /// `done` are the note's checked-off action-item indexes (kept apart from the note); those
    /// items are written `- [x]`. Each item is its one-line form, so an owner and a due date, when the
    /// summary found them, read the same as in the note ("Priya: Send the deck — by Friday").
    /// `transcript` is the note's turns (`Store.transcript(noteId:)`); without it the stored cache of
    /// those turns is used, which is the same text.
    public static func markdown(for note: Note, transcript: NoteTranscript? = nil, done: Set<Int> = []) -> String {
        let body = transcript?.rendered ?? note.transcript
        var lines = [
            "---",
            "title: \(yamlQuoted(note.title))",
            "date: \(ISO8601DateFormatter().string(from: note.createdAt))",
            "duration_minutes: \(Int((note.durationSeconds / 60).rounded()))",
            "source: hushy",
            "id: \(note.id ?? 0)",
            "---",
            "",
            "# \(note.title)",
            "",
        ]
        if !note.summary.isEmpty {
            lines += ["## Summary", "", note.summary, ""]
        }
        if !note.actionItems.isEmpty {
            let items = note.actionItems.enumerated().map { "- [\(done.contains($0.offset) ? "x" : " ")] \($0.element)" }
            lines += ["## Action items", ""] + items + [""]
        }
        lines += ["## Transcript", "", body.isEmpty ? "_No speech captured._" : body, ""]
        return lines.joined(separator: "\n")
    }

    public static func fileName(for note: Note) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let safeTitle = note.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
            .prefix(80)
        return "\(formatter.string(from: note.createdAt)) \(safeTitle).md"
    }

    /// Atomically writes the note into `directory`, replacing any previous export of the same note.
    @discardableResult
    public static func export(_ note: Note, transcript: NoteTranscript? = nil, to directory: URL, done: Set<Int> = []) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: note))
        try markdown(for: note, transcript: transcript, done: done).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func yamlQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
