import Foundation

/// How a speaker is named in a transcript: "blank beats wrong" (meetings schema freeze, v28).
/// 1. The person's own name for the speaker (`note_speaker.displayName`) always wins.
/// 2. Otherwise the mic channel's owner (`micChannel`, the person recording).
/// 3. Otherwise the best `calendar` or `ax` guess at `guessFloor` or above.
/// 4. Otherwise the stored label ("Speaker 2", or "You" for the mic side).
public enum SpeakerNameRule {
    public static let guessFloor = 0.8

    public static func name(for speaker: NoteSpeaker, assignments: [SpeakerAssignment]) -> String {
        if let own = speaker.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty { return own }
        let mine = assignments.filter { $0.speakerId == speaker.id }
        if let owner = mine.first(where: { $0.source == .micChannel }) { return owner.name }
        let guess = mine
            .filter { $0.source != .micChannel && $0.confidence >= guessFloor }
            .max { ($0.confidence, $1.name) < ($1.confidence, $0.name) }
        return guess?.name ?? speaker.label
    }
}

/// A note's transcript as its turns and the names they are shown with. `rendered` is what
/// `note.transcript` caches; every reader that shows or exports a transcript goes through here, so
/// the cache and the readers cannot disagree.
public struct NoteTranscript: Sendable, Equatable {
    /// The label of mic turns that have no speaker yet (before assembly, or with speaker labels off).
    public static let micLabel = "You"
    /// The label of call-side turns that have no speaker yet; the interleaver's single-speaker fallback.
    public static let systemLabel = "Speaker 1"

    public let turns: [NoteTurn]
    /// Speaker id to the name the rule picked.
    public let names: [Int64: String]

    public init(turns: [NoteTurn], names: [Int64: String] = [:]) {
        self.turns = turns
        self.names = names
    }

    /// One shown line: consecutive turns by one voice, merged.
    public struct Line: Sendable, Equatable {
        public var label: String?
        public var text: String
        public var start: Double?
        public var end: Double?
    }

    /// Who a turn is, for grouping: its speaker, else its side of the call.
    enum Voice: Hashable { case speaker(Int64), mic, system, plain }

    static func voice(of turn: NoteTurn) -> Voice {
        if let id = turn.speakerId { return .speaker(id) }
        switch turn.stream {
        case .mic: return .mic
        case .system: return .system
        case .file, .unknown: return .plain
        }
    }

    public func label(of turn: NoteTurn) -> String? {
        switch Self.voice(of: turn) {
        case .speaker(let id): names[id] ?? Self.systemLabel
        case .mic: Self.micLabel
        case .system: Self.systemLabel
        case .plain: nil
        }
    }

    private var spoken: [NoteTurn] {
        turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// More than one voice has words: lines carry labels. One voice (a memo, a legacy note, an
    /// import, a call where only one side spoke) reads as plain text, as notes always have.
    public var hasSeveralVoices: Bool { Set(spoken.map(Self.voice(of:))).count > 1 }

    public var lines: [Line] {
        let labelled = hasSeveralVoices
        var lines: [Line] = []
        var lastVoice: Voice?
        for turn in spoken {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let voice = Self.voice(of: turn)
            if !lines.isEmpty, voice == lastVoice || !labelled {
                lines[lines.count - 1].text += " " + text
                lines[lines.count - 1].end = turn.t1 ?? lines[lines.count - 1].end
            } else {
                lines.append(Line(label: labelled ? label(of: turn) : nil, text: text, start: turn.t0, end: turn.t1))
            }
            lastVoice = voice
        }
        return lines
    }

    /// The transcript text: "Name: words" lines when several voices spoke, else the words.
    public var rendered: String {
        lines.map { line in line.label.map { "\($0): \(line.text)" } ?? line.text }.joined(separator: "\n")
    }

    /// Every turn's words with no labels, for language detection and word counts.
    public var plainText: String { spoken.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ") }

    public var isEmpty: Bool { spoken.isEmpty }

    /// Timed rows for subtitles and timestamped text: one per recognised word where a turn kept its
    /// words (echo words left out), else one per timed turn. Empty for a legacy note, which has no times.
    public func timedRows(noteId: Int64) -> [NoteSegmentWithSpeaker] {
        let labelled = hasSeveralVoices
        var rows: [NoteSegmentWithSpeaker] = []
        for turn in spoken {
            guard let t0 = turn.t0, let t1 = turn.t1 else { continue }
            let speaker = labelled ? label(of: turn).map { NoteSpeaker(id: turn.speakerId, noteId: noteId, label: $0) } : nil
            func row(_ text: String, _ start: Double, _ end: Double) {
                rows.append(NoteSegmentWithSpeaker(
                    segment: NoteSegment(noteId: noteId, speakerId: turn.speakerId, startTime: start, endTime: end,
                                         text: text, ordinal: rows.count),
                    speaker: speaker))
            }
            let words = (turn.words ?? []).filter { $0.flags & NoteTurn.Word.echo == 0 }
            if words.isEmpty {
                row(turn.text, t0, t1)
            } else {
                for word in words { row(word.w, word.start, word.end) }
            }
        }
        return rows
    }
}

/// The gate check that turns are the only transcript: the stored cache is exactly the rendered
/// turns, and it holds every word of every turn, no more and no fewer.
public enum TranscriptInvariant {
    public struct Result: Sendable, Equatable {
        public var cacheMatches: Bool
        public var transcriptWords: Int
        public var turnWords: Int
        public var wordsMatch: Bool
        public var holds: Bool { cacheMatches && wordsMatch }
    }

    public static func check(cache: String, transcript: NoteTranscript) -> Result {
        let labels = Set(transcript.lines.compactMap(\.label))
        let cacheWords = cache.split(separator: "\n").flatMap { line -> [String] in
            var text = Substring(line)
            if let colon = text.firstIndex(of: ":"), labels.contains(String(text[..<colon])) {
                text = text[text.index(after: colon)...]
            }
            return words(String(text))
        }
        let turnWords = transcript.turns.flatMap { words($0.text) }
        return Result(
            cacheMatches: cache == transcript.rendered, transcriptWords: cacheWords.count, turnWords: turnWords.count,
            wordsMatch: counted(cacheWords) == counted(turnWords))
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func counted(_ words: [String]) -> [String: Int] { words.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
}
