import Foundation
import MurmurCore

/// Per-step regression against a reference: words that matched the reference before a step and do not
/// after it ("made worse"), and the reverse ("made better"). Uses `EvalTextNormalizer` so speech-only
/// filler removal does not count as worse when the normalized stream is unchanged.
enum MadeWorseScorer {
    static let stepOrder: [PipelineStep] = [.recognizer, .boosted, .fixers, .model, .checks]

    enum PipelineStep: String, CaseIterable, Codable, Sendable {
        case recognizer, boosted, fixers, model, checks
    }

    struct StepDelta: Codable, Sendable, Equatable {
        let worse: Int
        let better: Int
    }

    /// Counts attributed to the step whose output is `after` (transition from `before`).
    static func transition(reference: String, before: String, after: String) -> StepDelta {
        if EvalTextNormalizer.normalizedWords(before) == EvalTextNormalizer.normalizedWords(after) {
            return StepDelta(worse: 0, better: 0)
        }
        let ref = EvalTextNormalizer.normalizedWords(reference)
        guard !ref.isEmpty else { return StepDelta(worse: 0, better: 0) }
        let correctBefore = matchedReferenceIndices(reference: ref, hypothesis: EvalTextNormalizer.normalizedWords(before))
        let correctAfter = matchedReferenceIndices(reference: ref, hypothesis: EvalTextNormalizer.normalizedWords(after))
        let worse = correctBefore.subtracting(correctAfter).count
        let better = correctAfter.subtracting(correctBefore).count
        return StepDelta(worse: worse, better: better)
    }

    static func score(reference: String, steps: [PipelineStep: String]) -> [PipelineStep: StepDelta] {
        var out: [PipelineStep: StepDelta] = [:]
        for index in 1..<stepOrder.count {
            let step = stepOrder[index]
            guard let after = steps[step], let before = steps[stepOrder[index - 1]] else { continue }
            out[step] = transition(reference: reference, before: before, after: after)
        }
        return out
    }

    /// Reference indices that align to an equal normalized token in `hypothesis`.
    private static func matchedReferenceIndices(reference: [String], hypothesis: [String]) -> Set<Int> {
        let n = reference.count, m = hypothesis.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = reference[i] == hypothesis[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var matched = Set<Int>()
        var i = 0, j = 0
        while i < n, j < m {
            if reference[i] == hypothesis[j] {
                matched.insert(i)
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matched
    }
}
