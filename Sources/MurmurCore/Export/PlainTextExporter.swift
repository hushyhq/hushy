import Foundation

/// Renders a plain-text transcript with a `[timestamp]` before each line, grouped the same way
/// as `SubtitleFormatter`'s cues (so the timestamps line up with what a viewer would see if they
/// exported subtitles from the same note) but without any line-length limit — this is a reading
/// transcript, not a subtitle track. Works from the same `TimedCueSource` rows `SubtitleFormatter`
/// does: word-level for an imported file, speaker-turn-level for a diarized live recording.
public enum PlainTextExporter {
    /// Groups `rows` into readable lines (capped at `maxCharsPerLine` for word-level rows; a
    /// diarized turn always gets its own line regardless of length, since it isn't safe to
    /// further split without that turn's own internal word timings) and prefixes each with its
    /// start time as `[MM:SS]`/`[H:MM:SS]`, plus the speaker's label when the row has one
    /// ("[1:02] Speaker 1: …").
    public static func timestampedText<Row: TimedCueSource>(rows: [Row], maxCharsPerLine: Int = 80) -> String {
        let usable = rows.filter { !$0.cueText.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return "" }

        var lines: [String] = []
        var current: [Row] = []
        var currentSpeaker: String?

        func flush() {
            guard let first = current.first else { return }
            let text = current.map(\.cueText).joined(separator: " ")
            let speakerPrefix = currentSpeaker.map { "\($0): " } ?? ""
            lines.append("[\(Timecode.plain(first.cueStartSeconds))] \(speakerPrefix)\(text)")
            current = []
        }

        for row in usable {
            let speakerChanged = !current.isEmpty && row.cueSpeakerLabel != currentSpeaker
            let candidate = current.isEmpty ? row.cueText : (current.map(\.cueText).joined(separator: " ") + " " + row.cueText)
            // A row that already carries a speaker label is a whole diarized turn (not a single
            // word), so it always starts its own line rather than being merged with neighbors.
            let isTurnLevel = row.cueSpeakerLabel != nil
            if speakerChanged || (candidate.count > maxCharsPerLine && !current.isEmpty) || (isTurnLevel && !current.isEmpty) {
                flush()
            }
            if current.isEmpty { currentSpeaker = row.cueSpeakerLabel }
            current.append(row)
            if isTurnLevel { flush() }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// Falls back to plain untimed text (no timestamps) when a note has no stored segments at
    /// all — a live microphone recording with no diarization run.
    public static func plainText(_ transcript: String) -> String { transcript }
}
