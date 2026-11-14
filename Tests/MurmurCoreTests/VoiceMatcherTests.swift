import Foundation
import Testing
@testable import MurmurCore

/// Covers `VoiceSimilarity.cosine`, `VoiceMatcher.bestMatch`'s threshold behavior (the "similarity
/// thresholds" test this task requires), and `DiarizedSpeakerEmbeddings.averageEmbeddings`. All
/// pure functions, no FluidAudio/CoreML dependency — synthetic vectors only.
@Suite("VoiceSimilarity")
struct VoiceSimilarityTests {
    @Test("identical vectors have cosine similarity 1")
    func identicalVectorsScoreOne() {
        let vector: [Float] = [0.6, 0.8, 0]
        #expect(abs(VoiceSimilarity.cosine(vector, vector) - 1) < 0.0001)
    }

    @Test("orthogonal vectors have cosine similarity 0")
    func orthogonalVectorsScoreZero() {
        #expect(abs(VoiceSimilarity.cosine([1, 0], [0, 1])) < 0.0001)
    }

    @Test("opposite vectors have cosine similarity -1")
    func oppositeVectorsScoreNegativeOne() {
        #expect(abs(VoiceSimilarity.cosine([1, 0], [-1, 0]) - (-1)) < 0.0001)
    }

    @Test("mismatched-length vectors return 0 rather than crashing")
    func mismatchedLengthReturnsZero() {
        #expect(VoiceSimilarity.cosine([1, 0], [1, 0, 0]) == 0)
    }

    @Test("empty vectors return 0")
    func emptyVectorsReturnZero() {
        #expect(VoiceSimilarity.cosine([], []) == 0)
    }

    @Test("zero-norm vector returns 0 rather than dividing by zero")
    func zeroNormVectorReturnsZero() {
        #expect(VoiceSimilarity.cosine([0, 0, 0], [1, 0, 0]) == 0)
    }

    @Test("weightedAverage re-normalizes to unit length")
    func weightedAverageIsUnitNormalized() {
        let existing: [Float] = [1, 0, 0]
        let new: [Float] = [0, 1, 0]
        let averaged = VoiceSimilarity.weightedAverage(existing: existing, existingCount: 1, new: new)
        let norm = averaged.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 0.0001)
    }

    @Test("weightedAverage weights existing samples more heavily as sampleCount grows")
    func weightedAverageWeightsByCount() {
        let existing: [Float] = [1, 0]
        let new: [Float] = [0, 1]
        let earlyAverage = VoiceSimilarity.weightedAverage(existing: existing, existingCount: 1, new: new)
        let lateAverage = VoiceSimilarity.weightedAverage(existing: existing, existingCount: 99, new: new)
        // With more existing weight, the result should stay closer to `existing` (higher first
        // component) than the early-average case.
        #expect(lateAverage[0] > earlyAverage[0])
    }
}

@Suite("VoiceMatcher")
struct VoiceMatcherTests {
    /// Two orthonormal-ish basis vectors in a small embedding space, used to construct
    /// "same speaker" (near-parallel) and "different speaker" (near-orthogonal) test embeddings
    /// without needing a real 256-d FluidAudio embedding.
    private func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return vector.map { $0 / norm }
    }

    @Test("returns the voice above threshold when exactly one qualifies")
    func returnsSingleQualifyingMatch() {
        let target = normalized([1, 0, 0])
        let voices: [(id: Int64, name: String, embedding: [Float])] = [
            (1, "Dana", normalized([0.99, 0.05, 0])),
            (2, "Sam", normalized([0, 1, 0])),
        ]
        let match = VoiceMatcher.bestMatch(for: target, among: voices)
        #expect(match?.id == 1)
        #expect(match?.name == "Dana")
    }

    @Test("returns nil when no voice clears the threshold")
    func returnsNilBelowThreshold() {
        let target = normalized([1, 0, 0])
        let voices: [(id: Int64, name: String, embedding: [Float])] = [
            (1, "Dana", normalized([0, 1, 0])),
            (2, "Sam", normalized([0, 0, 1])),
        ]
        #expect(VoiceMatcher.bestMatch(for: target, among: voices) == nil)
    }

    @Test("returns nil against an empty voice library")
    func returnsNilForEmptyLibrary() {
        #expect(VoiceMatcher.bestMatch(for: normalized([1, 0]), among: []) == nil)
    }

    @Test("picks the single highest-scoring voice when several clear the threshold")
    func picksHighestScoringMatch() {
        let target = normalized([1, 0, 0])
        let voices: [(id: Int64, name: String, embedding: [Float])] = [
            (1, "CloseEnough", normalized([0.9, 0.1, 0])),
            (2, "BestMatch", normalized([0.999, 0.001, 0])),
        ]
        let match = VoiceMatcher.bestMatch(for: target, among: voices)
        #expect(match?.id == 2)
    }

    @Test("a custom threshold is honored over the default")
    func customThresholdIsHonored() {
        // [0.8, 0.6, 0] is already unit length, so its cosine similarity to [1, 0, 0] is exactly
        // its first component, 0.8 — above a 0.75 threshold, below a 0.95 one.
        let target: [Float] = [1, 0, 0]
        let voices: [(id: Int64, name: String, embedding: [Float])] = [(1, "Dana", [0.8, 0.6, 0])]
        #expect(VoiceMatcher.bestMatch(for: target, among: voices, threshold: 0.75) != nil)
        #expect(VoiceMatcher.bestMatch(for: target, among: voices, threshold: 0.95) == nil)
    }

    @Test("a match exactly at the threshold is included (>=, not >)")
    func matchAtExactThresholdIsIncluded() {
        let target: [Float] = [1, 0]
        let voice: [Float] = [1, 0]  // cosine similarity exactly 1.0
        let match = VoiceMatcher.bestMatch(for: target, among: [(1, "Exact", voice)], threshold: 1.0)
        #expect(match != nil)
    }
}

@Suite("DiarizedSpeakerEmbeddings")
struct DiarizedSpeakerEmbeddingsTests {
    @Test("averages multiple turns for the same speaker into one unit-normalized embedding")
    func averagesSameSpeakerTurns() {
        let entries = [
            LabeledEmbedding(speakerLabel: "S1", embedding: [1, 0], durationSeconds: 5),
            LabeledEmbedding(speakerLabel: "S1", embedding: [1, 0], durationSeconds: 5),
        ]
        let averaged = DiarizedSpeakerEmbeddings.averageEmbeddings(by: entries)
        #expect(averaged["S1"] != nil)
        let norm = averaged["S1"]!.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 0.0001)
    }

    @Test("keeps distinct speakers' embeddings separate")
    func keepsDistinctSpeakersSeparate() {
        let entries = [
            LabeledEmbedding(speakerLabel: "S1", embedding: [1, 0], durationSeconds: 5),
            LabeledEmbedding(speakerLabel: "S2", embedding: [0, 1], durationSeconds: 5),
        ]
        let averaged = DiarizedSpeakerEmbeddings.averageEmbeddings(by: entries)
        #expect(averaged.count == 2)
        #expect(averaged["S1"] != averaged["S2"])
    }

    @Test("weights longer turns more heavily than shorter ones")
    func weightsLongerTurnsMoreHeavily() throws {
        let entries = [
            LabeledEmbedding(speakerLabel: "S1", embedding: [1, 0], durationSeconds: 100),
            LabeledEmbedding(speakerLabel: "S1", embedding: [0, 1], durationSeconds: 1),
        ]
        let averaged = DiarizedSpeakerEmbeddings.averageEmbeddings(by: entries)
        let result = try #require(averaged["S1"])
        // The long turn should dominate, so the first component stays much larger than the second.
        #expect(result[0] > result[1])
    }

    @Test("ignores empty embeddings and zero/negative durations")
    func ignoresDegenerateEntries() {
        let entries = [
            LabeledEmbedding(speakerLabel: "S1", embedding: [], durationSeconds: 5),
            LabeledEmbedding(speakerLabel: "S1", embedding: [1, 0], durationSeconds: 0),
        ]
        #expect(DiarizedSpeakerEmbeddings.averageEmbeddings(by: entries).isEmpty)
    }

    @Test("empty input returns an empty result")
    func emptyInputReturnsEmpty() {
        #expect(DiarizedSpeakerEmbeddings.averageEmbeddings(by: []).isEmpty)
    }
}
