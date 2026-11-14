import Foundation

/// Scoring helpers shared by the eval harness and tests.
public enum EvalMetrics {
    /// Lowercased words with punctuation and list markers removed; numbers spelled
    /// as digits and words ("nine" / "9") compare equal.
    ///
    /// This is the product/golden-set scoring path (`layoutMatches`, `formatMatches`,
    /// `wordsMatch`, and the default `wer`/`corpusWER`). It is intentionally unchanged —
    /// golden-set scores must stay comparable across runs. For ASR corpus WER reporting,
    /// prefer `EvalTextNormalizer.wer`/`corpusWER`, a separate, more thorough English
    /// text normalizer (see `EvalTextNormalizer`), applied identically to every engine.
    public static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
            .map { numberWords[$0] ?? $0 }
    }

    /// Word-level Levenshtein distance between reference and hypothesis.
    public static func editDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }
        var previous = Array(0...hypothesis.count)
        var current = [Int](repeating: 0, count: hypothesis.count + 1)
        for i in 1...reference.count {
            current[0] = i
            for j in 1...hypothesis.count {
                let cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[hypothesis.count]
    }

    /// Word error rate of one pair (use `corpusWER` to aggregate).
    public static func wer(reference: String, hypothesis: String) -> Double {
        let ref = normalizedWords(reference)
        guard !ref.isEmpty else { return normalizedWords(hypothesis).isEmpty ? 0 : 1 }
        return Double(editDistance(ref, normalizedWords(hypothesis))) / Double(ref.count)
    }

    /// Total edits over total reference words, the standard way to report WER.
    public static func corpusWER(_ pairs: [(reference: String, hypothesis: String)]) -> Double {
        var edits = 0
        var words = 0
        for pair in pairs {
            let ref = normalizedWords(pair.reference)
            edits += editDistance(ref, normalizedWords(pair.hypothesis))
            words += ref.count
        }
        return words == 0 ? 0 : Double(edits) / Double(words)
    }

    /// Same words in the same order, ignoring punctuation and case.
    public static func wordsMatch(_ expected: String, _ actual: String) -> Bool {
        normalizedWords(expected) == normalizedWords(actual)
    }

    /// Whether both texts agree on being a list (bulleted or numbered lines).
    public static func formatMatches(_ expected: String, _ actual: String) -> Bool {
        listItemCount(expected) == listItemCount(actual)
    }

    /// Product scoring: preserve line/paragraph boundaries, list kind, and words per line.
    /// Punctuation and casing remain tolerant; this is not a typography exact-match metric.
    public static func layoutMatches(_ expected: String, _ actual: String) -> Bool {
        func lines(_ text: String) -> [String] {
            text.replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func kind(_ line: String) -> Int {
            if line.range(of: "^[-•*]\\s+", options: .regularExpression) != nil { return 1 }
            if line.range(of: "^\\d+[.)]\\s+", options: .regularExpression) != nil { return 2 }
            return 0
        }
        let lhs = lines(expected), rhs = lines(actual)
        return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            kind($0) == kind($1) && normalizedWords($0) == normalizedWords($1)
        }
    }

    public static func listItemCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter {
            $0.range(of: "^\\s*(?:[-•*]|\\d+[.)])\\s+", options: .regularExpression) != nil
        }.count
    }

    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
        return sorted[index]
    }

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "fifteen": "15", "twenty": "20", "thirty": "30", "sixty": "60", "hundred": "100",
        "okay": "ok", "o.k": "ok",
    ]
}
