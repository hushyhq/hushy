#if DEBUG
import Foundation
import MurmurCore

enum MockMicScoreMode: String, Codable, Equatable {
    /// Whole reference against the whole hypothesis (the synthetic clips, which say every word).
    case full
    /// The hypothesis is matched to the best contiguous stretch of the reference, with the
    /// reference words before and after it free (an external clip that is a cut of a longer meeting).
    case bestStretch
}

struct MockMicScore: Equatable {
    let mode: MockMicScoreMode
    let wer: Double
    let referenceWords: Int
    let hypothesisWords: Int
    let errors: Int
}

enum MockMicScoring {
    static func score(reference: String, hypothesis: String, mode: MockMicScoreMode) -> MockMicScore {
        let ref = EvalMetrics.normalizedWords(reference)
        let hyp = EvalMetrics.normalizedWords(hypothesis)
        switch mode {
        case .full:
            let errors = EvalMetrics.editDistance(ref, hyp)
            return make(mode, ref.count, hyp.count, errors)
        case .bestStretch:
            let best = bestStretch(ref, hyp)
            return make(mode, best.length, hyp.count, best.errors)
        }
    }

    private static func make(_ mode: MockMicScoreMode, _ refCount: Int, _ hypCount: Int, _ errors: Int) -> MockMicScore {
        let wer = refCount == 0 ? (hypCount == 0 ? 0 : 1) : Double(errors) / Double(refCount)
        return MockMicScore(mode: mode, wer: wer, referenceWords: refCount, hypothesisWords: hypCount, errors: errors)
    }

    /// Semi-global alignment: the whole hypothesis against a contiguous stretch of the reference that
    /// starts and ends anywhere. Returns the edit cost and the length of the reference stretch used
    /// (ties go to the earliest end, then the shortest stretch).
    private static func bestStretch(_ ref: [String], _ hyp: [String]) -> (errors: Int, length: Int) {
        if hyp.isEmpty || ref.isEmpty { return (max(hyp.count, ref.isEmpty ? 0 : ref.count), ref.count) }
        let columns = ref.count
        var previous = [Int](repeating: 0, count: columns + 1)   // row 0: free start
        var previousStart = Array(0...columns)
        for i in 1...hyp.count {
            var current = [Int](repeating: 0, count: columns + 1)
            var start = [Int](repeating: 0, count: columns + 1)
            current[0] = i
            start[0] = 0
            for j in 1...columns {
                let cost = hyp[i - 1] == ref[j - 1] ? 0 : 1
                let diagonal = previous[j - 1] + cost
                let deletion = previous[j] + 1          // a hypothesis word with no reference word
                let insertion = current[j - 1] + 1      // a reference word that was not heard
                if diagonal <= deletion && diagonal <= insertion {
                    current[j] = diagonal; start[j] = previousStart[j - 1]
                } else if deletion <= insertion {
                    current[j] = deletion; start[j] = previousStart[j]
                } else {
                    current[j] = insertion; start[j] = start[j - 1]
                }
            }
            previous = current
            previousStart = start
        }
        var bestEnd = 0
        for j in 1...columns where previous[j] < previous[bestEnd] { bestEnd = j }
        return (previous[bestEnd], max(bestEnd - previousStart[bestEnd], 0))
    }
}
#endif
