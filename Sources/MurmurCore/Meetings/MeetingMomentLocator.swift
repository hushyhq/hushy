import Foundation

/// One turn of a meeting transcript with its time, as the page shows it.
public struct MeetingLine: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let start: Double
    public let end: Double
    public let speaker: String?
    public let text: String

    public init(index: Int, start: Double, end: Double, speaker: String?, text: String) {
        self.index = index
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }

    /// The diarized segments as page lines; "You" stands in for the person's own speaker.
    public static func lines(from segments: [NoteSegmentWithSpeaker]) -> [MeetingLine] {
        segments.enumerated().map { offset, entry in
            MeetingLine(
                index: offset, start: entry.segment.startTime, end: entry.segment.endTime,
                speaker: entry.speaker?.displayLabel, text: entry.segment.text)
        }
    }
}

/// A point in the recording a row can jump to.
public struct MeetingMoment: Sendable, Equatable, Hashable {
    public let seconds: Double
    /// The transcript line it falls in, when the meeting has timed lines.
    public let lineIndex: Int?
    public let speaker: String?

    public init(seconds: Double, lineIndex: Int?, speaker: String?) {
        self.seconds = seconds
        self.lineIndex = lineIndex
        self.speaker = speaker
    }

    /// "4:05", or "1:02:10" past an hour.
    public var label: String { Self.clock(seconds) }

    public static func clock(_ seconds: Double) -> String {
        let total = seconds > 0 ? Int(exactly: seconds.rounded(.down)) ?? 0 : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Finds where in the transcript a written row was said, so "Priya sends the deck by Friday" opens
/// the turn where Priya said it. Bag-of-words overlap of content words over each line and each
/// pair of adjacent lines; linear in the transcript (one pass, a set lookup per word). A row that
/// matches nothing well enough gets no moment rather than a wrong one.
public enum MeetingMomentLocator {
    /// Share of the row's content words that must appear in the chosen line(s).
    static let minimumCoverage = 0.5

    public static func moment(for text: String, in lines: [MeetingLine], hintSeconds: Double? = nil) -> MeetingMoment? {
        if let hintSeconds {
            let line = lines.last { $0.start <= hintSeconds + 0.5 }
            return MeetingMoment(seconds: hintSeconds, lineIndex: line?.index, speaker: line?.speaker)
        }
        let wanted = contentWords(text)
        guard !wanted.isEmpty, !lines.isEmpty else { return nil }
        let needed = wanted.count <= 2 ? wanted.count : max(2, Int((Double(wanted.count) * minimumCoverage).rounded(.up)))
        let lineWords = lines.map { contentWords($0.text) }
        var best: (score: Int, index: Int)?
        for index in lines.indices {
            var words = lineWords[index]
            let single = wanted.intersection(words).count
            if index + 1 < lines.count { words.formUnion(lineWords[index + 1]) }
            // A pair only wins when it adds a word the line alone lacked.
            let score = max(single, wanted.intersection(words).count - 1)
            if score >= needed, score > (best?.score ?? 0) { best = (score, index) }
        }
        guard let best else { return nil }
        let line = lines[best.index]
        return MeetingMoment(seconds: line.start, lineIndex: line.index, speaker: line.speaker)
    }

    /// The words that carry meaning, numbers and periods written one way (`MeetingWords`).
    static func contentWords(_ text: String) -> Set<String> { MeetingWords.content(text) }

    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "your", "are", "was", "were", "will", "have", "has",
        "had", "but", "not", "they", "them", "their", "our", "out", "about", "from", "into", "can", "could",
        "would", "should", "just", "like", "yeah", "okay", "really", "then", "than", "there", "here", "what",
        "when", "which", "who", "how", "all", "any", "some", "get", "got", "going", "gonna", "let", "lets",
        "also", "very", "one", "two", "need", "needs", "make", "sure", "think", "know", "want", "decided", "agreed",
    ]
}
