import Foundation

/// Splits a note transcript into overlapping pieces for a model with a small context window
/// (`NoteSummarizer`'s map step).
///
/// Understands the speaker-turn format notes are exported and rendered in — one turn per line,
/// "Label: words" (`Speaker 2: …`, `You: …`, or a renamed speaker's name) — and plain text. Cuts
/// prefer a turn boundary, then a sentence end, within the last fifth of a piece, so an action
/// item and its "yes, I'll do it" rarely land in different pieces; each piece after the first
/// starts `overlapWords` back so anything straddling a cut is seen whole at least once. A piece
/// that starts mid-turn repeats that turn's label, so the model always knows who is speaking.
public enum TranscriptChunker {
    struct Word {
        let text: Substring
        /// Index into the turn list, so a piece can be re-rendered as turns.
        let turn: Int
    }

    struct Turn {
        let speaker: String?
        let range: Range<Int>
    }

    /// "Speaker 2", "You", "Priya", "Dr. Patel": up to four words, capitalized first, then a colon.
    private static let labelPattern = #"^([A-Z][\w.'\-]*(?: [\w.'\-]+){0,3}):\s+(.*)$"#

    /// A transcript's turns and the flat word list they index into.
    static func parse(_ transcript: String) -> (turns: [Turn], words: [Word]) {
        var turns: [Turn] = []
        var words: [Word] = []
        for line in transcript.split(whereSeparator: \.isNewline) {
            let (speaker, body) = split(String(line))
            let start = words.count
            words += body.split(whereSeparator: \.isWhitespace).map { Word(text: $0, turn: turns.count) }
            guard words.count > start else { continue }
            turns.append(Turn(speaker: speaker, range: start..<words.count))
        }
        return (turns, words)
    }

    /// "Speaker 2: words" → ("Speaker 2", "words"); an unlabelled line → (nil, line).
    static func split(_ line: String) -> (speaker: String?, body: Substring) {
        guard let match = Regex.firstMatch(line, labelPattern),
              let speaker = match.string(at: 1, in: line), let range = Range(match.range(at: 2), in: line)
        else { return (nil, line[...]) }
        return (speaker, line[range])
    }

    /// Pieces of at most `maxWords` words (plus a repeated label), overlapping by about
    /// `overlapWords`. A transcript that fits is returned whole, as written.
    public static func chunks(_ transcript: String, maxWords: Int, overlapWords: Int = 100) -> [String] {
        let (turns, words) = parse(transcript)
        guard words.count > maxWords, maxWords > 0 else { return [transcript] }
        let overlap = min(max(0, overlapWords), maxWords / 3)
        var pieces: [String] = []
        var start = 0
        while start < words.count {
            var end = min(start + maxWords, words.count)
            if end < words.count { end = cut(near: end, after: start + maxWords * 4 / 5, words: words) }
            pieces.append(render(words[start..<end], turns: turns))
            guard end < words.count else { break }
            start = max(start + 1, restart(before: end, overlap: overlap, words: words))
        }
        return pieces
    }

    /// The best cut at or before `limit` and after `floor`: a turn start, else just after a
    /// sentence end, else `limit` itself.
    static func cut(near limit: Int, after floor: Int, words: [Word]) -> Int {
        let window = stride(from: limit, to: max(floor, 1), by: -1)
        if let turnStart = window.first(where: { words[$0].turn != words[$0 - 1].turn }) { return turnStart }
        if let sentenceEnd = window.first(where: { endsSentence(words[$0 - 1].text) }) { return sentenceEnd }
        return limit
    }

    /// Where the next piece starts: `overlap` words before `end`, moved forward to the start of
    /// a turn or sentence when one begins within that overlap.
    static func restart(before end: Int, overlap: Int, words: [Word]) -> Int {
        let start = end - overlap
        guard overlap > 0, start > 0 else { return end }
        for index in start..<end where words[index].turn != words[index - 1].turn || endsSentence(words[index - 1].text) {
            return index
        }
        return start
    }

    static func endsSentence(_ word: Substring) -> Bool {
        guard let last = word.last(where: { !"\"')]”’".contains($0) }) else { return false }
        return ".?!".contains(last)
    }

    /// Words back to turn lines ("Label: words"), or plain text when the transcript has no labels.
    static func render(_ slice: ArraySlice<Word>, turns: [Turn]) -> String {
        var lines: [String] = []
        var index = slice.startIndex
        while index < slice.endIndex {
            let turn = slice[index].turn
            var end = index
            while end < slice.endIndex, slice[end].turn == turn { end += 1 }
            let text = slice[index..<end].map(\.text).joined(separator: " ")
            lines.append(turns[turn].speaker.map { "\($0): \(text)" } ?? text)
            index = end
        }
        return lines.joined(separator: "\n")
    }
}
