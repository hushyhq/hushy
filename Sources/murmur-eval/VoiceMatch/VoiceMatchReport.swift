import Foundation
import MurmurCore

/// Renders the measurement as markdown. Counts and scores only: no transcript text, names or audio.
enum VoiceMatchReport {
    static let reportedGates: [Double] = [0.55, 0.60, 0.65, 0.70, 0.75]
    static let searchGates: [Double] = stride(from: 0.50, through: 0.90, by: 0.025).map { $0 }

    private static func f(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "n/a" }
    private static func pct(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
    private static func ratio(_ n: Int, _ d: Int) -> String { d == 0 ? "n/a" : String(format: "%.1f%% (%d/%d)", Double(n) / Double(d) * 100, n, d) }

    // MARK: Speaker count

    static func speakerCounts(_ excerpts: [ExcerptRecord], title: String) -> String {
        func truth(_ e: ExcerptRecord) -> Int { e.trueSeconds.values.filter { $0 >= VoiceMatchRules.truthMinSeconds }.count }
        func detected(_ e: ExcerptRecord) -> Int { e.clusters.count }
        func detectedBig(_ e: ExcerptRecord) -> Int { e.clusters.filter { $0.seconds >= VoiceMatchRules.truthMinSeconds }.count }
        func row(_ label: String, _ subset: [ExcerptRecord]) -> String {
            let all = subset.map { VoiceMatchMeasurement.CountOutcome(detected: detected($0), truth: truth($0)) }
            let big = subset.map { VoiceMatchMeasurement.CountOutcome(detected: detectedBig($0), truth: truth($0)) }
            func tally(_ o: [VoiceMatchMeasurement.CountOutcome]) -> String {
                var exact = 0, over1 = 0, over2 = 0, under = 0
                for outcome in o {
                    switch outcome {
                    case .exact: exact += 1
                    case .over(let n): if n == 1 { over1 += 1 } else { over2 += 1 }
                    case .under: under += 1
                    }
                }
                return "\(exact) | \(over1) | \(over2) | \(under)"
            }
            let drift = Double(subset.map { detected($0) - truth($0) }.reduce(0, +)) / Double(max(subset.count, 1))
            return "| \(label) | \(subset.count) | \(tally(all)) | \(String(format: "%+.2f", drift)) | \(tally(big)) |"
        }
        var lines = ["#### Speaker count · \(title)", "",
                     "True speakers = those with at least \(Int(VoiceMatchRules.truthMinSeconds)) s of speech in the excerpt. Detected (all) counts every cluster the app would show; detected (≥5 s) ignores clusters under 5 s.", "",
                     "| group | excerpts | exact | over by 1 | over by 2+ | under | mean detected − true | exact (≥5 s) | over by 1 (≥5 s) | over by 2+ (≥5 s) | under (≥5 s) |",
                     "|---|---|---|---|---|---|---|---|---|---|---|"]
        for set in Array(Set(excerpts.map(\.set))).sorted() { lines.append(row(set, excerpts.filter { $0.set == set })) }
        lines.append(row("all", excerpts))
        return lines.joined(separator: "\n")
    }

    // MARK: Similarity

    static func similarity(_ scorer: VoiceMatchScorer, title: String) -> String {
        let scores = scorer.pairScores(.app)
        func row(_ label: String, _ values: [Double]) -> String {
            guard let q = VoiceMatchMeasurement.quantiles(values) else { return "| \(label) | 0 | n/a | n/a | n/a | n/a | n/a |" }
            return "| \(label) | \(q.count) | \(f(q.min)) | \(f(q.p10)) | \(f(q.median)) | \(f(q.p90)) | \(f(q.max)) |"
        }
        var lines = ["#### Similarity, saved voice vs a later cluster · \(title)", "",
                     "Saved voice = what \"Remember\" builds from the named cluster's clean turns in one excerpt; compared with every cluster of at least \(Int(VoiceMatchRules.clusterMinSeconds)) s in another excerpt of the same half (the app's own comparison).", "",
                     "| pair kind | n | min | p10 | median | p90 | max |", "|---|---|---|---|---|---|---|"]
        lines.append(row("same speaker (other excerpt, same recording)", scores.same))
        lines.append(row("different speaker, same recording", scores.differentSameRecording))
        lines.append(row("different speaker, other recording", scores.differentOtherRecording))
        let different = scores.differentSameRecording + scores.differentOtherRecording
        lines += ["", "| gate | missed same speaker | false match, same recording | false match, other recording | false match, all different |", "|---|---|---|---|---|"]
        for gate in reportedGates { lines.append(gateRow(gate, scores, different)) }
        return lines.joined(separator: "\n")
    }

    private static func gateRow(_ gate: Double, _ scores: PairScores, _ different: [Double]) -> String {
        let missed = scores.same.filter { $0 < gate }.count
        let falseSame = scores.differentSameRecording.filter { $0 >= gate }.count
        let falseOther = scores.differentOtherRecording.filter { $0 >= gate }.count
        return "| \(String(format: "%.2f", gate)) | \(ratio(missed, scores.same.count)) | \(ratio(falseSame, scores.differentSameRecording.count)) | \(ratio(falseOther, scores.differentOtherRecording.count)) | \(ratio(falseSame + falseOther, different.count)) |"
    }

    // MARK: Variants and over-split

    static func variants(_ scorer: VoiceMatchScorer, title: String) -> String {
        var lines = ["#### How the two embeddings are built · \(title)", "",
                     "| saved voice vs later cluster | same n | same median | same p10 | missed @0.75 | different n | different p90 | different max | false @0.75 |", "|---|---|---|---|---|---|---|---|---|"]
        for variant in MatchVariant.allCases {
            let scores = scorer.pairScores(variant)
            let different = scores.differentSameRecording + scores.differentOtherRecording
            let same = VoiceMatchMeasurement.quantiles(scores.same)
            let diff = VoiceMatchMeasurement.quantiles(different)
            lines.append("| \(variant.rawValue) | \(scores.same.count) | \(f(same?.median)) | \(f(same?.p10)) | \(pct(VoiceMatchMeasurement.missedRate(sameScores: scores.same, gate: 0.75))) | \(different.count) | \(f(diff?.p90)) | \(f(diff?.max)) | \(pct(VoiceMatchMeasurement.falseMatchRate(differentScores: different, gate: 0.75))) |")
        }
        return lines.joined(separator: "\n")
    }

    static func overSplit(_ scorer: VoiceMatchScorer, title: String) -> String {
        let rows = scorer.splitRows()
        let scores = scorer.pairScores(.app)
        func median(_ values: [Double]) -> String { f(VoiceMatchMeasurement.quantiles(values)?.median) }
        let missed = { (values: [Double]) in pct(VoiceMatchMeasurement.missedRate(sameScores: values, gate: 0.75)) }
        let both = rows.compactMap(\.mergedBothSides)
        return ["#### Over-split voices · \(title)", "",
                "Rows are (saved voice, later excerpt of the same recording) where the later excerpt splits that speaker into 2+ clusters of at least \(Int(VoiceMatchRules.splitMinSeconds)) s.", "",
                "| score | n | median | missed @0.75 |", "|---|---|---|---|",
                "| largest piece | \(rows.count) | \(median(rows.map(\.largest))) | \(missed(rows.map(\.largest))) |",
                "| best single piece | \(rows.count) | \(median(rows.map(\.bestPiece))) | \(missed(rows.map(\.bestPiece))) |",
                "| all pieces merged | \(rows.count) | \(median(rows.map(\.merged))) | \(missed(rows.map(\.merged))) |",
                "| merged on both sides | \(both.count) | \(median(both)) | \(missed(both)) |",
                "| (for comparison) every same-speaker pair | \(scores.same.count) | \(median(scores.same)) | \(missed(scores.same)) |"].joined(separator: "\n")
    }

    // MARK: End to end

    static func trials(_ scorer: VoiceMatchScorer, title: String, gates: [Double]) -> String {
        var lines = ["#### A saved voice meeting a later excerpt, as the app suggests · \(title)", "",
                     "Present = the speaker has at least \(Int(VoiceMatchRules.truthMinSeconds)) s in the later excerpt. Wrong name = the best cluster at or above the gate is someone else. False suggestion = the voice is not in the excerpt at all.", "",
                     "| gate | present | right name | missed | wrong name | absent | false suggestion |", "|---|---|---|---|---|---|---|"]
        for gate in gates {
            let t = scorer.trials(gate: gate)
            lines.append("| \(String(format: "%.3f", gate)) | \(t.present) | \(ratio(t.correct, t.present)) | \(ratio(t.missed, t.present)) | \(ratio(t.wrongName, t.present)) | \(t.absent) | \(ratio(t.falseSuggestion, t.absent)) |")
        }
        return lines.joined(separator: "\n")
    }

    /// The lowest gate on the search grid whose false-match rate (all different-speaker pairs) is at most `limit`.
    static func gateChosen(on scorer: VoiceMatchScorer, falseMatchLimit: Double) -> Double? {
        let scores = scorer.pairScores(.app)
        let different = scores.differentSameRecording + scores.differentOtherRecording
        return searchGates.first { (VoiceMatchMeasurement.falseMatchRate(differentScores: different, gate: $0) ?? 0) <= falseMatchLimit }
    }
}
