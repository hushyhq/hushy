import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MurmurCore

/// Loads a sealed model: the weights are decrypted in this process, chunk by chunk, and go straight into the
/// model's arrays. No plaintext file, temporary file or mounted image exists at any point.
///
/// The stock loader (`LLMModelFactory.load(from:)`) reads weights from file paths and has no hook for another
/// source, so this repeats its steps with the same public pieces: build the model from `config.json` with the
/// factory's own type registry, `sanitize`, quantize per layer, `update(parameters:verify: .all)`, prepare the
/// inference state, tokenizer, `ModelContext`. `SealedModelLoaderTests` loads one model both ways and compares the
/// weights, so a drift from the library on upgrade shows up as a failing test (docs/engineering/SEALED-MODELS.md).
enum SealedModelLoader {
    /// The stock factory's processor is private and Hushy never prepares chat input through it.
    private struct NoProcessor: UserInputProcessor {
        func prepare(input: UserInput) async throws -> LMInput {
            throw SealedModelLoader.Failure.noProcessor
        }
    }

    /// What a call that cannot get a key says; the engine and `MLXLanguageModel` recognise it (a key problem is
    /// temporary: it must not switch the model off for the rest of the run).
    static let keyUnavailablePrefix = "Hushy's model key is not available"

    enum Failure: Error, LocalizedError {
        case noKeySource
        case noProcessor
        /// No key now: signed out, offline, not published yet, or it does not open the files. Try again later.
        case keyUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .noKeySource: "This model is sealed and no key source was given."
            case .noProcessor: "Sealed models do not prepare chat input."
            case .keyUnavailable(let why): "\(SealedModelLoader.keyUnavailablePrefix) (\(why))."
            }
        }
    }

    static func load(directory: URL, modelID: String, keys: any SealedKeySource) async throws -> ModelContext {
        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let baseConfig = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
        let model = try await LLMModelFactory.shared.typeRegistry.createModel(
            configuration: configData, modelType: baseConfig.modelType)

        var eosTokenIds = baseConfig.effectiveEOSTokenIds
        var stopStrings = Set<String>()
        if let data = try? Data(contentsOf: directory.appendingPathComponent("generation_config.json")),
           let generation = try? JSONDecoder.json5().decode(GenerationConfigFile.self, from: data) {
            if let ids = generation.eosTokenIds?.values { eosTokenIds = Set(ids) }
            stopStrings = generation.stopStrings
        }

        let stream: SealedPlainStream
        do {
            stream = try await SealedModelOpener.open(directory: directory, modelID: modelID, keys: keys)
        } catch let damaged as SealedWeightsError {
            throw damaged   // files that are not whole: a real failure, not a key problem
        } catch {
            throw Failure.keyUnavailable(error.localizedDescription)
        }
        try apply(stream: stream, to: model, perLayerQuantization: baseConfig.perLayerQuantization)

        let tokenizer = try await TokenizerLoaderBridge().load(from: directory)
        let configuration = ModelConfiguration(
            directory: directory, stopStrings: stopStrings, eosTokenIds: eosTokenIds)
        return ModelContext(configuration: configuration, model: model, processor: NoProcessor(), tokenizer: tokenizer)
    }

    /// `loadWeights(modelDirectory:model:…)` with the weights taken from `stream` instead of from files.
    static func apply(
        stream: SealedPlainStream, to model: any MLXLMCommon.LanguageModel,
        perLayerQuantization: BaseConfiguration.PerLayerQuantization?
    ) throws {
        let (loaded, metadata) = try SealedSafetensors.load(from: stream)
        let weights = model.sanitize(weights: loaded, metadata: metadata)
        if let perLayerQuantization {
            quantize(model: model) { path, _ -> (groupSize: Int, bits: Int, mode: QuantizationMode)? in
                guard weights["\(path).scales"] != nil, let quantization = perLayerQuantization.quantization(layer: path) else { return nil }
                return quantization.asTuple
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        // The stock loader treats a failed optional optimisation as "keep going unfused".
        do { try model.prepare() } catch { MLXLog.model.error("sealed model prepare failed: \(String(describing: error), privacy: .public)") }
        eval(model)
    }
}

/// Measurement only (`murmur-eval sealed-parity`): loads a model both ways and compares every weight byte for byte.
public enum SealedModelParity {
    public struct Report: Sendable {
        public let tensors: Int
        public let bytes: Int64
        public let mismatches: [String]
        public let sealedLoadMilliseconds: Double
        public let plainLoadMilliseconds: Double
    }

    public static func compare(
        plainDirectory: URL, sealedDirectory: URL, sealedModelID: String, keys: any SealedKeySource
    ) async throws -> Report {
        func parameters(_ context: ModelContext) -> [String: MLXArray] {
            Dictionary(uniqueKeysWithValues: context.model.parameters().flattened())
        }
        let plainStart = ContinuousClock.now
        let plain = try await LLMModelFactory.shared.load(
            from: try MLXShardMaterializer.loadDirectory(plainDirectory), using: TokenizerLoaderBridge())
        let plainMs = MLXEngine.milliseconds(since: plainStart)
        let sealedStart = ContinuousClock.now
        let sealed = try await SealedModelLoader.load(directory: sealedDirectory, modelID: sealedModelID, keys: keys)
        let sealedMs = MLXEngine.milliseconds(since: sealedStart)
        let left = parameters(plain)
        let right = parameters(sealed)
        var bad: [String] = left.keys.filter { right[$0] == nil }.map { "missing \($0)" }
        bad += right.keys.filter { left[$0] == nil }.map { "extra \($0)" }
        var bytes: Int64 = 0
        for (name, array) in left {
            guard let other = right[name] else { continue }
            bytes += Int64(array.nbytes)
            if array.shape != other.shape || array.dtype != other.dtype || array.asData().data != other.asData().data {
                bad.append("differs \(name)")
            }
        }
        return Report(tensors: left.count, bytes: bytes, mismatches: bad.sorted(), sealedLoadMilliseconds: sealedMs, plainLoadMilliseconds: plainMs)
    }
}
