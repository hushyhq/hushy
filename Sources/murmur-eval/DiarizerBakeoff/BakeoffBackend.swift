import FluidAudio
import Foundation
import MurmurCore

/// One diarizer under test. Each owns its loaded Core ML models and turns 16 kHz mono audio into
/// speaker turns; labels are only unique within one call.
protocol BakeoffDiarizer: AnyObject {
    func diarize(_ audio: [Float]) async throws -> [DERSegment]
}

/// The pipelines FluidAudio 0.17.4 ships that a meeting note could use.
enum BakeoffBackend: String, CaseIterable {
    /// What the app runs today: pyannote-3 segmentation + WeSpeaker + online clustering, with the
    /// app's own tuning (`DiarizerTuning`).
    case legacy
    /// pyannote community-1 offline pipeline: powerset segmentation, WeSpeaker, PLDA + VBx.
    case community1
    /// NVIDIA Nemotron 3 Diarization (Sortformer successor), up to 8 speakers, one preset each.
    case nemotronOffline = "nemotron-offline"
    case nemotronFast128 = "nemotron-fast128"
    case nemotronFast32 = "nemotron-fast32"
    /// `fast128`'s shape, split graph with 8-bit weights and activations: 95 MB, all on the Neural Engine.
    case nemotronC128W8A8 = "nemotron-c128-w8a8"

    /// `threshold` is community-1's clustering cut, or Nemotron's per-frame speaker probability cut.
    func make(modelsBase: URL, threshold: Double?) async throws -> any BakeoffDiarizer {
        switch self {
        case .legacy:
            return try await LegacyBakeoffDiarizer(modelsBase: modelsBase)
        case .community1:
            return try await Community1BakeoffDiarizer(modelsBase: modelsBase, threshold: threshold)
        case .nemotronOffline:
            return try await NemotronBakeoffDiarizer(config: .offline, modelsBase: modelsBase, threshold: threshold)
        case .nemotronFast128:
            return try await NemotronBakeoffDiarizer(config: .fast128, modelsBase: modelsBase, threshold: threshold)
        case .nemotronFast32:
            return try await NemotronBakeoffDiarizer(config: .fast32, modelsBase: modelsBase, threshold: threshold)
        case .nemotronC128W8A8:
            guard let config = Nemotron3Config.preset(named: "c128-split-w8a8") else {
                throw EvalError.missing("FluidAudio has no c128-split-w8a8 preset")
            }
            return try await NemotronBakeoffDiarizer(config: config, modelsBase: modelsBase, threshold: threshold)
        }
    }
}

final class LegacyBakeoffDiarizer: BakeoffDiarizer {
    private let manager: DiarizerManager

    init(modelsBase: URL) async throws {
        var config = DiarizerConfig.default
        config.clusteringThreshold = DiarizerTuning.clusteringThreshold
        config.minSpeechDuration = DiarizerTuning.minSpeechDuration
        let models = try await DiarizerModels.downloadIfNeeded(
            to: modelsBase.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true))
        manager = DiarizerManager(config: config)
        manager.initialize(models: models)
    }

    func diarize(_ audio: [Float]) async throws -> [DERSegment] {
        try manager.performCompleteDiarization(audio, sampleRate: 16_000).segments.map {
            DERSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }
}

final class Community1BakeoffDiarizer: BakeoffDiarizer {
    private let manager: OfflineDiarizerManager

    init(modelsBase: URL, threshold: Double?) async throws {
        let config = threshold.map { OfflineDiarizerConfig(clusteringThreshold: $0) } ?? OfflineDiarizerConfig()
        manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels(directory: modelsBase)
    }

    func diarize(_ audio: [Float]) async throws -> [DERSegment] {
        try await manager.process(audio: audio).segments.map {
            DERSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }
}

final class NemotronBakeoffDiarizer: BakeoffDiarizer {
    private let diarizer: Nemotron3Diarizer
    private let config: Nemotron3Config
    private let threshold: Float

    init(config: Nemotron3Config, modelsBase: URL, threshold: Double?) async throws {
        self.config = config
        self.threshold = threshold.map(Float.init) ?? 0.5
        let models = try await Nemotron3Models.loadFromHuggingFace(config: config, cacheDirectory: modelsBase)
        diarizer = Nemotron3Diarizer(config: config, models: models)
    }

    func diarize(_ audio: [Float]) async throws -> [DERSegment] {
        let (probabilities, frames) = try diarizer.processComplete(audio)
        return Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames, numSpeakers: config.numSpeakers, threshold: threshold)
            .map { DERSegment(speaker: "spk\($0.speakerIndex)", start: Double($0.startSeconds), end: Double($0.endSeconds)) }
    }
}
