import Foundation

/// Splits a long raw transcript into sentence groups that can be cleaned independently — the
/// core piece that lets a 60-180 s dictation get full rules+model cleanup within budget instead
/// of `ModelPace` skipping the model entirely because the whole draft is too long to rewrite in
/// one call (see `ModelPace.swift`). Pure, allocation-light, and unit-tested on its own: it has
/// no dependency on `SmartCleaner`, ASR, or Foundation Models, so its splitting/joining logic can
/// be verified deterministically without a model available.
///
/// A group is a run of whole sentences, targeted at `targetWords` (25-40) but allowed to grow
/// past that to keep a correction cue's sentence together with the sentence it corrects — a
/// correction like "no, I mean…" may reach back into the *previous* sentence (see
/// `ModelHints.hasCorrectionCue`, `SelfCorrection`, `Restatement`), so splitting between them
/// would hand the model half of a correction with no way to resolve it.
public enum TextSegmentation {
    /// Lower bound before a group is considered "big enough" to close, absent a forced merge.
    /// Was 25 (with a 40-word max) until 2026-09-26: after key release the unprewarmed tail
    /// group is the whole post-release model cost, and a 40-word tail took 3–4 s on a loaded
    /// Mac (`murmur-eval release-latency`). 14–26 word groups keep the tail near 1–1.5 s while
    /// still giving the model a sentence or two of context.
    public static let minGroupWords = 14
    /// Upper bound a group tries not to exceed — a group may still grow past this to keep a
    /// correction window intact, since correctness beats hitting the exact target.
    public static let maxGroupWords = 26
    /// Text at or under this many words is cleaned as one call (one model round-trip beats two
    /// small ones when nothing could have been prewarmed).
    public static let segmentThresholdWords = 40

    /// One contiguous span of the original text to be cleaned as a unit, plus its position in
    /// the sentence sequence (0-based) so a caller can tell the last group (the "tail") apart
    /// from earlier ones without re-deriving it.
    public struct Group: Sendable, Equatable {
        public let text: String
        public let index: Int
        public let isTail: Bool
        /// True when this group starts in the middle of a spoken sentence: a piece of a long
        /// run-on that `RunOnChunker` split (every piece after the first). `SmartCleaner` uses
        /// it to stitch the cleaned pieces back into flowing text (see `stitch`).
        public let continuesSentence: Bool

        public init(text: String, index: Int, isTail: Bool, continuesSentence: Bool = false) {
            self.text = text
            self.index = index
            self.isTail = isTail
            self.continuesSentence = continuesSentence
        }
    }

    /// One unit the grouping loop packs: a whole sentence, or one piece of a run-on sentence.
    private struct Unit {
        let text: String
        let words: Int
        /// A run-on piece is always a group of its own (see `groups`).
        let isRunOnPiece: Bool
        let continuesSentence: Bool
    }

    /// Splits `text` into groups of roughly `minGroupWords...maxGroupWords` words, on sentence
    /// boundaries, never separating a correction cue's sentence from the sentence before it.
    /// Text short enough to be a single group (at most `maxGroupWords` words, or with only one
    /// sentence) returns exactly one group — this is what lets the whole-text path stay a no-op
    /// for ordinary short dictations while still being exercised by the same code as long ones.
    ///
    /// A single sentence longer than `RunOnChunker.hardCapWords` (typically a long dictation
    /// that arrived with no punctuation at all) is first split into pieces by `RunOnChunker`,
    /// and each piece becomes a group of its own — never merged with a neighbour, so a piece's
    /// group text doesn't change as streaming confirms more words after it.
    public static func groups(_ text: String) -> [Group] {
        let sentences = Sentences.split(text)
        guard !sentences.isEmpty else { return [] }
        var units: [Unit] = []
        var previous: String?
        for sentence in sentences {
            let pieces = RunOnChunker.split(sentence)
            // A lowercase start after a lone full stop is the recogniser's stray full stop, not a new sentence.
            let straysFromPrevious = previous.map { isStrayFullStop(after: $0, before: sentence) } ?? false
            for (offset, piece) in pieces.enumerated() {
                units.append(Unit(text: piece, words: TextStats.wordCount(piece), isRunOnPiece: pieces.count > 1,
                                  continuesSentence: offset > 0 || straysFromPrevious))
            }
            previous = sentence
        }
        guard units.count > 1, TextStats.wordCount(text) > segmentThresholdWords else {
            return [Group(text: text, index: 0, isTail: true)]
        }

        var runs: [(units: [Unit], continuesSentence: Bool)] = []
        var current: [Unit] = []
        var currentWords = 0

        func close() {
            guard !current.isEmpty else { return }
            runs.append((current, current[0].continuesSentence))
            current = []
            currentWords = 0
        }

        var closeBeforeNext = false
        for unit in units {
            let mustMergeWithPrevious = !current.isEmpty && startsCorrectionWindow(unit.text)
            let wouldOverflow = !current.isEmpty && currentWords >= minGroupWords
                && currentWords + unit.words > maxGroupWords
            // A run-on piece stands alone (closed before and after it), unless the next unit
            // opens with a correction cue that reaches back into it.
            if (unit.isRunOnPiece || closeBeforeNext || wouldOverflow), !mustMergeWithPrevious { close() }
            current.append(unit)
            currentWords += unit.words
            closeBeforeNext = unit.isRunOnPiece
        }
        close()

        return runs.enumerated().map { offset, run in
            Group(text: joined(run.units.map(\.text)), index: offset, isTail: offset == runs.count - 1,
                  continuesSentence: run.continuesSentence)
        }
    }

    /// The recogniser ended `previous` with a lone full stop, yet `next` starts in lowercase: the stop was
    /// put in the middle of a thought. A question or exclamation mark, an ellipsis, and a lowercase "i"
    /// (the recogniser's casing of the pronoun, which says nothing about a sentence start) are not it.
    static func isStrayFullStop(after previous: String, before next: String) -> Bool {
        guard previous.hasSuffix("."), !previous.hasSuffix(".."), !previous.hasSuffix("\u{2026}") else { return false }
        guard let first = next.first(where: \.isLetter), first.isLowercase else { return false }
        let firstWord = next.split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "\u{2019}") }).first.map(String.init) ?? ""
        return firstWord != "i" && !firstWord.hasPrefix("i'")
    }

    /// Whether `text` goes on with the thought that `previous` left open: `previous` did not end a sentence, or
    /// ended it with a full stop the recogniser put in the middle of a thought. Judged on the two texts as they
    /// are now, so groups matched from an earlier (streaming) transcript take the final transcript's seam.
    static func continues(after previous: String?, text: String) -> Bool {
        guard let previous else { return false }
        let endsSentence = previous.last.map { ".!?".contains($0) } ?? false
        return !endsSentence || isStrayFullStop(after: previous, before: text)
    }

    /// Words that continue the previous clause when a run-on piece starts with them ("…too much
    /// | because when you have…"): the pieces are re-joined with a comma, not a sentence break.
    static let continuationWords: Set<String> = [
        "because", "which", "who", "whom", "whose", "that", "and", "but", "or", "nor", "when",
        "while", "where", "if", "unless", "until", "though", "although", "than", "to", "for",
        "of", "with", "as", "since", "whether",
    ]

    /// Re-joins cleaned group texts, normalising the punctuation where two groups meet — and
    /// only the punctuation (plus the case of a mid-sentence group's first letter); the words
    /// are never touched. Each group is cleaned on its own, and its cleanup ends it like a whole
    /// dictation (`TerminalPunctuation`), so a seam can carry doubled marks (",." ",," "?,") or a
    /// sentence break the speaker never made. At every seam, stray marks opening the next group
    /// are dropped and the marks ending the previous one collapse to one (placed where the first
    /// mark was, so a closing quote or parenthesis keeps its place; see `replacingTrailingMarks`).
    ///
    /// Where the next group `continuesSentence` (`RunOnChunker` cut a run-on there), that one
    /// mark is chosen from the raw text: the transcript's own comma/semicolon/colon if the cut
    /// followed one; a comma before a continuation word ("…too much, because…"); nothing at a
    /// cut the chunker made with no boundary word at all (its hard cap: "…the weight next
    /// session…"); otherwise a sentence break, since a new sentence usually starts at a
    /// discourse restart like "so", "then" or a question. A mid-sentence group's first letter is
    /// lowercased when it was lowercase in the transcript. A previous group the cleanup ended
    /// with "?"/"!", or that holds a formatted list, keeps its sentence break.
    public static func stitch(_ cleaned: [String], groups: [Group], newParagraphs: [Bool]? = nil) -> String {
        guard cleaned.count == groups.count, cleaned.count > 1 else { return join(cleaned) }
        // Keep edge newlines: TextCleaner may have produced them from an explicit spoken
        // "new line" / "new paragraph" command inside a group. Trimming them here used to
        // silently turn that structure back into prose at the group seam.
        var parts = cleaned.map(trimHorizontalWhitespace)
        for index in 1..<parts.count {
            parts[index] = droppingLeadingMarks(parts[index])
            // The nearest non-empty previous part (a group can clean down to nothing).
            guard !parts[index].isEmpty,
                  let previousIndex = (0..<index).last(where: { !parts[$0].isEmpty })
            else { continue }
            var previous = parts[previousIndex]
            // A "?" the model put at the end of a piece cut out of a run-on, when neither the words nor the
            // recogniser made it a question, is a model guess: the speaker went on in the same thought.
            if groups[index].continuesSentence, isUnearnedQuestionMark(
                cleaned: previous, raw: groups[previousIndex].text, next: groups[index].text) {
                previous = replacingTrailingMarks(of: previous, with: ".")
                parts[previousIndex] = previous
            }
            let seam = groups[index].continuesSentence && !previous.contains("\n")
                ? midSentenceMark(rawPrevious: groups[previousIndex].text, rawNext: groups[index].text,
                                  cleanedPrevious: previous, cleanedNext: parts[index])
                : nil
            if let seam {
                parts[previousIndex] = replacingTrailingMarks(of: previous, with: seam)
                if groups[index].text.first(where: \.isLetter)?.isLowercase == true {
                    parts[index] = Punctuation.lowercasingFirst(parts[index])
                }
            } else if let mark = sentenceBreakMark(cleanedPrevious: previous) {
                parts[previousIndex] = replacingTrailingMarks(of: previous, with: mark)
            }
        }
        guard let newParagraphs, newParagraphs.count == parts.count else { return join(parts) }
        var result = ""
        for (index, part) in parts.enumerated() where !part.isEmpty {
            let endsSentence = trailingMarks(result).contains(where: { ".!?".contains($0) })
            let beginsLowercase = part.first(where: \.isLetter)?.isLowercase == true
            if !result.isEmpty, newParagraphs[index], endsSentence, !beginsLowercase {
                // Breaks are inserted after every per-piece guard has run; ListStructureGuard
                // judges the model's own group text, not the app's seam between groups.
                let existing = result.reversed().prefix(while: { $0 == "\n" }).count
                result += String(repeating: "\n", count: max(0, 2 - existing))
            } else if !result.isEmpty, !result.hasSuffix("\n"), !part.hasPrefix("\n") {
                result += " "
            }
            result += part
        }
        return result
    }

    /// The cleaned piece ends with "?", the recogniser's text for it has no "?", and nothing says it is a question:
    /// its last sentence does not open a question by word order, nor does any tail of it (`QuestionPunctuation`),
    /// and it is not a short statement-shaped clause that speech can lift into a question ("You can send it") with
    /// nothing after the cut that carries the thought on. A model's "?" on such a clause stays, because the words
    /// permit a question; it goes only when the next piece opens with a word that continues the clause.
    static func isUnearnedQuestionMark(cleaned: String, raw: String, next: String = "") -> Bool {
        guard trailingMarks(cleaned).last == "?", !raw.contains("?"), !cleaned.contains("\n") else { return false }
        guard let last = Sentences.split(cleaned).last else { return false }
        // A question can sit inside the sentence ("…somebody asked, should we wait for the docs?"): any tail of it
        // that opens as a question by word order earns the mark.
        let words = last.split(separator: " ").map(String.init)
        if words.indices.contains(where: { QuestionPunctuation.opensQuestion(words[$0...].joined(separator: " ")) }) { return false }
        return !(isLiftableToQuestion(last) && !opensWithContinuation(next))
    }

    private static let liftableSubjects: Set<String> = ["you", "we", "they", "he", "she", "it", "i", "there", "that", "this"]
    private static let liftableAuxiliaries: Set<String> = [
        "can", "could", "will", "would", "should", "shall", "do", "does", "did", "are", "is", "was", "were", "have",
        "has", "had", "may", "might", "must",
    ]

    /// A short clause of the shape subject + auxiliary + rest, which a rising voice makes a question.
    private static func isLiftableToQuestion(_ sentence: String) -> Bool {
        let words = sentence.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "\u{2019}") }).map(String.init)
        guard words.count >= 3, words.count <= 8 else { return false }
        return liftableSubjects.contains(words[0]) && liftableAuxiliaries.contains(words[1])
    }

    private static func opensWithContinuation(_ next: String) -> Bool {
        guard let first = next.split(whereSeparator: { !($0.isLetter || $0 == "'") }).first else { return false }
        return continuationWords.contains(first.lowercased())
    }

    /// Punctuation that can end (or wrongly open) a cleaned group at a seam.
    static let seamMarks: Set<Character> = [".", ",", ";", ":", "!", "?"]
    /// Closing quotes/brackets that may sit among a group's trailing marks (`"ship it,".`).
    static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]

    /// The one mark a seam inside a spoken sentence gets ("" for none), or nil to keep a
    /// sentence break (see `stitch`).
    static func midSentenceMark(
        rawPrevious: String, rawNext: String, cleanedPrevious: String, cleanedNext: String
    ) -> String? {
        if let mark = trailingMarks(rawPrevious).last, ",;:".contains(mark) { return String(mark) }
        if trailingMarks(cleanedPrevious).contains(where: { "?!".contains($0) }) { return nil }
        if let firstWord = cleanedNext.split(separator: " ").first,
           continuationWords.contains(LegitDoubles.key(String(firstWord))) {
            return ","
        }
        let previousKeys = rawPrevious.split(separator: " ").map { LegitDoubles.key(String($0)) }
        let nextKeys = rawNext.split(separator: " ").map { LegitDoubles.key(String($0)) }
        let cutHadNoBoundary = RunOnChunker.boundaryScore(
            previousKeys + nextKeys, at: previousKeys.count, pieceStart: 0) == 0
        return cutHadNoBoundary ? "" : nil
    }

    /// The one mark doubled marks at a sentence-break seam collapse to, or nil when there is
    /// at most one (or an ellipsis): the strongest sentence mark ("?" over "!" over "."), else
    /// the first mark.
    static func sentenceBreakMark(cleanedPrevious: String) -> String? {
        let marks = trailingMarks(cleanedPrevious)
        guard marks.count > 1, !marks.allSatisfy({ $0 == "." }), let first = marks.first else { return nil }
        return String("?!.".first(where: marks.contains) ?? first)
    }

    /// The seam marks among `text`'s trailing run of marks and closers, in order.
    static func trailingMarks(_ text: String) -> [Character] {
        text.reversed().prefix { seamMarks.contains($0) || closers.contains($0) }.reversed()
            .filter { seamMarks.contains($0) }
    }

    /// `text` with the marks in its trailing run replaced by `mark` (closers stay in place;
    /// `mark` goes where the first mark was, or after the closers if there was none).
    static func replacingTrailingMarks(of text: String, with mark: String) -> String {
        let run = String(text.reversed().prefix { seamMarks.contains($0) || closers.contains($0) }.reversed())
        let body = text.dropLast(run.count)
        guard let firstMark = run.firstIndex(where: seamMarks.contains) else { return body + run + mark }
        let closersBefore = run[..<firstMark]
        let closersAfter = run[firstMark...].filter { !seamMarks.contains($0) }
        return body + closersBefore + mark + closersAfter
    }

    /// `text` without the stray marks a cleaned group can open with (", and then…").
    static func droppingLeadingMarks(_ text: String) -> String {
        String(text.drop { seamMarks.contains($0) || $0 == " " || $0 == "\t" || $0 == "\r" })
    }

    /// Re-joins cleaned group texts back into one draft, separating ordinary sentence groups
    /// with one space while retaining explicit line breaks at group edges. This matches the
    /// whole-text cleanup shape without flattening a spoken layout command at a seam.
    public static func join(_ cleanedGroups: [String]) -> String {
        var result = ""
        for rawGroup in cleanedGroups {
            let group = trimHorizontalWhitespace(rawGroup)
            guard !group.isEmpty else { continue }
            if !result.isEmpty, !result.hasSuffix("\n"), !group.hasPrefix("\n") {
                result.append(" ")
            }
            result.append(group)
        }
        return result
    }

    /// Trims horizontal spacing around a group without eating a structural line break.
    private static func trimHorizontalWhitespace(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
    }

    private static func joined(_ sentences: [String]) -> String {
        sentences.joined(separator: " ")
    }

    /// True when `sentence` opens with (or clearly contains, near its start) a correction cue
    /// that reaches back into the previous sentence — "No, I mean the other one.", "Actually,
    /// scratch that.", "Wait, forget the eggs." — so it must stay in the same group as whatever
    /// came right before it. Deliberately narrow to the *start* of the sentence (a correction cue
    /// appearing only deep inside a long sentence is almost always self-contained and needs no
    /// special handling), mirroring how `SelfCorrection`/`Restatement` themselves only resolve a
    /// cue that immediately follows the text it corrects.
    static func startsCorrectionWindow(_ sentence: String) -> Bool {
        let leading = sentence.trimmingCharacters(in: .whitespaces)
        let pattern = "^(?:" + ModelHints.correctionCues.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b"
        return leading.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
