import Foundation

/// Markdown tables and the per-item JSON for `murmur-eval judge calibrate`.
enum CalibrationReport {
    typealias M = CalibrationMetrics

    /// Jev's price per input token (TypeSafe models page, jev-1.13: $0.042 per million input
    /// tokens, output free). Update with the docs.
    static let jevDollarsPerInputToken = 0.042 / 1_000_000
    static let thresholds = [0.3, 0.5, 0.7, 0.9]

    struct Row {
        let name: String
        let items: [CalibrationItem]
        let predictedBad: [Bool]
        let probabilities: [Double]?
    }

    static func rows(_ r: CalibrationResults, subsets: JudgeCalibrationRunner.Subsets) -> [Row] {
        var rows: [Row] = []
        func jevRow(_ name: String, _ pool: [CalibrationItem], _ source: [String: JevJudgment]) {
            let items = pool.filter { source[$0.id] != nil }
            guard !items.isEmpty else { return }
            rows.append(Row(
                name: name, items: items, predictedBad: items.map { !source[$0.id]!.passed() },
                probabilities: items.map { source[$0.id]!.pBad }))
        }
        func checksRow(_ name: String, _ items: [CalibrationItem]) {
            rows.append(Row(name: name, items: items, predictedBad: items.map { !$0.checksPassed }, probabilities: nil))
        }
        jevRow("Jev v2 (with reference)", r.items, r.jevV2)
        checksRow("Deterministic checks", r.items)
        let codexItems = subsets.codex.filter { r.codex[$0.id] != nil }
        if !codexItems.isEmpty {
            jevRow("Jev v2 — Codex subset", codexItems, r.jevV2)
            rows.append(Row(
                name: "Codex gpt-6-luna (low)", items: codexItems,
                predictedBad: codexItems.map { !r.codex[$0.id]!.passed },
                probabilities: codexItems.map { max(0, min(1, (4 - r.codex[$0.id]!.meaningScore) / 4)) }))
            checksRow("Checks — Codex subset", codexItems)
        }
        let ablation = subsets.ablation
        jevRow("Jev v2 — ablation subset", ablation, r.jevV2)
        jevRow("Jev v2 without reference — ablation", ablation, r.jevV2NoRef)
        let v1Items = ablation.filter { r.jevV1[$0.id] != nil }
        if !v1Items.isEmpty {
            rows.append(Row(
                name: "Jev v1 (old 5-question rubric) — ablation", items: v1Items,
                predictedBad: v1Items.map { !r.jevV1[$0.id]!.passed }, probabilities: v1Items.map { r.jevV1[$0.id]!.pBad }))
        }
        return rows
    }

    static func mainTable(_ rows: [Row]) -> [String] {
        var lines = [
            "| Judge | n (bad) | Accuracy | Bad precision | Bad recall | False-alarm rate | AUC | ECE | Brier |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        for row in rows {
            let labels = row.items.map(\.isBad)
            let d = M.Detection(labelsBad: labels, predictedBad: row.predictedBad)
            let probs = row.probabilities
            lines.append("| \(row.name) | \(row.items.count) (\(labels.filter { $0 }.count)) | \(pct(d.accuracy)) | \(pct(d.precision)) | \(pct(d.recall)) | \(pct(d.falsePositiveRate)) | "
                + (probs.map { f2(M.auc(scores: $0, labels: labels)) } ?? "—") + " | "
                + (probs.map { f2(M.expectedCalibrationError(probabilities: $0, labels: labels)) } ?? "—") + " | "
                + (probs.map { f2(M.brier(probabilities: $0, labels: labels)) } ?? "—") + " |")
        }
        return lines
    }

    static func kindTable(_ r: CalibrationResults) -> [String] {
        var lines = [
            "| Kind | Label | n | Jev v2 flags bad | Codex flags bad (n) | Checks flag bad |",
            "|---|---|---|---|---|---|",
        ]
        for (kind, group) in Dictionary(grouping: r.items, by: \.kind).sorted(by: { $0.key < $1.key }) {
            let judged = group.filter { r.jevV2[$0.id] != nil }
            let jev = judged.filter { !r.jevV2[$0.id]!.passed() }.count
            let codexItems = group.filter { r.codex[$0.id] != nil }
            let codex = codexItems.filter { !r.codex[$0.id]!.passed }.count
            let checks = group.filter { !$0.checksPassed }.count
            let labels = Set(group.map(\.label)).sorted().joined(separator: "/")
            lines.append("| \(kind) | \(labels) | \(group.count) | \(judged.isEmpty ? "—" : "\(jev)/\(judged.count)") | "
                + (codexItems.isEmpty ? "—" : "\(codex)/\(codexItems.count)") + " | \(checks)/\(group.count) |")
        }
        return lines
    }

    /// Per-fault question quality: positives are bad items whose faults include the dimension,
    /// negatives are the good items.
    static func faultTable(_ r: CalibrationResults) -> [String] {
        var lines = ["| Jev question | positives | negatives | AUC | mean p (positives) | mean p (good) |", "|---|---|---|---|---|---|"]
        let good = r.items.filter { !$0.isBad && r.jevV2[$0.id] != nil }
        for key in ["meaning_broken", "dropped_content", "changed_fact", "disfluency_left", "correction_left", "over_edited", "layout_wrong", "reads_unclean"] {
            let positives = r.items.filter { $0.isBad && $0.faults.contains(key) && r.jevV2[$0.id] != nil }
            guard !positives.isEmpty else { continue }
            let pos = positives.map { r.jevV2[$0.id]!.faults[key] ?? 0 }
            let neg = good.map { r.jevV2[$0.id]!.faults[key] ?? 0 }
            lines.append("| \(key) | \(pos.count) | \(neg.count) | \(f2(M.auc(scores: pos + neg, labels: pos.map { _ in true } + neg.map { _ in false }))) | \(f2(mean(pos))) | \(f2(mean(neg))) |")
        }
        return lines
    }

    static func thresholdTable(_ r: CalibrationResults) -> [String] {
        let items = r.items.filter { r.jevV2[$0.id] != nil }
        var lines = ["| Jev v2 fault threshold | Accuracy | Bad precision | Bad recall | False-alarm rate |", "|---|---|---|---|---|"]
        for t in thresholds {
            let d = M.Detection(labelsBad: items.map(\.isBad), predictedBad: items.map { r.jevV2[$0.id]!.pBad >= t })
            lines.append("| \(t) | \(pct(d.accuracy)) | \(pct(d.precision)) | \(pct(d.recall)) | \(pct(d.falsePositiveRate)) |")
        }
        return lines
    }

    static func bandTable(_ r: CalibrationResults) -> [String] {
        let items = r.items.filter { r.jevV2[$0.id] != nil }
        var lines = ["| Jev band (pBad) | n | bad items | good items | observed bad rate |", "|---|---|---|---|---|"]
        for band in [JevJudgment.Band.pass, .unsure, .fail] {
            let members = items.filter { r.jevV2[$0.id]!.band == band }
            let bad = members.filter(\.isBad).count
            lines.append("| \(band.rawValue) | \(members.count) | \(bad) | \(members.count - bad) | \(pct(M.ratio(bad, members.count))) |")
        }
        return lines
    }

    static func reliabilityTable(_ r: CalibrationResults) -> [String] {
        let items = r.items.filter { r.jevV2[$0.id] != nil }
        let bins = M.reliability(probabilities: items.map { r.jevV2[$0.id]!.pBad }, labels: items.map(\.isBad))
        return ["| Jev pBad bin | n | mean pBad | observed bad rate |", "|---|---|---|---|"]
            + bins.map { "| \(f2($0.lower))–\(f2($0.upper)) | \($0.count) | \(f2($0.meanPredicted)) | \(pct($0.observedRate)) |" }
    }

    static func determinism(_ r: CalibrationResults) -> [String] {
        let ids = r.jevRepeats.keys.filter { r.jevV2[$0] != nil }
        let deltas = ids.map { id -> Double in
            let a = r.jevV2[id]!, b = r.jevRepeats[id]!
            return zip(a.faults.sorted { $0.key < $1.key }, b.faults.sorted { $0.key < $1.key })
                .map { abs($0.value - $1.value) }.max() ?? 0
        }
        let flips = ids.filter { r.jevV2[$0]!.passed() != r.jevRepeats[$0]!.passed() }.count
        let codexIDs = r.codexRepeats.keys.filter { r.codex[$0] != nil }
        let codexFlips = codexIDs.filter { r.codex[$0]!.passed != r.codexRepeats[$0]!.passed }.count
        let codexScoreDelta = codexIDs.map { abs(r.codex[$0]!.meaningScore - r.codexRepeats[$0]!.meaningScore) }.max() ?? 0
        return [
            "- Jev repeats: \(ids.count) items asked a second time (cached under the repeat tag) · max |Δ fault p| \(String(format: "%.3f", deltas.max() ?? 0)) · mean \(String(format: "%.3f", mean(deltas))) · verdict flips \(flips)",
            "- Codex repeats: \(codexIDs.count) items · verdict flips \(codexFlips) · max |Δ meaning_score| \(String(format: "%.1f", codexScoreDelta))",
        ]
    }

    static func pairwise(_ answers: [CalibrationResults.PairwiseAnswer], name: String) -> String {
        guard !answers.isEmpty else { return "- \(name) pairwise: not run" }
        let correct = answers.filter(\.correct).count
        let byBad = Dictionary(grouping: answers, by: \.badID)
        let consistent = byBad.values.filter { $0.count == 2 && $0[0].correct == $0[1].correct }.count
        let bothRight = byBad.values.filter { $0.count == 2 && $0.allSatisfy(\.correct) }.count
        let firstPicks = answers.filter { $0.choice == "a" }.count
        return "- \(name) pairwise (good vs one-fault output, both orders): picked the good output \(correct)/\(answers.count) · both orders right \(bothRight)/\(byBad.count) pairs · order-consistent \(consistent)/\(byBad.count) · chose A \(firstPicks)/\(answers.count) · said same \(answers.filter { $0.choice == "same" }.count)"
    }

    static func cost(_ r: CalibrationResults) -> [String] {
        let tokens = r.jevTokens.map(Double.init)
        let perCall = mean(tokens) * jevDollarsPerInputToken
        return [
            "- Jev: \(r.jevCallsUsed) uncached calls this run · mean \(Int(mean(tokens))) input tokens/call (≈ $\(String(format: "%.6f", perCall))/call, $\(String(format: "%.4f", perCall * 100)) per 100 cases) · latency p50 \(String(format: "%.2f", M.percentile(r.jevLatencies, 0.5))) s, p95 \(String(format: "%.2f", M.percentile(r.jevLatencies, 0.95))) s (n=\(r.jevLatencies.count))",
            "- Codex: \(r.codexCallsUsed) uncached calls this run · latency p50 \(String(format: "%.1f", M.percentile(r.codexLatencies, 0.5))) s, p95 \(String(format: "%.1f", M.percentile(r.codexLatencies, 0.95))) s (n=\(r.codexLatencies.count)) · cost = ChatGPT-plan Codex quota, no per-call price",
        ]
    }

    /// Items where Jev and the checks disagree, for hand review.
    static func disagreements(_ r: CalibrationResults) -> [String] {
        r.items.compactMap { item in
            guard let j = r.jevV2[item.id], j.passed() != item.checksPassed else { return nil }
            let codex = r.codex[item.id].map { $0.passed ? "pass" : "fail" } ?? "—"
            return "  - \(item.id) label=\(item.label) checks=\(item.checksPassed ? "pass" : "fail") jev=\(j.passed() ? "pass" : "fail")(pBad \(f2(j.pBad)) \(j.firedFaults())) codex=\(codex)\n      output: \(item.output.replacingOccurrences(of: "\n", with: " ⏎ "))"
        }
    }

    static func emit(_ r: CalibrationResults, subsets: JudgeCalibrationRunner.Subsets) {
        let summary = (["### Judge calibration · \(r.items.count) labeled dev items · Jev \(JevRubric.model) rubric \(JevRubric.version) vs Codex vs checks", ""]
            + mainTable(rows(r, subsets: subsets)) + [""] + kindTable(r) + [""] + faultTable(r) + [""]
            + thresholdTable(r) + [""] + bandTable(r) + [""] + reliabilityTable(r) + [""] + determinism(r)
            + [pairwise(r.jevPairwise, name: "Jev"), pairwise(r.codexPairwise, name: "Codex")] + cost(r))
            .joined(separator: "\n")
        let details = disagreements(r)
        Runners.emit(summary, details: details.isEmpty ? [] : ["Jev × checks disagreements (review by hand):"] + details)
    }

    static func writeJSON(_ r: CalibrationResults, path: String) throws {
        let entries: [[String: Any]] = r.items.map { item in
            var entry: [String: Any] = [
                "id": item.id, "kind": item.kind, "label": item.label, "level": item.level, "checksPassed": item.checksPassed,
                "output": item.output,
            ]
            if let j = r.jevV2[item.id] { entry["jev"] = ["passed": j.passed(), "pBad": j.pBad, "faults": j.faults, "meaning": j.meaning, "listLayout": j.listLayout] }
            if let j = r.jevRepeats[item.id] { entry["jevRepeat"] = ["passed": j.passed(), "pBad": j.pBad, "faults": j.faults] }
            if let j = r.jevV2NoRef[item.id] { entry["jevNoRef"] = ["passed": j.passed(), "pBad": j.pBad] }
            if let j = r.jevV1[item.id] { entry["jevV1"] = ["passed": j.passed, "pBad": j.pBad] }
            if let c = r.codex[item.id] { entry["codex"] = ["passed": c.passed, "meaningScore": c.meaningScore, "reasoning": c.reasoning] }
            return entry
        }
        let pairwise: [[String: Any]] = r.jevPairwise.map { ["judge": "jev", "badID": $0.badID, "goodFirst": $0.goodFirst, "choice": $0.choice] }
            + r.codexPairwise.map { ["judge": "codex", "badID": $0.badID, "goodFirst": $0.goodFirst, "choice": $0.choice] }
        let payload: [String: Any] = [
            "pairwise": pairwise,
            "schemaVersion": 1, "kind": "judge-calibration", "jevModel": JevRubric.model, "rubric": JevRubric.version,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "items": entries,
        ]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    static func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    static func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
    static func f2(_ value: Double) -> String { String(format: "%.2f", value) }
}
