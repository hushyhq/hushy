import Foundation

/// Exports a note's transcript as SRT, WebVTT, or timestamped plain text — the formats offered
/// alongside the existing Markdown export (see `MarkdownExporter`). Timed rows come from
/// `Store.noteSegments(noteId:)`: word-level for an imported file (`FileTranscriber`, `speakerId`
/// always nil) or speaker-turn-level for a live recording that ran diarization (`SpeakerDiarizer`).
/// A note with no stored segments (a live recording with no diarization, or one from before
/// migration v6) falls back to plain untimed text for the "plain text" format and has nothing to
/// offer for SRT/VTT — callers should hide those options rather than export an empty subtitle
/// file (see `NoteActions` in `NotesView`, gated on `AppModel.hasTimedTranscript`).
public enum NoteTranscriptExporter {
    public enum Format: String, CaseIterable, Sendable {
        case srt, vtt, plainText

        public var fileExtension: String {
            switch self {
            case .srt: "srt"
            case .vtt: "vtt"
            case .plainText: "txt"
            }
        }

        public var displayName: String {
            switch self {
            case .srt: "SRT Subtitles"
            case .vtt: "WebVTT Subtitles"
            case .plainText: "Plain Text (Timestamped)"
            }
        }
    }

    /// Renders `note`'s transcript in `format` using `segments` (its stored timed rows, if any,
    /// each optionally carrying a speaker — see `NoteSegmentWithSpeaker`). `segments` empty means
    /// "no timings" — SRT/VTT then render as an empty file (callers should have already excluded
    /// those formats from the UI in that case; this still returns something sane rather than
    /// crashing) and plain text falls back to the untimed transcript.
    public static func render(_ note: Note, segments: [NoteSegmentWithSpeaker], format: Format) -> String {
        switch format {
        case .srt:
            return SubtitleFormatter.srt(cues: SubtitleFormatter.cues(from: segments))
        case .vtt:
            return SubtitleFormatter.vtt(cues: SubtitleFormatter.cues(from: segments))
        case .plainText:
            guard !segments.isEmpty else { return PlainTextExporter.plainText(note.transcript) }
            return PlainTextExporter.timestampedText(rows: segments)
        }
    }

    public static func fileName(for note: Note, format: Format) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let safeTitle = note.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
            .prefix(80)
        return "\(formatter.string(from: note.createdAt)) \(safeTitle).\(format.fileExtension)"
    }

    /// Atomically writes the rendered export into `directory`, replacing any previous export of
    /// the same note and format.
    @discardableResult
    public static func export(
        _ note: Note, segments: [NoteSegmentWithSpeaker], format: Format, to directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: note, format: format))
        try render(note, segments: segments, format: format).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
