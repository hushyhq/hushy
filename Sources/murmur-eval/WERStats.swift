import Foundation

/// Per-clip error counts, the unit every US-English/accent statistic is built from.
struct ScoredClip: Codable, Equatable {
    let id: String
    var group: String?
    var speaker: String?
    let reference: String
    let hypothesis: String
    /// Word edits and reference words after `WhisperEnglishNormalizer`.
    let edits: Int
    let words: Int
    let audioSeconds: Double
    let seconds: Double

    static func score(id: String, reference: String, hypothesis: String, audioSeconds: Double, seconds: Double,
                      group: String? = nil, speaker: String? = nil) -> ScoredClip {
        let totals = WhisperEnglishNormalizer.editTotals([(reference, hypothesis)])
        return ScoredClip(id: id, group: group, speaker: speaker, reference: reference, hypothesis: hypothesis,
                          edits: totals.edits, words: totals.words, audioSeconds: audioSeconds, seconds: seconds)
    }
}

/// Corpus WER, bootstrap confidence intervals, spread, and a speaker-level permutation test.
/// Everything is seeded (`SplitMix64`) so reruns print identical intervals.
enum WERStats {
    static func wer(_ clips: [ScoredClip]) -> Double {
        let words = clips.reduce(0) { $0 + $1.words }
        return words == 0 ? 0 : Double(clips.reduce(0) { $0 + $1.edits }) / Double(words)
    }

    /// Audio seconds per processing second (higher is faster), i.e. inverse real-time factor.
    static func speed(_ clips: [ScoredClip]) -> Double {
        clips.reduce(0) { $0 + $1.audioSeconds } / max(clips.reduce(0) { $0 + $1.seconds }, 0.001)
    }

    /// 95% percentile-bootstrap interval for corpus WER. Resamples whole clusters (e.g. speakers)
    /// with replacement when `cluster` is given, otherwise single clips. With fewer than two
    /// clusters there is nothing to resample and the interval is nil.
    static func interval(
        _ clips: [ScoredClip], cluster: ((ScoredClip) -> String)? = nil, resamples: Int = 1000, seed: UInt64 = 7
    ) -> (low: Double, high: Double)? {
        let units: [(edits: Int, words: Int)]
        if let cluster {
            units = Dictionary(grouping: clips, by: cluster).keys.sorted().map { key in
                let members = clips.filter { cluster($0) == key }
                return (members.reduce(0) { $0 + $1.edits }, members.reduce(0) { $0 + $1.words })
            }
        } else {
            units = clips.map { ($0.edits, $0.words) }
        }
        guard units.count >= 2 else { return nil }
        var generator = SplitMix64(seed: seed)
        var estimates: [Double] = []
        estimates.reserveCapacity(resamples)
        for _ in 0..<resamples {
            var edits = 0
            var words = 0
            for _ in units.indices {
                let unit = units[Int(generator.next() % UInt64(units.count))]
                edits += unit.edits
                words += unit.words
            }
            estimates.append(words == 0 ? 0 : Double(edits) / Double(words))
        }
        estimates.sort()
        let low = estimates[Int(Double(resamples - 1) * 0.025)]
        let high = estimates[Int(Double(resamples - 1) * 0.975)]
        return (low, high)
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation (n − 1); 0 for fewer than two values.
    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = mean(values)
        return (values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count - 1)).squareRoot()
    }

    /// Permutation test: are the group WERs more spread out than they would be if speakers were
    /// assigned to groups at random (same group sizes, in speakers)? Speakers stay intact, so
    /// this asks whether accent explains variation beyond speaker-to-speaker differences.
    /// Returns the observed standard deviation of group WERs and the one-sided p-value.
    static func accentPermutationTest(
        _ clips: [ScoredClip], permutations: Int = 2000, seed: UInt64 = 11
    ) -> (observedSD: Double, pValue: Double) {
        struct Speaker { let group: String; let edits: Int; let words: Int }
        let speakers = Dictionary(grouping: clips, by: { "\($0.group ?? "")|\($0.speaker ?? $0.id)" })
            .sorted { $0.key < $1.key }
            .map { key, members in
                Speaker(group: members.first?.group ?? "", edits: members.reduce(0) { $0 + $1.edits },
                        words: members.reduce(0) { $0 + $1.words })
            }
        let groups = Array(Set(speakers.map(\.group))).sorted()
        func groupSD(_ labels: [String]) -> Double {
            var edits: [String: Int] = [:]
            var words: [String: Int] = [:]
            for (speaker, label) in zip(speakers, labels) {
                edits[label, default: 0] += speaker.edits
                words[label, default: 0] += speaker.words
            }
            return standardDeviation(groups.map { Double(edits[$0] ?? 0) / Double(max(words[$0] ?? 0, 1)) })
        }
        let observed = groupSD(speakers.map(\.group))
        var labels = speakers.map(\.group)
        var generator = SplitMix64(seed: seed)
        var atLeast = 0
        for _ in 0..<permutations {
            for index in stride(from: labels.count - 1, to: 0, by: -1) {
                labels.swapAt(index, Int(generator.next() % UInt64(index + 1)))
            }
            if groupSD(labels) >= observed - 1e-12 { atLeast += 1 }
        }
        return (observed, Double(atLeast + 1) / Double(permutations + 1))
    }
}
