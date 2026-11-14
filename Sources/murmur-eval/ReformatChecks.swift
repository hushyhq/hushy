import Foundation
import MurmurCore

/// Case format and deterministic scoring for the held-out reformat eval (`murmur-eval reformat`,
/// `Evals/reformat-golden.json`). Pure functions only — no model, no I/O — so the scoring rules
/// are unit-tested (`Tests/MurmurEvalTests/ReformatChecksTests.swift`) independently of any
/// model output.
///
/// HELD OUT: this golden set is the referee for cleanup-pipeline changes. Never tune prompts,
/// rules or thresholds against individual cases here — see `.claude/DECISIONS.md`.
enum ReformatChecks {
    // MARK: Case format

    struct Case: Decodable {
        let id: String
        let category: String
        let lengthBucket: String
        let negative: Bool?
        let mustEqualInput: Bool?
        let input: String
        let note: String?
        let levels: [String: Expectation]

        var isNegative: Bool { negative ?? false }
    }

    struct Expectation: Decodable {
        let reference: String
        let mustContain: [String]?
        let mustNotContain: [String]?
        /// Phrase -> the most times it may appear (e.g. `{"actually": 1}` for "keep one, drop
        /// the second"). `0` is equivalent to listing the phrase in `mustNotContain`.
        let maxOccurrences: [String: Int]?
        let minWords: Int?
        let maxWords: Int?
        let minQuestionMarks: Int?
        let minSentences: Int?
    }

    static let levelNames = ["clean", "polished"]

    /// Word-count buckets: short < 10 words, medium 10–30, long > 30 (raw whitespace split of
    /// the input, so the bucket is a property of the case, not of any normalisation).
    static func lengthBucket(for input: String) -> String {
        let count = input.split(whereSeparator: \.isWhitespace).count
        if count < 10 { return "short" }
        return count <= 30 ? "medium" : "long"
    }

    /// Structural problems with a golden set (empty, duplicate IDs, missing levels, a declared
    /// bucket that doesn't match the input, a negative without `mustEqualInput`). Empty = valid.
    static func validate(_ cases: [Case]) -> [String] {
        var problems: [String] = []
        if cases.isEmpty { problems.append("golden set is empty") }
        var seen = Set<String>()
        for item in cases {
            if !seen.insert(item.id).inserted { problems.append("duplicate id \(item.id)") }
            for level in levelNames where item.levels[level] == nil {
                problems.append("\(item.id): missing '\(level)' expectations")
            }
            let bucket = lengthBucket(for: item.input)
            if bucket != item.lengthBucket {
                problems.append("\(item.id): lengthBucket '\(item.lengthBucket)' but input is \(bucket)")
            }
            if item.isNegative && item.mustEqualInput != true {
                problems.append("\(item.id): negative case must set mustEqualInput")
            }
        }
        return problems
    }

    // MARK: Normalisation

    private static let extraNumberWords: [String: String] = [
        "thirteen": "13", "fourteen": "14", "sixteen": "16", "seventeen": "17", "eighteen": "18",
        "nineteen": "19", "forty": "40", "fifty": "50", "seventy": "70", "eighty": "80", "ninety": "90",
    ]

    /// Lowercased words with punctuation removed (hyphens split words, apostrophes kept), thousands
    /// separators dropped ("45,000" -> "45000"), and common number words mapped to digits. Built on
    /// `EvalMetrics.normalizedWords` so it agrees with the rest of the harness.
    static func words(_ text: String) -> [String] {
        let withoutSeparators = text.replacingOccurrences(
            of: "(?<=\\d),(?=\\d{3}\\b)", with: "", options: .regularExpression)
        return EvalMetrics.normalizedWords(withoutSeparators).map { extraNumberWords[$0] ?? $0 }
    }

    /// Whitespace- and punctuation-insensitive form used for `mustEqualInput`: "3pm" and "3 PM."
    /// compare equal; "had had" and "had" do not.
    static func compact(_ text: String) -> String { words(text).joined() }

    static func unchanged(input: String, output: String) -> Bool { compact(input) == compact(output) }

    /// Number of non-overlapping, word-aligned occurrences of `phrase` in `text`.
    static func occurrences(of phrase: String, in text: String) -> Int {
        occurrences(of: words(phrase), in: words(text))
    }

    static func occurrences(of needle: [String], in haystack: [String]) -> Int {
        guard !needle.isEmpty, needle.count <= haystack.count else { return 0 }
        var count = 0
        var index = 0
        while index + needle.count <= haystack.count {
            if Array(haystack[index..<(index + needle.count)]) == needle {
                count += 1
                index += needle.count
            } else {
                index += 1
            }
        }
        return count
    }

    static func contains(_ phrase: String, in text: String) -> Bool { occurrences(of: phrase, in: text) > 0 }

    // MARK: Negation

    private static let negationWords: Set<String> = [
        "not", "never", "cannot", "nothing", "nobody", "none", "neither", "nor", "nowhere",
    ]

    /// Explicit negators ("not", "never", any "-n't" contraction, …). Bare "no" is deliberately
    /// excluded: in dictation it is far more often a discourse marker or a correction cue
    /// ("yeah no", "at 4, no, 5") than a negation, and counting it would flag correct cleanup.
    static func negationCount(_ text: String) -> Int {
        words(text).filter { negationWords.contains($0) || $0.hasSuffix("n't") }.count
    }

    // MARK: Punctuation

    static func questionMarkCount(_ text: String) -> Int { text.filter { $0 == "?" }.count }

    /// Sentence terminators followed by whitespace or end of text ("2.5" is not a sentence end).
    static func sentenceCount(_ text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "[.!?]+(?=\\s|$)") else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // MARK: Scoring

    struct Outcome: Sendable {
        var missing: [String] = []
        var leaked: [String] = []
        var disfluencyTargets = 0
        var wordCount = 0
        var wordBoundsViolation: String?
        var negationLost = false
        var negationAdded = false
        /// Only meaningful for `mustEqualInput` cases.
        var unchanged = true
        var mustEqualInput = false
        var questionShortfall = false
        var sentenceShortfall = false
        /// 1 − word edit distance / reference length, clamped to 0…1.
        var similarity = 0.0

        var disfluencyRemoved: Int { disfluencyTargets - leaked.count }
        var contentPreserved: Bool { missing.isEmpty && !negationLost && !negationAdded }

        var failureReasons: [String] {
            var reasons: [String] = []
            if mustEqualInput && !unchanged { reasons.append("changed a must-stay-unchanged input") }
            if !missing.isEmpty { reasons.append("lost \(missing)") }
            if !leaked.isEmpty { reasons.append("kept disfluency \(leaked)") }
            if negationLost { reasons.append("negation lost") }
            if negationAdded { reasons.append("negation added") }
            if let wordBoundsViolation { reasons.append(wordBoundsViolation) }
            if questionShortfall { reasons.append("missing question mark") }
            if sentenceShortfall { reasons.append("run-on not split into sentences") }
            return reasons
        }

        var passed: Bool { failureReasons.isEmpty }
    }

    static func evaluate(_ item: Case, expectation: Expectation, output: String) -> Outcome {
        var outcome = Outcome()
        let outputWords = words(output)
        outcome.wordCount = outputWords.count
        outcome.missing = (expectation.mustContain ?? []).filter { !contains($0, in: output) }

        let banned = expectation.mustNotContain ?? []
        var leaked = banned.filter { contains($0, in: output) }
        for (phrase, limit) in (expectation.maxOccurrences ?? [:]).sorted(by: { $0.key < $1.key }) {
            let found = occurrences(of: phrase, in: output)
            if found > limit { leaked.append("\(phrase)×\(found)") }
        }
        outcome.leaked = leaked
        outcome.disfluencyTargets = banned.count + (expectation.maxOccurrences?.count ?? 0)

        if let minimum = expectation.minWords, outputWords.count < minimum {
            outcome.wordBoundsViolation = "too short (\(outputWords.count) < \(minimum) words)"
        } else if let maximum = expectation.maxWords, outputWords.count > maximum {
            outcome.wordBoundsViolation = "too long (\(outputWords.count) > \(maximum) words)"
        }

        let outputNegations = negationCount(output)
        outcome.negationLost = outputNegations < negationCount(expectation.reference)
        outcome.negationAdded = outputNegations > negationCount(item.input)

        outcome.mustEqualInput = item.mustEqualInput ?? false
        outcome.unchanged = unchanged(input: item.input, output: output)
        outcome.questionShortfall = questionMarkCount(output) < (expectation.minQuestionMarks ?? 0)
        outcome.sentenceShortfall = sentenceCount(output) < (expectation.minSentences ?? 0)
        outcome.similarity = similarity(reference: expectation.reference, output: output)
        return outcome
    }

    static func similarity(reference: String, output: String) -> Double {
        let ref = words(reference)
        guard !ref.isEmpty else { return words(output).isEmpty ? 1 : 0 }
        let distance = EvalMetrics.editDistance(ref, words(output))
        return max(0, 1 - Double(distance) / Double(ref.count))
    }

    // MARK: Aggregation helpers

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
