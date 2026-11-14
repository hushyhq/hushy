import Foundation

/// One piece of timed text `SubtitleFormatter` can pack into cues: a word (imported-file
/// transcription stores one `note_segment` row per word, `speakerId` nil — see
/// `.claude/DECISIONS.md`'s file-import/speaker-labels reconciliation entry) or a whole
/// diarized speaker turn (live recordings that ran `SpeakerDiarizer` store one row per turn).
/// `SubtitleFormatter` doesn't need to know which — it only needs text, a time span, and
/// optionally who said it.
public protocol TimedCueSource {
    var cueText: String { get }
    var cueStartSeconds: Double { get }
    var cueEndSeconds: Double { get }
    /// The speaker's display label ("Speaker 1", or their renamed label), or `nil` when
    /// unattributed (every segment from an imported file, or a live recording with no
    /// diarization run yet). A cue built from a `nil`-speaker source has no prefix.
    var cueSpeakerLabel: String? { get }
}

extension WordTiming: TimedCueSource {
    public var cueText: String { word }
    public var cueStartSeconds: Double { start }
    public var cueEndSeconds: Double { end }
    public var cueSpeakerLabel: String? { nil }
}

extension NoteSegmentWithSpeaker: TimedCueSource {
    public var cueText: String { segment.text }
    public var cueStartSeconds: Double { segment.startTime }
    public var cueEndSeconds: Double { segment.endTime }
    public var cueSpeakerLabel: String? { speaker?.displayLabel }
}

/// Builds SRT and WebVTT subtitle cues from timed transcript rows: word-level timings (imported
/// files — see `FileTranscriber`) or diarized speaker turns (live recordings — see
/// `SpeakerDiarizer`), both stored as `note_segment` rows and read back via
/// `Store.noteSegments(noteId:)` as `NoteSegmentWithSpeaker`.
///
/// Standard readability constraints, matching common subtitle conventions (Netflix's timed-text
/// style guide and the BBC subtitle guidelines land on very similar numbers):
///   - at most `maxCharsPerLine` characters per line
///   - at most `maxLinesPerCue` lines per cue
///   - at most `maxCueSeconds` on screen per cue
/// Input rows are greedily packed into lines/cues up to those limits, breaking only at row
/// boundaries (a word for imports, a whole speaker turn's text for diarized recordings — the
/// packer never splits a turn's text mid-word, since a turn does not carry its own internal word
/// timings) and preferring to break before the row that would overflow. A speaker change always
/// starts a fresh cue, so one cue never mixes two speakers' text.
public enum SubtitleFormatter {
    public struct Options: Sendable {
        public var maxCharsPerLine: Int
        public var maxLinesPerCue: Int
        public var maxCueSeconds: Double

        public init(maxCharsPerLine: Int = 42, maxLinesPerCue: Int = 2, maxCueSeconds: Double = 7) {
            self.maxCharsPerLine = maxCharsPerLine
            self.maxLinesPerCue = maxLinesPerCue
            self.maxCueSeconds = maxCueSeconds
        }
    }

    /// One subtitle cue: the lines of text to display and the time range to show them.
    public struct Cue: Sendable, Equatable {
        public let lines: [String]
        public let startSeconds: Double
        public let endSeconds: Double

        public init(lines: [String], startSeconds: Double, endSeconds: Double) {
            self.lines = lines
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
        }
    }

    /// Packs `rows` (in time order, non-blank text) into cues obeying `options`. Rows with blank
    /// text are skipped. When a row has a speaker label, the cue's first line is prefixed
    /// "Speaker label: …"; unattributed rows (imports, or a live recording with no diarization)
    /// get no prefix. A single row whose text is longer than `maxCharsPerLine` is kept whole on
    /// its own line rather than split mid-word (this only matters for turn-level/diarized rows —
    /// a per-word import row is essentially always short enough to fit).
    public static func cues<Row: TimedCueSource>(from rows: [Row], options: Options = Options()) -> [Cue] {
        let usable = rows.filter { !$0.cueText.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return [] }

        var cues: [Cue] = []
        var lines: [[String]] = [[]]
        var lastSpanEnd: Double = usable[0].cueStartSeconds
        var cueStart = usable[0].cueStartSeconds
        var cueSpeaker: String? = usable[0].cueSpeakerLabel
        var hasContent = false

        func lineText(_ index: Int) -> String { lines[index].joined(separator: " ") }

        func flushCue(endingAt end: Double) {
            var renderedLines: [String] = []
            for index in lines.indices where !lines[index].isEmpty {
                var text = lineText(index)
                if index == 0, let cueSpeaker, !cueSpeaker.isEmpty {
                    text = "\(cueSpeaker): \(text)"
                }
                renderedLines.append(text)
            }
            guard !renderedLines.isEmpty else { return }
            cues.append(Cue(lines: renderedLines, startSeconds: cueStart, endSeconds: end))
            lines = [[]]
            hasContent = false
        }

        for row in usable {
            let speakerChanged = hasContent && row.cueSpeakerLabel != cueSpeaker
            let candidateText = lines[lines.count - 1].isEmpty
                ? row.cueText : lineText(lines.count - 1) + " " + row.cueText
            let wouldExceedDuration = row.cueEndSeconds - cueStart > options.maxCueSeconds

            if !speakerChanged, candidateText.count <= options.maxCharsPerLine, !wouldExceedDuration {
                lines[lines.count - 1].append(row.cueText)
                lastSpanEnd = row.cueEndSeconds
                hasContent = true
                continue
            }

            if !speakerChanged, lines.count < options.maxLinesPerCue, !wouldExceedDuration {
                lines.append([row.cueText])
                lastSpanEnd = row.cueEndSeconds
                hasContent = true
                continue
            }

            flushCue(endingAt: lastSpanEnd)
            cueStart = row.cueStartSeconds
            cueSpeaker = row.cueSpeakerLabel
            lines = [[row.cueText]]
            lastSpanEnd = row.cueEndSeconds
            hasContent = true
        }
        flushCue(endingAt: lastSpanEnd)
        return cues
    }

    /// Renders `cues` as an SRT file: 1-based sequence numbers, `HH:MM:SS,mmm --> HH:MM:SS,mmm`
    /// timecodes (comma decimal separator, per the SRT spec), a blank line between cues.
    public static func srt(cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(Timecode.srt(cue.startSeconds)) --> \(Timecode.srt(cue.endSeconds))
            \(cue.lines.joined(separator: "\n"))
            """
        }.joined(separator: "\n\n") + (cues.isEmpty ? "" : "\n")
    }

    /// Renders `cues` as a WebVTT file: the `WEBVTT` header, then `HH:MM:SS.mmm --> HH:MM:SS.mmm`
    /// timecodes (dot decimal separator, per the WebVTT spec), a blank line between cues.
    public static func vtt(cues: [Cue]) -> String {
        var lines = ["WEBVTT", ""]
        for cue in cues {
            lines.append("\(Timecode.vtt(cue.startSeconds)) --> \(Timecode.vtt(cue.endSeconds))")
            lines.append(contentsOf: cue.lines)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

/// Formats a seconds offset as a subtitle timecode.
public enum Timecode {
    /// `HH:MM:SS,mmm` (SRT).
    public static func srt(_ seconds: Double) -> String { format(seconds, decimalSeparator: ",") }

    /// `HH:MM:SS.mmm` (WebVTT).
    public static func vtt(_ seconds: Double) -> String { format(seconds, decimalSeparator: ".") }

    /// `HH:MM:SS` or `MM:SS` (plain-text export): hours are omitted under an hour, matching how
    /// most transcript tools (and this app's own duration displays) present short recordings.
    public static func plain(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private static func format(_ seconds: Double, decimalSeparator: String) -> String {
        let clamped = max(0, seconds)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let secs = (totalMilliseconds % 60_000) / 1000
        let millis = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, decimalSeparator, millis)
    }
}
