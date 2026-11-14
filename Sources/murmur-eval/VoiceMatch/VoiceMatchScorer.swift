import Foundation
import MurmurCore

/// A voice as it would be saved after "Remember <name>'s voice" in one excerpt.
struct SavedVoice {
    let excerpt: ExcerptRecord
    let speaker: String
    let remember: [Float]
    let turnMean: [Float]
    /// The same voice built from every cluster that holds this speaker, when the speaker is split in that excerpt.
    let mergedRemember: [Float]?
}

/// Which embedding a saved voice is compared with, and which one a later cluster is compared with.
enum MatchVariant: String, CaseIterable {
    /// What the app does: saved voice from clean turns, later cluster by the mean of its turn embeddings.
    case app
    /// Both sides built the same way, from clean turns.
    case cleanBothSides
    /// Both sides the mean of turn embeddings.
    case turnMeanBothSides
}

struct PairScores {
    var same: [Double] = []
    var differentSameRecording: [Double] = []
    var differentOtherRecording: [Double] = []
}

struct SplitRow {
    let largest: Double
    let merged: Double
    let bestPiece: Double
    let mergedBothSides: Double?
}

struct TrialCounts {
    var present = 0, correct = 0, missed = 0, wrongName = 0
    var absent = 0, falseSuggestion = 0
}

struct VoiceMatchScorer {
    let excerpts: [ExcerptRecord]

    // MARK: Saved voices

    func savedVoices() -> [SavedVoice] {
        excerpts.flatMap { excerpt in
            excerpt.trueSeconds.filter { $0.value >= VoiceMatchRules.truthMinSeconds }.keys.sorted().compactMap { speaker in
                let pieces = pieces(of: speaker, in: excerpt, minimumSeconds: VoiceMatchRules.clusterMinSeconds)
                guard let largest = pieces.first, let remember = largest.remember else { return nil }
                return SavedVoice(
                    excerpt: excerpt, speaker: speaker, remember: remember, turnMean: largest.avgTurn,
                    mergedRemember: excerpt.mergedRemember[speaker])
            }
        }
    }

    /// Clusters that are mostly `speaker` and at least `minimumSeconds` long, longest first.
    func pieces(of speaker: String, in excerpt: ExcerptRecord, minimumSeconds: Double) -> [ClusterRecord] {
        excerpt.clusters
            .filter { $0.trueSpeaker == speaker && $0.purity >= VoiceMatchRules.minimumPurity && $0.seconds >= minimumSeconds && !$0.avgTurn.isEmpty }
            .sorted { $0.seconds > $1.seconds }
    }

    // MARK: Pair scores

    func pairScores(_ variant: MatchVariant) -> PairScores {
        var scores = PairScores()
        for saved in savedVoices() {
            for later in excerpts where later.id != saved.excerpt.id && later.half == saved.excerpt.half {
                for cluster in later.clusters where isVoiceCluster(cluster) {
                    guard let score = similarity(saved, cluster, variant) else { continue }
                    if later.recording != saved.excerpt.recording {
                        scores.differentOtherRecording.append(score)
                    } else if cluster.trueSpeaker == saved.speaker {
                        scores.same.append(score)
                    } else {
                        scores.differentSameRecording.append(score)
                    }
                }
            }
        }
        return scores
    }

    private func similarity(_ saved: SavedVoice, _ cluster: ClusterRecord, _ variant: MatchVariant) -> Double? {
        switch variant {
        case .app: return Double(VoiceSimilarity.cosine(saved.remember, cluster.avgTurn))
        case .cleanBothSides: return cluster.remember.map { Double(VoiceSimilarity.cosine(saved.remember, $0)) }
        case .turnMeanBothSides: return Double(VoiceSimilarity.cosine(saved.turnMean, cluster.avgTurn))
        }
    }

    // MARK: Over-split

    /// For every (saved voice, later excerpt of the same recording) where the later excerpt splits that speaker
    /// into two or more clusters: the score with the largest piece, with all pieces merged, and with the best piece.
    func splitRows() -> [SplitRow] {
        var rows: [SplitRow] = []
        for saved in savedVoices() {
            for later in excerpts where later.id != saved.excerpt.id && later.recording == saved.excerpt.recording {
                let split = pieces(of: saved.speaker, in: later, minimumSeconds: VoiceMatchRules.splitMinSeconds)
                guard split.count >= 2, let merged = later.mergedAvgTurn[saved.speaker] else { continue }
                let each = split.map { Double(VoiceSimilarity.cosine(saved.remember, $0.avgTurn)) }
                let both = saved.mergedRemember.map { Double(VoiceSimilarity.cosine($0, merged)) }
                rows.append(SplitRow(
                    largest: each[0], merged: Double(VoiceSimilarity.cosine(saved.remember, merged)),
                    bestPiece: each.max() ?? each[0], mergedBothSides: both))
            }
        }
        return rows
    }

    // MARK: End to end

    /// A saved voice meeting a later excerpt: every cluster there is compared and the best one at or above `gate`
    /// becomes the suggestion, as the app does. Wrong when that cluster is somebody else, or when the speaker is not there.
    func trials(gate: Double) -> TrialCounts {
        var counts = TrialCounts()
        for saved in savedVoices() {
            for later in excerpts where later.id != saved.excerpt.id && later.half == saved.excerpt.half {
                let scored = later.clusters.filter { !$0.avgTurn.isEmpty }
                    .map { ($0, Double(VoiceSimilarity.cosine(saved.remember, $0.avgTurn))) }
                let best = scored.max { $0.1 < $1.1 }
                let isPresent = later.recording == saved.excerpt.recording
                    && (later.trueSeconds[saved.speaker] ?? 0) >= VoiceMatchRules.truthMinSeconds
                let suggested = best.flatMap { $0.1 >= gate ? $0.0 : nil }
                if isPresent {
                    counts.present += 1
                    if let suggested {
                        let right = suggested.trueSpeaker == saved.speaker && suggested.purity >= VoiceMatchRules.minimumPurity
                        if right { counts.correct += 1 } else { counts.wrongName += 1 }
                    } else {
                        counts.missed += 1
                    }
                } else {
                    counts.absent += 1
                    if suggested != nil { counts.falseSuggestion += 1 }
                }
            }
        }
        return counts
    }
}
