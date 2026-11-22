import Foundation
import MurmurCore

extension MLXLanguageModel: UnloadableLanguageModel {}

extension MLXLanguageModel: ResidentModelMemory {}

/// The app's wiring of a `ModelRegistry` entry into a cleanup backend (M6), shared with
/// `murmur-eval --backend local` so evals measure exactly what the app runs:
/// `MLXLanguageModel` (speculation on, the entry's prompt profile) under its residency policy,
/// in front of Apple FM, with rules as the caller's last resort.
public enum LocalCleanupBackend {
    /// The MLX configuration an entry runs with in the app.
    /// `speculation` and `tuning` override the entry's flag and the default draft settings (measurement only:
    /// `murmur-eval … --speculate on|off --speculate-draft N`).
    public static func configuration(
        for entry: LocalModelEntry, directory: URL, keys: (any SealedKeySource)? = nil,
        speculation: Bool? = nil, tuning: SpeculationSettings? = nil
    ) -> MLXLanguageModel.Configuration {
        var configuration = MLXLanguageModel.Configuration(directory: directory)
        if entry.sealing != nil {
            configuration.sealedModelID = entry.id
            configuration.sealedKeys = keys
        }
        configuration.speculation = (speculation ?? entry.speculation) ? (tuning ?? SpeculationSettings()) : nil
        configuration.promptProfile = MLXLanguageModel.PromptProfile(rawValue: entry.promptProfile.rawValue) ?? .production
        configuration.toolGrammar = "strict"
        // The meeting-extract adapter (Run A) rides on the 4B it was trained on, unfused and on only for meeting-facts
        // calls (`MLXEngine.applyAdapterScope`). Present only when installed next to the model or named for an eval.
        let modelsRoot = directory.deletingLastPathComponent().deletingLastPathComponent()
        if MeetingExtractAdapter.fits(entryID: entry.id), configuration.adapterDirectory == nil,
           let adapter = MeetingExtractAdapter.installedDirectory(modelsRoot: modelsRoot) {
            configuration.adapterDirectory = adapter
            configuration.adapterScope = MLXEngine.meetingRecordsScope
        }
        return configuration
    }

    public static func model(
        for entry: LocalModelEntry, directory: URL, keys: (any SealedKeySource)? = nil,
        speculation: Bool? = nil, tuning: SpeculationSettings? = nil
    ) -> MLXLanguageModel {
        MLXLanguageModel(configuration: configuration(
            for: entry, directory: directory, keys: keys, speculation: speculation, tuning: tuning))
    }

    /// The pieces the app keeps: the chain to install, and the managed local model (for unload
    /// and memory pressure).
    public struct Chain: Sendable {
        public let model: any LanguageModel
        public let local: ManagedLocalModel
        public let mlx: MLXLanguageModel
    }

    /// local (managed, logged as "local") → `fallback` (logged as "apple"). `callLog` gets each
    /// leg's latency and outcome, never text.
    public static func chain(
        entry: LocalModelEntry, directory: URL, fallback: any LanguageModel, idleSeconds: TimeInterval?,
        callLog: ModelCallLog, keys: (any SealedKeySource)? = nil,
        speculation: Bool? = nil, tuning: SpeculationSettings? = nil,
        onUnload: @escaping @Sendable (LocalModelResidency.UnloadReason) -> Void = { _ in }
    ) -> Chain {
        let mlx = model(for: entry, directory: directory, keys: keys, speculation: speculation, tuning: tuning)
        let residency = LocalModelResidency(idleSeconds: idleSeconds, unload: { await mlx.unload() }, onUnload: onUnload)
        let managed = ManagedLocalModel(base: mlx, residency: residency)
        let chain = FallbackLanguageModel(
            primary: RecordingLanguageModel(managed, label: "local", log: callLog),
            secondary: RecordingLanguageModel(fallback, label: "apple", log: callLog))
        return Chain(model: chain, local: managed, mlx: mlx)
    }

    /// Whether this process can run MLX at all (the Metal kernels are bundled).
    public static var runtimeAvailable: Bool { MetalLibraryLocator.find() != nil }
}
