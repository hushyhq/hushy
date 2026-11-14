import Foundation
import MurmurCore

/// Per-case and per-group accounting of what the cleanup model did, for `murmur-eval cleanup`:
/// every case gets an outcome line (not only failures), a table counts the outcomes, and each
/// failing case is classed by whether the model's edit never reached the output or reached it and
/// was wrong. Counts and timings come from `PipelineResult.groups`; the text is never logged.
enum CleanupOutcomeReport {
    /// Why a case did not pass, from the model's side.
    static func failureClass(_ result: Runners.CaseResult) -> String {
        guard let group = result.output.groups.last else { return "no trace" }
        if result.output.groups.count > 1, result.output.groups.contains(where: { !isUsed($0) }) {
            return "segmented: some group never applied"
        }
        switch group.outcome {
        case .used:
            return group.edited ? "applied and wrong" : "model made no edit"
        case .rejectedByGuard:
            guard result.rejectedAnswer != nil else { return "rejected, answer unavailable" }
            return result.rejectedAnswer.map(result.matches) == true
                ? "rejected, the answer was right" : "rejected, the answer was wrong too"
        case .notAsked: return "not asked"
        default: return "no answer (\(group.outcome.rawValue))"
        }
    }

    private static func isUsed(_ group: GroupTrace) -> Bool { group.outcome == .used }

    /// A short, stable name for a guard's reason, so reasons that differ only in the words they
    /// quote count together.
    static func guardName(_ code: GuardCode?) -> String { code?.rawValue ?? "unknown" }

    static func lines(_ results: [Runners.CaseResult]) -> [String] {
        let groups = results.flatMap { result in result.output.groups.map { (result, $0) } }
        guard !groups.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for (_, group) in groups {
            let key: String = switch group.outcome {
            case .used: group.edited ? "accepted, edited the draft" : "accepted, no change to the draft"
            case .rejectedByGuard: "rejected by guard: \(guardName(group.guardCode))"
            default: group.outcome.rawValue
            }
            counts[key, default: 0] += 1
        }
        var out = ["", "Model outcome per group (\(groups.count) groups, \(results.count) cases):"]
        out += counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "  \($0.value)  \($0.key)" }
        let modelMs = groups.compactMap { $0.1.modelMs.map(Double.init) }
        if !modelMs.isEmpty {
            out.append("  model call: p50 \(Int(EvalMetrics.percentile(modelMs, 0.5))) ms, p95 \(Int(EvalMetrics.percentile(modelMs, 0.95))) ms over \(modelMs.count) calls")
        }
        let failed = results.filter { !$0.passed }
        if !failed.isEmpty {
            var classes: [String: Int] = [:]
            for result in failed { classes[failureClass(result), default: 0] += 1 }
            out += ["", "Failing cases by model-side cause (\(failed.count) failing):"]
            out += classes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "  \($0.value)  \($0.key)" }
        }
        out += ["", "Per case (id, pass, outcome per group, model ms):"]
        for result in results {
            let labels = result.output.groups.map(\.label).joined(separator: " | ")
            let ms = result.output.groups.compactMap(\.modelMs).map(String.init).joined(separator: "+")
            out.append("  \(result.item.id)  \(result.passed ? "pass" : "FAIL")  \(labels)  \(ms.isEmpty ? "-" : ms + " ms")")
        }
        return out + [""]
    }
}
