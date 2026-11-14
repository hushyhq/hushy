import Foundation
import MurmurCore

/// Scores one whole dictation's output against its answer key (`LongDictationCase`) without a model and without a
/// network judge. Task 142. Every fault kind below has a plain definition and says how well it is measured.
///
/// Layout faults (what stops the text reading as if typed):
/// - `filler`: a hedge or filler phrase from the key is still there, beyond the uses that are real words. Measured
///   well, but only for the phrases the key names; a filler the key does not name is not seen.
/// - `restart`, `falseStart`, `correction`: words the speaker abandoned are still in the output. Measured well when
///   the abandoned words are all dropped or all kept; it cannot see a repair that dropped the wrong words
///   (that shows up as a missing item instead).
/// - `runOn`: an output sentence is a run-on when it is over `runOnWords` (40) words, or when it holds a place the key says
///   needs a sentence end and has none. Measured roughly: the key marks only clear places, and a long sentence
///   can be fine.
/// - `badJoin`: at a place where the old pipeline cut the text into groups, the output has a sentence end where the
///   reference has none, a sentence end after a word that cannot end a sentence, a sentence that starts in
///   lowercase, or a word said twice across the cut. Measured roughly: it needs the cut's first words to survive
///   cleanup, otherwise the place is counted as not found.
/// - `missingParagraph`: the reference has more paragraphs than the output. Counted, not placed. Measured roughly.
///
/// Meaning faults (counted on their own, never traded against the layout faults):
/// - `missingItems`: a `must_keep` item is not in the output.
/// - `negationAdded`: the output has more negation words than the reference, allowing for a correction cue ("no wait")
///   that was left in. `negationRemoved`: it has fewer, beyond what a missing negated item already counts.
///   Measured roughly: it counts words, not which statement they belong to.
/// - `numberChanged`: a number in the output that is absent from the intended reference, including an
///   abandoned spoken number. Spelled and digit forms are normalized before comparison.
enum LongDictationScorer {
    static let runOnWords = 40

    struct Faults: Codable, Equatable, Sendable {
        /// Layout and meaning faults other than the paragraph break, which the current model cannot make at all.
        var layoutBesidesParagraphs: Int { layout - missingParagraph }
        var isCleanBesidesParagraphs: Bool { layoutBesidesParagraphs == 0 && meaning == 0 }
        var filler = 0, restart = 0, falseStart = 0, correction = 0, runOn = 0, badJoin = 0, missingParagraph = 0
        var missingItems = 0, negationAdded = 0, negationRemoved = 0, numberChanged = 0
        // Not faults: what the scorer could not place, and what it noticed on the way.
        var breaksTotal = 0, breaksMissing = 0, breaksUnlocated = 0
        var seamsTotal = 0, seamsUnlocated = 0, extraParagraphs = 0, longestSentenceWords = 0

        var layout: Int { filler + restart + falseStart + correction + runOn + badJoin + missingParagraph }
        var meaning: Int { missingItems + negationAdded + negationRemoved + numberChanged }
        var isClean: Bool { layout == 0 && meaning == 0 }

        static func + (lhs: Faults, rhs: Faults) -> Faults {
            var sum = lhs
            sum.filler += rhs.filler; sum.restart += rhs.restart; sum.falseStart += rhs.falseStart; sum.correction += rhs.correction
            sum.runOn += rhs.runOn; sum.badJoin += rhs.badJoin; sum.missingParagraph += rhs.missingParagraph
            sum.missingItems += rhs.missingItems; sum.negationAdded += rhs.negationAdded
            sum.negationRemoved += rhs.negationRemoved; sum.numberChanged += rhs.numberChanged
            sum.breaksTotal += rhs.breaksTotal; sum.breaksMissing += rhs.breaksMissing; sum.breaksUnlocated += rhs.breaksUnlocated
            sum.seamsTotal += rhs.seamsTotal; sum.seamsUnlocated += rhs.seamsUnlocated; sum.extraParagraphs += rhs.extraParagraphs
            sum.longestSentenceWords = max(sum.longestSentenceWords, rhs.longestSentenceWords)
            return sum
        }
    }

    struct Result: Equatable, Sendable {
        var faults: Faults
        /// Word error rate of the output against the reference (lowercased, punctuation removed): how far the words are from typed.
        var wordErrors: Int
        var referenceWords: Int
        /// Which key entries were hit, as short labels from the key (invented text), for reading a run; never counted.
        var details: [String] = []
    }

    // MARK: Canonical words

    /// Lowercase words with contractions spelled out, digit commas removed, punctuation gone and spelled numbers as
    /// digits ("sixty percent" and "60%" are both "60"). Used for every comparison that is about words.
    static func tokens(_ text: String) -> [String] {
        var t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        t = t.replacingOccurrences(of: "(?<=\\d),(?=\\d)", with: "", options: .regularExpression)
        for (short, long) in [("won't", "will not"), ("can't", "can not"), ("cannot", "can not"), ("n't", " not"), ("'ll", " will"),
                              ("'m", " am"), ("'re", " are"), ("'ve", " have")] {
            t = t.replacingOccurrences(of: short, with: long)
        }
        func words(_ s: String) -> [String] {
            s.map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }.split(separator: " ").map { String($0) }
        }
        // Numbers are read one stretch of words at a time, so "not one, one the day" is two ones and not "11".
        var segments: [String] = []
        var current = ""
        for character in t {
            if character == "-" {
                current.append(" ")
            } else if character.isLetter || character.isNumber || character == "'" || character == " " {
                current.append(character)
            } else {
                segments.append(current)
                current = ""
            }
        }
        segments.append(current)
        // Digits already written are left alone (the normalizer would drop the zero in "0142"); spelled numbers become digits.
        let all = segments.flatMap { segment -> [String] in
            var result: [String] = []
            var run: [String] = []
            func flush() {
                if !run.isEmpty { result += words(WhisperNumberNormalizer.normalize(run.joined(separator: " "))) }
                run = []
            }
            for word in words(segment) {
                if word.first?.isNumber == true { flush(); result.append(word) } else { run.append(word) }
            }
            flush()
            return result
        }
        // Whisper's port intentionally retains its "ninth" spelling quirk. The core eval normalizer
        // already recognizes ordinal morphology, so use it only for an ordinal Whisper left as a word.
        // This keeps number scoring symmetric when either the reference or output spells the ordinal.
        let canonical = all.map { token -> String in
            guard token.first?.isNumber != true else { return token }
            let normalized = EvalTextNormalizer.normalizedWords(token)
            guard normalized.count == 1,
                  normalized[0].range(of: "^[0-9]+(?:st|nd|rd|th)$", options: .regularExpression) != nil else { return token }
            return normalized[0]
        }
        // Digits written apart are one number: "7:15", "715" and "seven fifteen", "555-0142" and "5-5-5-0-1-4-2".
        var merged: [String] = []
        for token in canonical {
            if let last = merged.last, last.allSatisfy(\.isNumber), token.allSatisfy(\.isNumber) {
                merged[merged.count - 1] = last + token
            } else {
                merged.append(token)
            }
        }
        return merged
    }

    static func occurrences(of phrase: [String], in tokens: [String]) -> Int {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return 0 }
        var count = 0
        var index = 0
        while index + phrase.count <= tokens.count {
            if Array(tokens[index..<index + phrase.count]) == phrase { count += 1; index += phrase.count } else { index += 1 }
        }
        return count
    }

    /// `a|b` is satisfied by either spelling.
    static func contains(_ item: String, in tokens: [String]) -> Bool {
        item.split(separator: "|").contains { occurrences(of: self.tokens(String($0)), in: tokens) > 0 }
    }

    private static let negations: Set<String> = ["not", "no", "never", "none", "nothing", "nobody", "without", "neither", "nor"]
    static func negationCount(_ tokens: [String]) -> Int { tokens.filter { negations.contains($0) }.count }

    /// Words that cannot end a sentence: a full stop after one is a cut in the middle of a clause.
    private static let danglers: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "by", "from", "and", "or", "but", "so", "because", "that",
        "which", "who", "if", "as", "than", "my", "our", "your", "their", "his", "her", "is", "are", "was", "were", "be", "not",
    ]

    // MARK: Raw-text helpers (these look at punctuation, so they use the output as written)

    private static func rawWords(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }

    private static func pattern(_ words: [String]) -> String {
        words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "[^a-z0-9']+")
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Sentences of `text` (a sentence ends at . ? ! before a space or the end, or at a line break), with their word counts
    /// and start offsets in UTF-16 units, the unit the regular-expression matches use.
    static func sentences(_ text: String) -> [(start: Int, words: Int)] {
        let units = Array(text.utf16)
        var result: [(Int, Int)] = []
        var start = 0
        func close(at end: Int) {
            guard end > start else { return }
            let count = rawWords(String(decoding: units[start..<end], as: UTF16.self)).count
            if count > 0 { result.append((start, count)) }
        }
        let dot: UInt16 = 46, question: UInt16 = 63, bang: UInt16 = 33, space: UInt16 = 32, newline: UInt16 = 10
        for index in units.indices {
            let unit = units[index]
            let next = index + 1 < units.count ? units[index + 1] : space
            if unit == newline {
                close(at: index)
                start = index + 1
            } else if unit == dot || unit == question || unit == bang, next == space || next == newline {
                close(at: index + 1)
                start = index + 1
            }
        }
        close(at: units.count)
        return result
    }

    /// The text between the words `before` and `after` where `after` is found in `text`, or nil when it is not found.
    /// `text` is searched as written, so the result keeps its punctuation and line breaks.
    private static func gap(in text: String, endOf tailWords: [String], startOf headWords: [String], maxBetween: Int) -> (gap: String, tailAt: Int)? {
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard let tailRegex = regex(pattern(tailWords)), !headWords.isEmpty else { return nil }
        let whole = NSRange(lower.startIndex..., in: lower)
        for tail in tailRegex.matches(in: lower, range: whole) {
            let rest = NSRange(location: tail.range.upperBound, length: whole.length - tail.range.upperBound)
            let between = "(?:[^a-z0-9']+[a-z0-9']+){0,\(maxBetween)}?"
            guard let headRegex = regex("\\G(\(between)[^a-z0-9']+)" + pattern(headWords)) else { continue }
            if let head = headRegex.firstMatch(in: lower, options: [.anchored], range: rest), let r = Range(head.range(at: 1), in: lower) {
                return (String(lower[r]), tail.range.location)
            }
        }
        return nil
    }

    private static func endsSentence(_ gap: String) -> Bool { gap.contains { ".?!\n".contains($0) } }

    // MARK: Score

    /// `groupTexts` are the groups the old pipeline cut the spoken text into (`TextSegmentation.groups`); their seams are the
    /// places `badJoin` looks at. Pass the same groups for every arm so the arms are scored on the same places.
    static func score(
        _ item: LongDictationCase, output: String, groupTexts: [String], groupContinues: [Bool] = []
    ) -> Result {
        var f = Faults()
        var details: [String] = []
        let out = tokens(output)
        let ref = tokens(item.reference)

        // Fillers and hedges.
        for filler in item.fillers {
            let left = occurrences(of: tokens(filler.p), in: out) - filler.legit
            f.filler += min(max(0, left), filler.hedge)
            if left > 0 { details.append("filler: \(filler.p)") }
        }
        // Abandoned words.
        for repair in item.repairs where repair.abandoned.split(separator: "|").contains(where: { occurrences(of: tokens(String($0)), in: out) > 0 }) {
            details.append("\(repair.kind): \(repair.abandoned)")
            switch repair.kind {
            case "restart": f.restart += 1
            case "false_start": f.falseStart += 1
            default: f.correction += 1
            }
        }
        // Run-ons: a sentence that is too long, or that holds a place the key says needs a sentence end.
        let outSentences = sentences(output)
        var flagged = Set<Int>()
        for (index, sentence) in outSentences.enumerated() where sentence.words > runOnWords { flagged.insert(index) }
        f.longestSentenceWords = outSentences.map(\.words).max() ?? 0
        for pair in item.breaks where pair.count == 2 {
            f.breaksTotal += 1
            let tail = Array(rawWords(pair[0]).suffix(2)), head = Array(rawWords(pair[1]).prefix(2))
            guard !tail.isEmpty, !head.isEmpty, let found = gap(in: output, endOf: tail, startOf: head, maxBetween: 4) else {
                f.breaksUnlocated += 1
                continue
            }
            if !endsSentence(found.gap) {
                f.breaksMissing += 1
                // Offsets in the lowercased text equal offsets in the output (lowercasing keeps the length of these texts).
                if let index = outSentences.lastIndex(where: { $0.start <= found.tailAt }) { flagged.insert(index) }
            }
        }
        f.runOn = flagged.count

        // Paragraphs.
        let referenceParagraphs = item.reference.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let outputParagraphs = output.replacingOccurrences(of: "\\n{2,}", with: "\n\n", options: .regularExpression)
            .components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        f.missingParagraph = max(0, referenceParagraphs - outputParagraphs)
        f.extraParagraphs = max(0, outputParagraphs - referenceParagraphs)

        // Seams the old pipeline would have made. The groups come in order, so each is looked for after the one before it.
        var outputCursor = 0, referenceCursor = 0
        for index in groupTexts.indices.dropFirst() {
            f.seamsTotal += 1
            let first = rawWords(groupTexts[index])
            let continues = groupContinues.indices.contains(index) ? groupContinues[index] : true
            // The group's first words, or the ones after one or two that cleanup removed ("and", "um", "so").
            var anchors: [(offset: Int, head: [String])] = []
            for offset in 0...2 {
                for width in [3, 2] where first.count >= offset + width { anchors.append((offset, Array(first[offset..<offset + width]))) }
            }
            func find(in text: String, after cursor: Int) -> (seam: Seam, offset: Int)? {
                for anchor in anchors { if let found = seam(in: text, head: anchor.head, after: cursor) { return (found, anchor.offset) } }
                return nil
            }
            guard let foundInOutput = find(in: output, after: outputCursor) else { f.seamsUnlocated += 1; continue }
            let located = foundInOutput.seam
            outputCursor = located.end
            var referenceEnds: Bool?
            if let found = find(in: item.reference, after: referenceCursor) {
                referenceEnds = endsSentence(found.seam.gap)
                referenceCursor = found.seam.end
            }
            let ended = endsSentence(located.gap)
            var bad = false
            // A sentence end where the speaker went on in the same thought.
            if ended, continues, referenceEnds == false { bad = true }
            // A sentence that stops on a word that cannot end one.
            if ended, danglers.contains(located.before) { bad = true }
            // A new sentence that starts in lowercase.
            if ended, continues, located.startsLowercase, located.gap.contains(where: { ".?!".contains($0) }) { bad = true }
            // The same word said on both sides of the cut.
            if !ended, foundInOutput.offset == 0, located.before == first.first, located.before.count > 2 { bad = true }
            if bad { f.badJoin += 1 }
        }

        // Meaning.
        var missingNegated = 0
        for item in item.mustKeep where !contains(item, in: out) {
            f.missingItems += 1
            details.append("missing: \(item)")
            if item.split(separator: "|").contains(where: { negationCount(tokens(String($0))) > 0 }) { missingNegated += 1 }
        }
        let referenceNegations = negationCount(ref)
        let outputNegations = negationCount(out)
        f.negationAdded = max(0, outputNegations - referenceNegations - f.correction)
        f.negationRemoved = max(0, referenceNegations - outputNegations - missingNegated)
        let allowed = Set(ref.filter { $0.first?.isNumber == true })
        let changedNumbers = Set(out.filter { $0.first?.isNumber == true }.filter { !allowed.contains($0) })
        f.numberChanged = changedNumbers.count
        details += changedNumbers.sorted().map { "number: \($0)" }

        let wer = editDistance(ref, out)
        return Result(faults: f, wordErrors: wer, referenceWords: ref.count, details: details)
    }

    private struct Seam {
        let gap: String
        let before: String
        let startsLowercase: Bool
        let end: Int
    }

    /// For the first words of a group: the text between the word before them and them, that word, and whether they start in
    /// lowercase, found in `text` at or after `cursor`.
    private static func seam(in text: String, head: [String], after cursor: Int) -> Seam? {
        guard let headRegex = regex("([A-Za-z0-9\u{2019}']+)([^A-Za-z0-9']+)(" + pattern(head) + ")") else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        let range = NSRange(location: min(cursor, whole.length), length: max(0, whole.length - cursor))
        guard let match = headRegex.firstMatch(in: text, range: range),
              let before = Range(match.range(at: 1), in: text), let gap = Range(match.range(at: 2), in: text),
              let headRange = Range(match.range(at: 3), in: text) else { return nil }
        return Seam(
            gap: String(text[gap]), before: String(text[before]).lowercased().replacingOccurrences(of: "\u{2019}", with: "'"),
            startsLowercase: text[headRange].first?.isLowercase ?? false, end: match.range.upperBound)
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
