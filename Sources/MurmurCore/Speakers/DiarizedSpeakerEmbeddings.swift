import Foundation

/// One diarizer-emitted turn's embedding, paired with its speaker label — the minimal input
/// `averageEmbeddings(by:)` needs. Kept independent of FluidAudio's `TimedSpeakerSegment` (same
/// "framework-agnostic mirror" pattern as `DiarizationTurn` in `SpeakerAlignment.swift`) so this
/// file has no FluidAudio dependency and is unit-testable with synthetic vectors.
public struct LabeledEmbedding: Sendable, Equatable {
    public let speakerLabel: String
    public let embedding: [Float]
    /// Duration of the turn this embedding came from, used as an averaging weight (a 10 s turn's
    /// embedding is a more reliable sample of that speaker than a 1 s one).
    public let durationSeconds: Double

    public init(speakerLabel: String, embedding: [Float], durationSeconds: Double) {
        self.speakerLabel = speakerLabel
        self.embedding = embedding
        self.durationSeconds = durationSeconds
    }
}

/// Averages every diarization turn's embedding for each distinct speaker label into one
/// representative, unit-normalized embedding per speaker — the input `VoiceMatcher.bestMatch`
/// needs to compare a diarized speaker (which may have many short turns) against the saved voice
/// library. Duration-weighted: longer turns count more, since they're less likely to be a
/// misclassified sliver of cross-talk or a very short utterance.
public enum DiarizedSpeakerEmbeddings {
    public static func averageEmbeddings(by speakerLabel: [LabeledEmbedding]) -> [String: [Float]] {
        var weightedSums: [String: [Float]] = [:]
        var totalWeights: [String: Double] = [:]

        for entry in speakerLabel {
            guard !entry.embedding.isEmpty, entry.durationSeconds > 0 else { continue }
            let weight = entry.durationSeconds
            if var sum = weightedSums[entry.speakerLabel] {
                guard sum.count == entry.embedding.count else { continue }
                for i in 0..<sum.count { sum[i] += entry.embedding[i] * Float(weight) }
                weightedSums[entry.speakerLabel] = sum
            } else {
                weightedSums[entry.speakerLabel] = entry.embedding.map { $0 * Float(weight) }
            }
            totalWeights[entry.speakerLabel, default: 0] += weight
        }

        var result: [String: [Float]] = [:]
        for (label, sum) in weightedSums {
            guard let weight = totalWeights[label], weight > 0 else { continue }
            var averaged = sum.map { $0 / Float(weight) }
            let norm = averaged.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { continue }
            for i in 0..<averaged.count { averaged[i] /= norm }
            result[label] = averaged
        }
        return result
    }
}
