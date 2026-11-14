import Foundation
import MurmurCore

/// Word-level edit-operation backtrace used for error analysis (which reference word became
/// which hypothesis word) — a level of detail `EvalMetrics.editDistance`/`WordAlignment` don't
/// provide (they report a distance and a "wrong" set, not the aligned pairs themselves). Used
/// only by `murmur-eval accent`'s top-substitution-pairs report; never used for scoring, so it
/// cannot affect any WER number the harness already reports.
enum SubstitutionAnalysis {
    /// One reference→hypothesis substitution found while aligning a single clip's transcript
    /// pair, normalized the same way `EvalMetrics.corpusWER` normalizes words (lowercased,
    /// punctuation stripped, numbers folded) so pairs group sensibly across clips.
    struct Substitution: Hashable {
        let reference: String
        let hypothesis: String
    }

    /// Standard Levenshtein dynamic-programming table with backtrace, classifying each edit as a
    /// substitution, insertion, or deletion. Ties prefer a substitution/match diagonal step over
    /// an insertion/deletion, matching the usual WER alignment convention.
    static func substitutions(reference: [String], hypothesis: [String]) -> [Substitution] {
        guard !reference.isEmpty, !hypothesis.isEmpty else { return [] }
        let rows = reference.count, cols = hypothesis.count
        var distance = Array(repeating: Array(repeating: 0, count: cols + 1), count: rows + 1)
        for i in 0...rows { distance[i][0] = i }
        for j in 0...cols { distance[0][j] = j }
        for i in 1...rows {
            for j in 1...cols {
                if reference[i - 1] == hypothesis[j - 1] {
                    distance[i][j] = distance[i - 1][j - 1]
                } else {
                    distance[i][j] = 1 + min(distance[i - 1][j - 1], distance[i - 1][j], distance[i][j - 1])
                }
            }
        }
        var pairs: [Substitution] = []
        var i = rows, j = cols
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1] {
                i -= 1; j -= 1
                continue
            }
            if i > 0, j > 0, distance[i][j] == distance[i - 1][j - 1] + 1 {
                pairs.append(Substitution(reference: reference[i - 1], hypothesis: hypothesis[j - 1]))
                i -= 1; j -= 1
            } else if i > 0, distance[i][j] == distance[i - 1][j] + 1 {
                // Deletion: reference word has no hypothesis counterpart.
                pairs.append(Substitution(reference: reference[i - 1], hypothesis: "∅"))
                i -= 1
            } else {
                // Insertion: hypothesis word has no reference counterpart.
                pairs.append(Substitution(reference: "∅", hypothesis: hypothesis[j - 1]))
                j -= 1
            }
        }
        return pairs.reversed()
    }

    /// Convenience over normalized text pairs, matching `EvalMetrics.normalizedWords`'s
    /// tokenization so the pair counts line up with the WER the harness already reports.
    static func substitutions(referenceText: String, hypothesisText: String) -> [Substitution] {
        substitutions(
            reference: EvalMetrics.normalizedWords(referenceText),
            hypothesis: EvalMetrics.normalizedWords(hypothesisText))
    }

    /// Tallies substitution pairs (excluding pure insertions/deletions, i.e. pairs involving
    /// "∅") across a corpus, sorted by frequency descending, ties broken alphabetically for
    /// determinism.
    static func topSubstitutions(_ pairs: [(reference: String, hypothesis: String)], top: Int) -> [(pair: Substitution, count: Int)] {
        var counts: [Substitution: Int] = [:]
        for pair in pairs {
            for substitution in substitutions(referenceText: pair.reference, hypothesisText: pair.hypothesis)
            where substitution.reference != "∅" && substitution.hypothesis != "∅" {
                counts[substitution, default: 0] += 1
            }
        }
        return counts
            .sorted {
                $0.value != $1.value ? $0.value > $1.value
                    : ($0.key.reference, $0.key.hypothesis) < ($1.key.reference, $1.key.hypothesis)
            }
            .prefix(top)
            .map { (pair: $0.key, count: $0.value) }
    }
}
