import Foundation
import MurmurCore

/// Console/markdown and JSON reporting for `murmur-eval reformat` (see `ReformatRunner`).
enum ReformatReport {
    typealias Run = ReformatRunner.LevelRun
    typealias CaseRun = ReformatRunner.CaseRun

    struct Aggregate {
        let total: Int
        let passed: Int
        let contentPreserved: Int
        let disfluencyRemoved: Int
        let disfluencyTargets: Int
        let modelUsed: Int
        let timeouts: Int
        let meanSimilarity: Double
        let p50: Double
        let p95: Double

        init(_ cases: [CaseRun]) {
            total = cases.count
            passed = cases.filter(\.outcome.passed).count
            contentPreserved = cases.filter(\.outcome.contentPreserved).count
            let positives = cases.filter { !$0.negative }
            disfluencyRemoved = positives.reduce(0) { $0 + $1.outcome.disfluencyRemoved }
            disfluencyTargets = positives.reduce(0) { $0 + $1.outcome.disfluencyTargets }
            modelUsed = cases.filter(\.usedModel).count
            timeouts = cases.filter { $0.rejection?.hasPrefix("timeout") ?? false }.count
            meanSimilarity = cases.isEmpty ? 0 : cases.reduce(0) { $0 + $1.outcome.similarity } / Double(cases.count)
            let latencies = cases.map(\.latencyMs)
            p50 = ReformatChecks.percentile(latencies, 0.5)
            p95 = ReformatChecks.percentile(latencies, 0.95)
        }
    }

    static func print(_ run: Run) {
        let all = Aggregate(run.cases)
        let negatives = run.cases.filter(\.negative)
        let positives = run.cases.filter { !$0.negative }
        let unchanged = negatives.filter(\.outcome.unchanged).count
        let negationLost = run.cases.filter(\.outcome.negationLost).count
        let negationAdded = run.cases.filter(\.outcome.negationAdded).count
        let mustContainLost = run.cases.filter { !$0.outcome.missing.isEmpty }.count
        let rejections = Dictionary(grouping: run.cases.compactMap(\.rejection), by: { reasonKey($0) })
            .map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")

        var lines = ["### Reformat (held-out) · \(run.level.rawValue) (\(run.strategy.rawValue)) · \(run.cases.count) cases"]
        lines.append("- Deterministic pass: **\(all.passed)/\(all.total) (\(pct(ReformatRunner.ratio(all.passed, all.total))))** — positives \(positives.filter(\.outcome.passed).count)/\(positives.count), negatives \(negatives.filter(\.outcome.passed).count)/\(negatives.count)")
        lines.append("- Negative faithfulness (unchanged): \(unchanged)/\(negatives.count) (\(pct(ReformatRunner.ratio(unchanged, negatives.count))))")
        lines.append("- Content preservation: \(all.contentPreserved)/\(all.total) (\(pct(ReformatRunner.ratio(all.contentPreserved, all.total)))) — mustContain lost in \(mustContainLost), negation lost \(negationLost), negation added \(negationAdded)")
        lines.append("- Disfluency removal: \(all.disfluencyRemoved)/\(all.disfluencyTargets) (\(pct(ReformatRunner.ratio(all.disfluencyRemoved, all.disfluencyTargets))))")
        lines.append("- Reference similarity (1 − WER vs reference, mean): \(String(format: "%.3f", all.meanSimilarity))")
        lines.append("- Model used (last segment): \(all.modelUsed)/\(all.total) (\(pct(ReformatRunner.ratio(all.modelUsed, all.total)))) · model available: \(SmartCleaner.isModelAvailable) · rejections: \(rejections.isEmpty ? "none" : rejections)")
        lines.append("- Latency p50/p95: all \(ms(all.p50))/\(ms(all.p95))" + bucketLatencies(run.cases))
        lines.append("")
        lines.append("| Category | Pass | Content kept | Disfluency removed | Similarity |")
        lines.append("|---|---:|---:|---:|---:|")
        for (key, items) in Dictionary(grouping: run.cases, by: \.category).sorted(by: { $0.key < $1.key }) {
            let agg = Aggregate(items)
            lines.append("| \(key) | \(agg.passed)/\(agg.total) | \(agg.contentPreserved)/\(agg.total) | \(agg.disfluencyTargets == 0 ? "—" : "\(agg.disfluencyRemoved)/\(agg.disfluencyTargets)") | \(String(format: "%.2f", agg.meanSimilarity)) |")
        }
        lines.append("")
        lines.append("| Length | Pass | Model used | p50 | p95 |")
        lines.append("|---|---:|---:|---:|---:|")
        for key in ["short", "medium", "long"] {
            let agg = Aggregate(run.cases.filter { $0.lengthBucket == key })
            guard agg.total > 0 else { continue }
            lines.append("| \(key) | \(agg.passed)/\(agg.total) | \(agg.modelUsed)/\(agg.total) | \(ms(agg.p50)) | \(ms(agg.p95)) |")
        }

        let failures = run.cases.filter { !$0.outcome.passed }.map { failure in
            """
              ✘ \(failure.id) [\(failure.category)/\(failure.lengthBucket)] \(failure.outcome.failureReasons.joined(separator: "; "))\(failure.rejection.map { " (model: \($0))" } ?? "")
                  input:     \(failure.input)
                  output:    \(failure.output.replacingOccurrences(of: "\n", with: " ⏎ "))
                  reference: \(failure.reference)
            """
        }
        Runners.emit(lines.joined(separator: "\n"), details: failures.isEmpty ? [] : ["\nFailures (\(run.level.rawValue)):"] + failures)
    }

    private static func bucketLatencies(_ cases: [CaseRun]) -> String {
        ["short", "medium", "long"].compactMap { key -> String? in
            let latencies = cases.filter { $0.lengthBucket == key }.map(\.latencyMs)
            guard !latencies.isEmpty else { return nil }
            return " · \(key) \(ms(ReformatChecks.percentile(latencies, 0.5)))/\(ms(ReformatChecks.percentile(latencies, 0.95)))"
        }.joined()
    }

    /// Groups rejection reasons by their stable prefix ("timeout or model error" and friends
    /// carry no variable detail, but guard rejections can) so the summary stays one line.
    private static func reasonKey(_ reason: String) -> String {
        String(reason.split(separator: ":").first ?? Substring(reason)).trimmingCharacters(in: .whitespaces)
    }

    static func write(
        _ runs: [Run], judged: [String: [String: ReformatJudge.Verdict]], golden: URL, elapsedSeconds: Double, to path: String
    ) throws {
        let levels: [[String: Any]] = runs.map { run in
            let agg = Aggregate(run.cases)
            let verdicts = judged[run.level.rawValue] ?? [:]
            return [
                "level": run.level.rawValue, "strategy": run.strategy.rawValue,
                "total": agg.total, "passed": agg.passed, "contentPreserved": agg.contentPreserved,
                "disfluencyRemoved": agg.disfluencyRemoved, "disfluencyTargets": agg.disfluencyTargets,
                "modelUsed": agg.modelUsed, "timeouts": agg.timeouts, "meanSimilarity": agg.meanSimilarity,
                "latencyP50Ms": agg.p50, "latencyP95Ms": agg.p95,
                "negativesUnchanged": run.cases.filter { $0.negative && $0.outcome.unchanged }.count,
                "negatives": run.cases.filter(\.negative).count,
                "cases": run.cases.map { caseJSON($0, verdict: verdicts[$0.id]) },
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1, "title": "Reformat (held-out)", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "arguments": Array(CommandLine.arguments.dropFirst()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "modelAvailable": SmartCleaner.isModelAvailable, "backend": LanguageModels.current.identifier,
            "goldenSHA256": ReformatRunner.sha256(of: golden),
            "elapsedSeconds": elapsedSeconds, "levels": levels,
        ]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private static func caseJSON(_ item: CaseRun, verdict: ReformatJudge.Verdict?) -> [String: Any] {
        var entry: [String: Any] = [
            "id": item.id, "category": item.category, "lengthBucket": item.lengthBucket, "negative": item.negative,
            "input": item.input, "reference": item.reference, "output": item.output,
            "usedModel": item.usedModel, "rejection": item.rejection as Any? ?? NSNull(), "latencyMs": item.latencyMs,
            "passed": item.outcome.passed, "failureReasons": item.outcome.failureReasons,
            "contentPreserved": item.outcome.contentPreserved, "unchanged": item.outcome.unchanged,
            "disfluencyRemoved": item.outcome.disfluencyRemoved, "disfluencyTargets": item.outcome.disfluencyTargets,
            "similarity": item.outcome.similarity,
        ]
        if let verdict {
            entry["judge"] = ["meaning": verdict.meaning, "pBad": verdict.pBad, "band": verdict.band.rawValue, "faults": verdict.faults]
        }
        return entry
    }

    static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
    static func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
}
