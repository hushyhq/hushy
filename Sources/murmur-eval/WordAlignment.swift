import Foundation

/// LCS-based word alignment for scoring which hypothesis words are wrong against a reference —
/// used only by `ConfidenceCalibration`, which needs to label individual hypothesis words
/// correct/wrong rather than just a corpus-level WER number. Independent of `BoostGuard`'s
/// alignment (internal to `MurmurCore`, not visible from this module) but the same
/// longest-common-subsequence technique.
enum WordAlignment {
    private enum Region {
        case same(Range<Int>)
        case changed(old: Range<Int>, new: Range<Int>)
    }

    /// Indices into `hypothesis` that are substitutions or insertions relative to `reference`
    /// (i.e. not part of a matching run) — the "wrong" words for calibration purposes.
    static func wrongHypothesisIndices(reference: [String], hypothesis: [String]) -> Set<Int> {
        var wrong = Set<Int>()
        for region in align(reference, hypothesis) {
            if case .changed(_, let newRange) = region { wrong.formUnion(newRange) }
        }
        return wrong
    }

    private static func align(_ a: [String], _ b: [String]) -> [Region] {
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var regions: [Region] = []
        var i = 0, j = 0, oldStart = 0, newStart = 0
        func flushChange() {
            if oldStart < i || newStart < j { regions.append(.changed(old: oldStart..<i, new: newStart..<j)) }
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                flushChange()
                let start = j
                while i < a.count, j < b.count, a[i] == b[j] { i += 1; j += 1 }
                regions.append(.same(start..<j))
                oldStart = i; newStart = j
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                j += 1
            } else {
                i += 1
            }
        }
        flushChange()
        return regions
    }
}
