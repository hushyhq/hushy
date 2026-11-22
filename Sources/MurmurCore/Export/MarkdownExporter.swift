import Foundation

/// Writes notes as Markdown files with YAML front-matter, so any tool (Claude Code, Codex,
/// Obsidian) can read them straight from disk.
public enum MarkdownExporter {
    /// `done` are the note's checked-off action-item indexes (kept apart from the note); those
    /// items are written `- [x]`. Each item is its one-line form, so an owner and a due date, when the
    /// summary found them, read the same as in the note ("Priya: Send the deck — by Friday").
    /// `transcript` is the note's turns (`Store.transcript(noteId:)`); without it the stored cache of
    /// those turns is used, which is the same text.
    ///
    /// `facts` are the note's visible facts (`Store.facts(noteId:)`): with them the note's decisions, action items and
    /// open questions are written from the facts, each with its `[mm:ss]` link and quote, and the summary keeps only its
    /// key points. Without them (a caller with no store, or a note with no facts) the stored columns are written as before.
    public static func markdown(
        for note: Note, transcript: NoteTranscript? = nil, facts: [MeetingFact]? = nil, done: Set<Int> = []
    ) -> String {
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
        if let facts, !facts.isEmpty {
            let points = LegacySummary.keyPoints(note.summary)
            if !points.isEmpty { lines += ["## Summary", ""] + points.map { "- \($0)" } + [""] }
            for section in MeetingFactText.sections(facts) {
                lines += ["## \(section.title)", ""] + section.facts.flatMap { MeetingFactText.markdown($0, noteId: note.id ?? 0) } + [""]
            }
        } else if !note.summary.isEmpty {
            lines += ["## Summary", "", note.summary, ""]
        }
        if facts?.isEmpty ?? true, !note.actionItems.isEmpty {
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
    public static func export(
        _ note: Note, transcript: NoteTranscript? = nil, facts: [MeetingFact]? = nil, to directory: URL, done: Set<Int> = []
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: note))
        try markdown(for: note, transcript: transcript, facts: facts, done: done).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func yamlQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
