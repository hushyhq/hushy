import Foundation
import MurmurCore

/// Deterministic, judge-free signals for a head-to-head pair: how different the two outputs
/// are, and whether one of them dropped something the other kept (numbers, names, negations).
/// These are the "lost-content flags" of gate 12 — they do not say who is right, only where a
/// human should look, since the founder's spoken words are not in the pairs file.
enum HeadToHeadScoring {
    struct LostContent: Equatable, Sendable {
        /// Number tokens present in one output but not the other (after `normalizedWords`).
        let numbersOnlyInHushy: [String]
        let numbersOnlyInOther: [String]
        /// Capitalised mid-sentence words (a cheap proxy for names/products) only in one side.
        let namesOnlyInHushy: [String]
        let namesOnlyInOther: [String]
        /// Negation words only in one side — the one flag that can flip meaning outright.
        let negationsOnlyInHushy: [String]
        let negationsOnlyInOther: [String]

        var hasAny: Bool {
            ![numbersOnlyInHushy, numbersOnlyInOther, namesOnlyInHushy, namesOnlyInOther,
              negationsOnlyInHushy, negationsOnlyInOther].allSatisfy(\.isEmpty)
        }
        var negationMismatch: Bool { !negationsOnlyInHushy.isEmpty || !negationsOnlyInOther.isEmpty }
    }

    struct PairScore: Equatable, Sendable {
        let id: String
        /// Word-level Levenshtein distance between the two outputs.
        let editDistance: Int
        /// `editDistance` over the longer output's word count, 0…1.
        let editRate: Double
        let lostContent: LostContent
    }

    static let negationWords: Set<String> = [
        "not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "without", "cannot",
        "can't", "don't", "doesn't", "didn't", "won't", "wouldn't", "shouldn't", "couldn't", "isn't",
        "aren't", "wasn't", "weren't", "hasn't", "haven't", "hadn't", "mustn't", "needn't",
    ]

    static func score(_ pair: HeadToHeadPair) -> PairScore {
        let hushyWords = EvalMetrics.normalizedWords(pair.hushyOutput)
        let otherWords = EvalMetrics.normalizedWords(pair.otherOutput)
        let distance = EvalMetrics.editDistance(hushyWords, otherWords)
        let longest = max(hushyWords.count, otherWords.count)
        return PairScore(
            id: pair.id,
            editDistance: distance,
            editRate: longest == 0 ? 0 : Double(distance) / Double(longest),
            lostContent: lostContent(hushy: pair.hushyOutput, other: pair.otherOutput))
    }

    static func lostContent(hushy: String, other: String) -> LostContent {
        let hushyWords = EvalMetrics.normalizedWords(hushy)
        let otherWords = EvalMetrics.normalizedWords(other)
        let hushyNumbers = numbers(in: hushyWords), otherNumbers = numbers(in: otherWords)
        let hushyNegations = negations(in: hushyWords), otherNegations = negations(in: otherWords)
        let hushyNames = names(in: hushy), otherNames = names(in: other)
        return LostContent(
            numbersOnlyInHushy: difference(hushyNumbers, otherNumbers),
            numbersOnlyInOther: difference(otherNumbers, hushyNumbers),
            namesOnlyInHushy: difference(hushyNames, otherNames),
            namesOnlyInOther: difference(otherNames, hushyNames),
            negationsOnlyInHushy: difference(hushyNegations, otherNegations),
            negationsOnlyInOther: difference(otherNegations, hushyNegations))
    }

    /// Multiset difference, order-preserving: `["3", "3"]` minus `["3"]` is `["3"]`, so a number
    /// that appears twice in one output and once in the other is still flagged.
    private static func difference(_ lhs: [String], _ rhs: [String]) -> [String] {
        var remaining = Dictionary(rhs.map { ($0, 1) }, uniquingKeysWith: +)
        return lhs.filter { token in
            guard let count = remaining[token], count > 0 else { return true }
            remaining[token] = count - 1
            return false
        }
    }

    private static func numbers(in words: [String]) -> [String] {
        words.filter { $0.contains(where: \.isNumber) }
    }

    private static func negations(in words: [String]) -> [String] {
        words.filter { negationWords.contains($0) }
    }

    /// Capitalised words that do not start a sentence and are not "I": a deliberately cheap
    /// proxy for names, products and acronyms. Compared case-sensitively so "apple" vs "Apple"
    /// is not flagged as lost, only as different casing (which the edit distance already sees).
    static func names(in text: String) -> [String] {
        var result: [String] = []
        var sentenceStart = true
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "\n" })
        for rawToken in tokens {
            let token = rawToken.trimmingCharacters(in: .punctuationCharacters)
            defer {
                let last = rawToken.last
                sentenceStart = last == "." || last == "!" || last == "?" || last == ":"
            }
            guard let first = token.first, first.isUppercase, token != "I", !sentenceStart else { continue }
            guard token.contains(where: \.isLetter) else { continue }
            result.append(token)
        }
        return result
    }

    // MARK: Preference tallies

    struct Tally: Equatable, Sendable {
        var hushy = 0
        var other = 0
        var tie = 0

        var total: Int { hushy + other + tie }
        /// Hushy wins over decisive votes (ties excluded) — the gate-12 number (≥ 50%).
        var hushyPreferredOfDecisive: Double {
            let decisive = hushy + other
            return decisive == 0 ? 0 : Double(hushy) / Double(decisive)
        }
        /// Hushy wins with ties counted as half, over every vote — the more conservative view.
        var hushyPreferredWithTiesAsHalf: Double {
            total == 0 ? 0 : (Double(hushy) + Double(tie) / 2) / Double(total)
        }
        var tieRate: Double { total == 0 ? 0 : Double(tie) / Double(total) }

        mutating func add(_ preference: Preference) {
            switch preference {
            case .hushy: hushy += 1
            case .other: other += 1
            case .tie: tie += 1
            }
        }

        static func of(_ preferences: [Preference]) -> Tally {
            preferences.reduce(into: Tally()) { $0.add($1) }
        }
    }

    /// Majority across several voters for one pair: the side with strictly more votes wins,
    /// otherwise it is a tie (including 1–1–1 splits and an even split with ties).
    static func majority(_ preferences: [Preference]) -> Preference? {
        guard !preferences.isEmpty else { return nil }
        let tally = Tally.of(preferences)
        if tally.hushy > tally.other, tally.hushy > tally.tie { return .hushy }
        if tally.other > tally.hushy, tally.other > tally.tie { return .other }
        return .tie
    }
}
