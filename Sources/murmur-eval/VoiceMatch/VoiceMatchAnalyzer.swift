import FluidAudio
import Foundation
import MurmurCore

/// Diarizes one excerpt exactly as the app diarizes a note (`performCompleteDiarization` with the app's
/// clustering settings over the whole excerpt) and builds each cluster's embeddings. Audio, names and text are
/// never printed; only the numbers in `ExcerptRecord` leave this type.
struct VoiceMatchAnalyzer {
    static let sampleRate = 16_000.0
    let manager: DiarizerManager

    static func loadManager(config: DiarizerConfig) throws -> DiarizerManager {
        let folder = DiarizerModels.defaultModelsDirectory()
        let segmentation = folder.appendingPathComponent("pyannote_segmentation.mlmodelc")
        let embedding = folder.appendingPathComponent("wespeaker_v2.mlmodelc")
        for url in [segmentation, embedding] where !FileManager.default.fileExists(atPath: url.path) {
            throw EvalError.missing("the speaker models are not on this Mac; this command never downloads them")
        }
        let models = try DiarizerModels.load(localSegmentationModel: segmentation, localEmbeddingModel: embedding)
        let manager = DiarizerManager(config: config)
        manager.initialize(models: models)
        return manager
    }

    func analyze(_ recording: VoiceMatchRecording, window: SpeechRange, index: Int) throws -> ExcerptRecord {
        let began = Date()
        let from = Int(window.start * Self.sampleRate)
        let to = min(Int(window.end * Self.sampleRate), recording.audio.count)
        let samples = Array(recording.audio[from..<to])
        let result = try manager.performCompleteDiarization(samples, sampleRate: Int(Self.sampleRate))

        let turns = result.segments.map {
            LabeledRange(label: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        let reference = VoiceMatchMeasurement.clipped(recording.turns, to: window)
        let origins = VoiceMatchMeasurement.origins(clusters: turns, reference: reference)
        let averaged = DiarizedSpeakerEmbeddings.averageEmbeddings(by: result.segments.map {
            LabeledEmbedding(speakerLabel: $0.speakerId, embedding: $0.embedding, durationSeconds: Double($0.durationSeconds))
        })
        let clusters = try origins.map { origin in
            ClusterRecord(
                label: origin.cluster, seconds: origin.seconds, trueSpeaker: origin.trueSpeaker, purity: origin.purity,
                avgTurn: averaged[origin.cluster] ?? [],
                remember: try rememberEmbedding(of: [origin.cluster], turns: turns, samples: samples),
                turns: turns.filter { $0.label == origin.cluster }.map { [$0.start, $0.end] })
        }
        let merged = try mergedEmbeddings(clusters: clusters, turns: turns, samples: samples)
        let der = DiarizationErrorRate.compute(
            reference: reference.map { DERSegment(speaker: $0.label, start: $0.start, end: $0.end) },
            hypothesis: turns.map { DERSegment(speaker: $0.label, start: $0.start, end: $0.end) })
        return ExcerptRecord(
            recording: recording.id, set: recording.set, half: recording.half, index: index, startSeconds: window.start,
            trueSeconds: VoiceMatchMeasurement.speechSeconds(reference), clusters: clusters,
            mergedAvgTurn: merged.avgTurn, mergedRemember: merged.remember, analysisSeconds: Date().timeIntervalSince(began),
            derSeconds: [der.missedSpeechSeconds, der.falseAlarmSeconds, der.confusionSeconds, der.totalReferenceSpeechSeconds])
    }

    /// The embedding "Remember <name>'s voice" would save for a speaker whose speech is `clusterLabels`' turns.
    private func rememberEmbedding(of clusterLabels: [String], turns: [LabeledRange], samples: [Float]) throws -> [Float]? {
        let own = turns.filter { clusterLabels.contains($0.label) }.map { SpeechRange(start: $0.start, end: $0.end) }
        let others = turns.filter { !clusterLabels.contains($0.label) }.map { SpeechRange(start: $0.start, end: $0.end) }
        guard case .ready(let ranges, _) = SpeakerVoiceSampling.select(own: own, others: others) else { return nil }
        var labelled: [LabeledEmbedding] = []
        for range in ranges {
            let from = max(0, Int(range.start * Self.sampleRate))
            let to = min(samples.count, Int(range.end * Self.sampleRate))
            guard from < to else { continue }
            let vector = try manager.extractSpeakerEmbedding(from: Array(samples[from..<to]))
            labelled.append(LabeledEmbedding(speakerLabel: "speaker", embedding: vector, durationSeconds: range.duration))
        }
        return DiarizedSpeakerEmbeddings.averageEmbeddings(by: labelled)["speaker"]
    }

    /// For each true speaker held by two or more clusters: those clusters' embeddings merged into one.
    private func mergedEmbeddings(clusters: [ClusterRecord], turns: [LabeledRange], samples: [Float]) throws
        -> (avgTurn: [String: [Float]], remember: [String: [Float]]) {
        let pieces = clusters.filter {
            $0.trueSpeaker != nil && $0.purity >= VoiceMatchRules.minimumPurity
                && $0.seconds >= VoiceMatchRules.splitMinSeconds && !$0.avgTurn.isEmpty
        }
        var avgTurn: [String: [Float]] = [:]
        var remember: [String: [Float]] = [:]
        for (speaker, group) in Dictionary(grouping: pieces, by: { $0.trueSpeaker ?? "" }) where group.count >= 2 {
            let weighted = group.map { LabeledEmbedding(speakerLabel: "m", embedding: $0.avgTurn, durationSeconds: $0.seconds) }
            if let vector = DiarizedSpeakerEmbeddings.averageEmbeddings(by: weighted)["m"] { avgTurn[speaker] = vector }
            if let vector = try rememberEmbedding(of: group.map(\.label), turns: turns, samples: samples) { remember[speaker] = vector }
        }
        return (avgTurn, remember)
    }
}
