import Foundation
import MurmurCore

/// The app compares each cluster of a new note with every saved voice and suggests the best one at or above the
/// gate. This measures that, with a library: the voices "Remember" would have saved from one excerpt (every true
/// speaker with enough speech there) meet a later excerpt, and every cluster of at least `clusterMinSeconds`
/// picks its best voice. Competition between voices is what stops a lone voice claiming someone else's cluster.
struct LibraryCounts {
    var present = 0, correct = 0, wrongName = 0, missed = 0
    var stranger = 0, falseSuggestion = 0
}

extension VoiceMatchScorer {
    func libraryTrials(gate: Double) -> LibraryCounts {
        var counts = LibraryCounts()
        for earlier in excerpts {
            let library = Dictionary(uniqueKeysWithValues: savedVoices().filter { $0.excerpt.id == earlier.id }.map { ($0.speaker, $0.remember) })
            guard !library.isEmpty else { continue }
            for later in excerpts where later.id != earlier.id && later.half == earlier.half {
                for cluster in later.clusters where isVoiceCluster(cluster) {
                    let best = library.map { ($0.key, Double(VoiceSimilarity.cosine($0.value, cluster.avgTurn))) }.max { $0.1 < $1.1 }
                    let suggested = best.flatMap { $0.1 >= gate ? $0.0 : nil }
                    if later.recording == earlier.recording, let speaker = cluster.trueSpeaker, library[speaker] != nil {
                        counts.present += 1
                        if suggested == nil { counts.missed += 1 } else if suggested == speaker { counts.correct += 1 } else { counts.wrongName += 1 }
                    } else {
                        counts.stranger += 1
                        if suggested != nil { counts.falseSuggestion += 1 }
                    }
                }
            }
        }
        return counts
    }

    func isVoiceCluster(_ cluster: ClusterRecord) -> Bool {
        cluster.trueSpeaker != nil && cluster.purity >= VoiceMatchRules.minimumPurity
            && cluster.seconds >= VoiceMatchRules.clusterMinSeconds && !cluster.avgTurn.isEmpty
    }
}

extension VoiceMatchReport {
    static func library(_ scorer: VoiceMatchScorer, title: String, gates: [Double]) -> String {
        func ratio(_ n: Int, _ d: Int) -> String { d == 0 ? "n/a" : String(format: "%.1f%% (%d/%d)", Double(n) / Double(d) * 100, n, d) }
        var lines = ["#### Library of saved voices meeting a later excerpt · \(title)", "",
                     "Library = the voices saved from one excerpt (every speaker with enough speech). Each cluster of at least \(Int(VoiceMatchRules.clusterMinSeconds)) s in another excerpt of the same half takes its best voice at or above the gate. Present = that cluster's speaker is in the library (same recording); stranger = not (other recording, or a speaker the library lacks).", "",
                     "| gate | present clusters | right name | missed | wrong name | stranger clusters | named anyway |",
                     "|---|---|---|---|---|---|---|"]
        for gate in gates {
            let c = scorer.libraryTrials(gate: gate)
            lines.append("| \(String(format: "%.2f", gate)) | \(c.present) | \(ratio(c.correct, c.present)) | \(ratio(c.missed, c.present)) | \(ratio(c.wrongName, c.present)) | \(c.stranger) | \(ratio(c.falseSuggestion, c.stranger)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Pooled frame-wise DER of the diarization over the excerpts (a guard that a setting does not trade
    /// attribution for a tidier speaker count).
    static func der(_ excerpts: [ExcerptRecord], title: String) -> String {
        let parts = excerpts.compactMap(\.derSeconds).filter { $0.count == 4 }
        let total = parts.reduce(0) { $0 + $1[3] }
        guard total > 0 else { return "" }
        func share(_ index: Int) -> String { String(format: "%.1f%%", parts.reduce(0) { $0 + $1[index] } / total * 100) }
        let all = (0..<3).reduce(0.0) { sum, i in sum + parts.reduce(0) { $0 + $1[i] } } / total
        return "DER over \(title) (pooled, 0.25 s collar): \(String(format: "%.1f%%", all * 100)) = missed \(share(0)) + false alarm \(share(1)) + confusion \(share(2)).\n"
    }
}
