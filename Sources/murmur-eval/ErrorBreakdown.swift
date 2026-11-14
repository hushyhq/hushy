import Foundation
import MurmurCore

/// Where the errors in a written-form transcript come from. Compares case- and
/// punctuation-preserving tokens of the expected text with the output, aligns them (Levenshtein),
/// and puts every edit into exactly one bucket, checked in this order:
///   1. casing — same word, different capitalisation ("monday" vs "Monday")
///   2. punctuation — same word once punctuation is ignored ("Friday?" vs "Friday"), or a
///      punctuation-only token inserted/deleted
///   3. number / ITN — either side has a digit or is a number word ("3:30" vs "three thirty")
///   4. proper noun — the expected word is a given term, or capitalised mid-sentence
///   5. disfluency — an inserted filler ("um", "uh", …) or a repeated word left in (or, against a
///      verbatim reference, a filler the output dropped)
///   6. other — a genuinely different, missing or extra word
enum ErrorBreakdown {
    enum Category: String, CaseIterable, Codable {
        case casing, punctuation, number = "number/ITN", properNoun = "proper noun", disfluency, other
    }

    enum Edit: Equatable {
        case substitute(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    static let fillers: Set<String> = ["um", "uh", "erm", "er", "ah", "hmm", "mm", "uhm", "umm"]
    static let numberWords: Set<String> = Set(WhisperNumberNormalizer.ones.keys)
        .union(WhisperNumberNormalizer.tens.keys).union(WhisperNumberNormalizer.multipliers.keys)
        .union(WhisperNumberNormalizer.onesSuffixed.keys).union(WhisperNumberNormalizer.tensSuffixed.keys)
        .union(["zero", "oh", "point", "percent", "dollars", "dollar", "cents", "half", "ninth"])

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func bare(_ token: String) -> String {
        String(token.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "’" })
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Minimum-edit alignment; ties prefer substitution, then deletion, then insertion.
    static func align(_ reference: [String], _ hypothesis: [String]) -> [Edit] {
        let n = reference.count, m = hypothesis.count
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let substitution = cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                    cost[i][j] = min(substitution, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                }
            }
        }
        var edits: [Edit] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1) {
                if reference[i - 1] != hypothesis[j - 1] { edits.append(.substitute(i - 1, j - 1)) }
                i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                edits.append(.delete(i - 1)); i -= 1
            } else {
                edits.append(.insert(j - 1)); j -= 1
            }
        }
        return edits.reversed()
    }

    /// Edits per category, plus the number of expected tokens (the denominator of formatted WER).
    static func categorize(expected: String, output: String, terms: [String] = []) -> (counts: [Category: Int], tokens: Int) {
        let reference = tokens(expected)
        let hypothesis = tokens(output)
        let termWords = Set(terms.flatMap { tokens($0) }.map { bare($0).lowercased() })
        var counts: [Category: Int] = [:]
        for edit in align(reference, hypothesis) {
            let category: Category
            switch edit {
            case .substitute(let r, let h):
                category = substitution(reference, r, hypothesis[h], termWords: termWords)
            case .delete(let r):
                // A verbatim reference that transcribes fillers ("uh") counts their omission here too.
                category = fillers.contains(bare(reference[r]).lowercased())
                    ? .disfluency : single(reference[r], proper: isProper(reference, r, termWords: termWords))
            case .insert(let h):
                let word = bare(hypothesis[h]).lowercased()
                let repeated = h > 0 && bare(hypothesis[h - 1]).lowercased() == word
                category = fillers.contains(word) || (repeated && !word.isEmpty) ? .disfluency : single(hypothesis[h], proper: false)
            }
            counts[category, default: 0] += 1
        }
        return (counts, reference.count)
    }

    private static func substitution(_ reference: [String], _ index: Int, _ output: String, termWords: Set<String>) -> Category {
        let expected = reference[index]
        if expected.lowercased() == output.lowercased() { return .casing }
        if bare(expected) == bare(output) || bare(expected).lowercased() == bare(output).lowercased() { return .punctuation }
        if isNumeric(expected) || isNumeric(output) { return .number }
        if isProper(reference, index, termWords: termWords) { return .properNoun }
        if fillers.contains(bare(output).lowercased()) { return .disfluency }
        return .other
    }

    private static func single(_ token: String, proper: Bool) -> Category {
        if bare(token).isEmpty { return .punctuation }
        if isNumeric(token) { return .number }
        return proper ? .properNoun : .other
    }

    static func isNumeric(_ token: String) -> Bool {
        token.contains(where: \.isNumber) || numberWords.contains(bare(token).lowercased())
    }

    /// A given term, or a capitalised word that does not start a sentence ("I" excluded).
    static func isProper(_ reference: [String], _ index: Int, termWords: Set<String>) -> Bool {
        let word = bare(reference[index])
        if termWords.contains(word.lowercased()) { return true }
        guard let first = word.first, first.isUppercase, !["I", "I'm", "I'll", "I've", "I'd"].contains(word) else {
            return false
        }
        guard index > 0 else { return false }
        let previous = reference[index - 1]
        return !(previous.hasSuffix(".") || previous.hasSuffix("?") || previous.hasSuffix("!") || previous.hasSuffix(":"))
    }

    // MARK: Targeted accuracies

    /// Share of term occurrences in `expected` that appear with exact spelling and case in `output`.
    static func termRecall(expected: String, output: String, terms: [String]) -> (found: Int, total: Int) {
        var found = 0, total = 0
        for term in terms {
            let wanted = occurrences(of: term, in: expected)
            total += wanted
            found += min(wanted, occurrences(of: term, in: output))
        }
        return (found, total)
    }

    private static func occurrences(of term: String, in text: String) -> Int {
        text.components(separatedBy: term).count - 1
    }

    /// Share of expected tokens containing a digit (trailing punctuation ignored) that appear in
    /// the output — "$1,250", "3:30", "18%", "415-555-0198".
    static func numberRecall(expected: String, output: String) -> (found: Int, total: Int) {
        func numeric(_ text: String) -> [String] {
            tokens(text).filter { $0.contains(where: \.isNumber) }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
        }
        var available = numeric(output)
        var found = 0
        let wanted = numeric(expected)
        for token in wanted {
            if let index = available.firstIndex(of: token) {
                available.remove(at: index)
                found += 1
            }
        }
        return (found, wanted.count)
    }

    static func fillerCount(_ text: String) -> Int {
        tokens(text).filter { fillers.contains(bare($0).lowercased()) }.count
    }
}
