import Foundation
import MurmurCore
import Synchronization

/// `LanguageModel` backed by an open model (Qwen3.5 / LFM2 / …, 4-bit MLX weights) run locally
/// with mlx-swift-lm — M2 of `docs/product/MODEL-STRATEGY.md`.
///
/// What it adds over the Apple adapter:
/// - **Prefix KV cache.** The system text (the caller's instructions plus the schema block) is
///   prefilled once per (model, text) and kept in a small LRU; each call copies that cache and
///   feeds only its own prompt tokens. `prewarm`/`prefixCache(instructions:)` build it ahead of
///   time. Loading another model means another instance, so caches never cross models.
/// - **Schema-constrained JSON** with XGrammar (`MLXGuidedGeneration`): each schema becomes a
///   compact EBNF grammar (fixed key order, no whitespace), so the answer always decodes and
///   jump-forward feeds the JSON structure without sampling (`GuidedJSONDecoder`). `.greedy` is
///   argmax; `.systemDefault` samples at 0.7.
///
/// Failure policy: anything that goes wrong throws (`LanguageModelError.unavailable`,
/// `.unsupportedSchema`, `.busy` when Metal can't allocate memory for the call, or
/// `CancellationError` when the caller's budget cancels the task), so the caller's rules path — or
/// a `FallbackLanguageModel` in front of Apple FM — takes over. A missing `mlx.metallib` makes the
/// model report `.unavailable`. A failed load, or `maxConsecutiveFailures` non-busy failures in a
/// row, pause it (`MLXHealth`): `.unavailable` for 30 s, then it is asked again, with a longer pause
/// after each failed try, up to 10 minutes. `.busy` is transient and never pauses it. There is no
/// `.refused`: an open model has no safety layer that declines text.
///
/// `LanguageModelOptions.textTransform` (Clean, custom modes): the answer is still decoded under
/// the schema's grammar, so it is exactly the one-string-field JSON the option's contract asks for
/// (the string is the rewrite, as generated); there are no content guardrails to relax, so the
/// option changes nothing else — same system text, same prefix cache, greedy when `.greedy`.
public final class MLXLanguageModel: LanguageModel {
    public struct Configuration: Sendable {
        /// A local directory with `config.json`, `*.safetensors` and tokenizer files (an
        /// mlx-community 4-bit conversion). Never downloaded here — M4/M5 own the download UX.
        public var directory: URL
        public var prefixCacheCapacity = 4
        /// Optional KV-cache quantization of cached prefixes (4 or 8 bits).
        public var kvCacheBits: Int?
        /// Off only for measurements ("what does the prefix cache buy?").
        public var usePrefixCache = true
        /// Prompt-lookup speculative decoding (`Speculation/`); nil = off. Same output either way.
        /// The app turns it on for every registry entry (`LocalCleanupBackend.configuration`).
        public var speculation: SpeculationSettings?
        /// Tools-v1 envelope grammar (`ToolEnvelopeGrammar.Mode`): `strict` (default) forces the
        /// chosen tool's unused arguments empty, limits enumerations and requires its required
        /// arguments; `aware` drops the last rule; `flat` is the generic grammar; `tool-first`
        /// is `strict` with the tool's own arguments first (needs a model trained on that order).
        public var toolGrammar = "strict"
        public var maxConsecutiveFailures = 3
        /// ISO 639-1 codes the model is trusted with for non-English cleanup.
        public var languages: Set<String> = ["en", "es", "fr", "de", "it", "pt"]
        /// Which system prompt cleanup calls use (see `PromptProfile`).
        public var promptProfile: PromptProfile = .production
        /// SPIKE (FINETUNE.md §3.32): a Hugging Face PEFT LoRA adapter directory applied *unfused* on
        /// top of `directory`'s 4-bit weights (`HUSHY_MLX_ADAPTER_DIR`). Measurement only.
        public var adapterDirectory: URL?
        /// SPIKE: `all` (default) or `tools` (`HUSHY_MLX_ADAPTER_SCOPE`); see `MLXEngine.Settings`.
        public var adapterScope = "all"
        /// Sealed models (`LocalModelEntry.sealing`): the id the model's key is filed under, and where the key
        /// comes from. Plain models leave both nil.
        public var sealedModelID: String?
        public var sealedKeys: (any SealedKeySource)?
        /// At key-down, page the weights back in from several threads before the GPU pass when macOS has
        /// compressed or swapped them out (`PageResidency`). Off only for the residency probe's baseline.
        public var restoresPagesOnKeyDown = true

        public init(directory: URL) {
            self.directory = directory
        }

        /// `HUSHY_MLX_MODEL_DIR`, for murmur-eval and manual runs.
        public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration? {
            guard let path = environment["HUSHY_MLX_MODEL_DIR"], !path.isEmpty else { return nil }
            var configuration = Configuration(directory: URL(fileURLWithPath: path, isDirectory: true))
            configuration.speculation = SpeculationSettings.fromEnvironment(environment["HUSHY_MLX_SPECULATE"])
            if let grammar = environment["HUSHY_MLX_TOOL_GRAMMAR"], !grammar.isEmpty { configuration.toolGrammar = grammar }
            if let adapter = environment["HUSHY_MLX_ADAPTER_DIR"], !adapter.isEmpty {
                configuration.adapterDirectory = URL(fileURLWithPath: adapter, isDirectory: true)
            }
            if let scope = environment["HUSHY_MLX_ADAPTER_SCOPE"], ["all", "tools"].contains(scope) { configuration.adapterScope = scope }
            if let bits = environment["HUSHY_MLX_KV_BITS"].flatMap(Int.init), [4, 8].contains(bits) {
                configuration.kvCacheBits = bits
            }
            if let profile = environment["HUSHY_MLX_PROMPT_PROFILE"].flatMap(PromptProfile.init(rawValue:)) {
                configuration.promptProfile = profile
            }
            return configuration
        }
    }

    /// The system prompt a model was trained for.
    /// - `production`: the caller's instructions verbatim plus the answer schema — zero-shot
    ///   models, and the Apple-FM-equivalent prompt.
    /// - `compact`: a model fine-tuned on `CompactCleanupPrompt` (scripts/finetune). Cleanup calls
    ///   get that short text instead of the ~2,000-token production instructions (the schema is
    ///   named inside it); every other call (rerank, actions, modes) keeps the production prompt.
    ///   Shorter prefix → smaller prefix cache and faster prefill; the answer grammar is unchanged.
    public enum PromptProfile: String, Sendable, CaseIterable {
        case production
        case compact
        case intent
        case compactV3 = "compact-v3"
        case compactV4 = "compact-v4"
        case compactV4PolishedBridge = "compact-v4-polished-bridge"
        /// Task 142 experiments, measurement only (never a registry entry): `CompactCleanupPrompt.Version.v2Context` and `.v2Paragraphs`.
        case compactContext = "compact-context"
        case compactParagraphs = "compact-paragraphs"
        case groupContract = "group-contract"
    }

    public struct Stats: Sendable, Equatable {
        public var calls = 0
        public var successes = 0
        public var failures = 0
        public var cancellations = 0
        public var prefixHits = 0
        public var prefixBuilds = 0
        public var prefixMisses = 0
        public var loadMilliseconds: Double = 0
    }

    /// One call's timings (see `respondMeasured`).
    public struct CallTimings: Sendable {
        public var prefixUse: String
        public var prefixTokens: Int
        public var promptTokens: Int
        public var generatedTokens: Int
        /// Tokens XGrammar forced by jump-forward (JSON structure; no sampling).
        public var forcedTokens: Int
        public var loadMilliseconds: Double
        public var prefixMilliseconds: Double
        public var timeToFirstTokenMilliseconds: Double
        public var totalMilliseconds: Double
        /// Tokens in the answer 250 ms after the call started (`EarlyTokens.windowMilliseconds`),
        /// sampled and forced together, and the sampled ones alone. A speed figure.
        public var earlyTokens: Int
        public var earlySampledTokens: Int
        /// Speculation counters when the call speculated.
        public var speculation: SpeculationStats?
    }

    private struct State {
        var stats = Stats()
        var lastCallTimings: CallTimings?
        var health: MLXHealth
        /// The schema last used with each instructions string, so `prewarm(instructions:)` can
        /// build the same prefix the next `respond` will look up.
        var schemaByInstructions: [String: GenerationSchemaSpec] = [:]
        /// Measurement only (`murmur-eval intent-app --speculate ab`): overrides `configuration.speculation` for
        /// every call until cleared, so one loaded model can run the same case with and without it.
        var measurementSpeculation: Bool?
    }

    public let configuration: Configuration
    private let engine: MLXEngine
    private let state: Mutex<State>
    public var lastCallTimings: CallTimings? { state.withLock { $0.lastCallTimings } }

    /// Measurement only: speculation on or off for the calls that follow (nil: the configuration's own setting).
    public func setMeasurementSpeculation(_ on: Bool?) { state.withLock { $0.measurementSpeculation = on } }

    /// Measurement only: decode the old way (mask each row on the CPU before argmax) for the calls that follow.
    public func setMeasurementMasksFirst(_ on: Bool) async { await engine.setMeasurementMasksFirst(on) }

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.state = Mutex(State(health: MLXHealth(maxConsecutiveFailures: configuration.maxConsecutiveFailures)))
        self.contextLength = Self.contextLength(in: configuration.directory) ?? LanguageModelContext.defaultTokens
        self.engine = MLXEngine(settings: .init(
            directory: configuration.directory, prefixCacheCapacity: configuration.prefixCacheCapacity,
            kvCacheBits: configuration.kvCacheBits,
            toolGrammar: ToolEnvelopeGrammar.Mode(rawValue: configuration.toolGrammar) ?? .strict,
            adapterDirectory: configuration.adapterDirectory, adapterScope: configuration.adapterScope,
            sealedModelID: configuration.sealedModelID, sealedKeys: configuration.sealedKeys))
    }

    public var identifier: String {
        let adapter = configuration.adapterDirectory.map { "+lora:\($0.lastPathComponent)" } ?? ""
        return "mlx:\(configuration.directory.lastPathComponent)\(adapter)"
    }

    /// The model's trained context length from `config.json` (`max_position_embeddings`, at the
    /// top level or under `text_config`), read once; `LanguageModelContext.defaultTokens` when
    /// the file doesn't say. Qwen3.5: 262,144.
    public var contextTokens: Int { contextLength }
    private let contextLength: Int

    static func contextLength(in directory: URL) -> Int? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = config["text_config"] as? [String: Any]
        return (config["max_position_embeddings"] as? Int) ?? (text?["max_position_embeddings"] as? Int)
    }

    public var stats: Stats { state.withLock { $0.stats } }

    public var availability: LanguageModelAvailability {
        if let reason = state.withLock({ $0.health.pauseReason(at: .now) }) { return .unavailable(reason: reason) }
        if let missing = Self.missingFiles(in: configuration.directory) { return .unavailable(reason: missing) }
        if MetalLibraryLocator.find() == nil {
            return .unavailable(reason: "mlx.metallib not found next to the executable (scripts/build-mlx-metallib.sh)")
        }
        return .available
    }

    public func supportsLanguage(_ languageCode: String) -> Bool {
        configuration.languages.contains(languageCode.lowercased())
    }

    public func prewarm(instructions: String) {
        guard isAvailable else { return }
        let schema = schema(for: instructions)
        let system = systemText(instructions: instructions, schema: schema)
        let calibrate = configuration.speculation != nil
        Task.detached(priority: .userInitiated) { [engine] in
            do {
                try await engine.warm(system: system, schema: schema, calibrateSpeculation: calibrate)
            } catch {
                MLXLog.model.error("mlx prewarm failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func prefixCache(instructions: String) async {
        guard isAvailable else { return }
        do {
            let schema = schema(for: instructions)
            try await engine.warm(system: systemText(instructions: instructions, schema: schema), schema: schema)
        } catch {
            MLXLog.model.error("mlx prefix cache failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func warmForDictation(instructions: String) async {
        guard isAvailable else { return }
        if configuration.restoresPagesOnKeyDown { await restorePages(why: "key-down", threads: WarmPolicy.keyDownThreads) }
        do {
            try await engine.touchCachedPrefix(system: systemText(instructions: instructions, schema: schema(for: instructions)))
        } catch is CancellationError {
            return
        } catch LanguageModelError.busy {
            return   // a sealed model waiting for its key: nothing to warm, and nothing to log on every key-down
        } catch {
            MLXLog.model.error("mlx key-down warm failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The loaded weights and cached prefixes as raw ranges (`ResidentModelMemory`); nil until loaded.
    public func memoryRegions() async -> ModelMemoryRegions? { await engine.memoryRegions() }

    /// Reads every page of the weights and cached prefixes from `threads` threads when fewer than
    /// `WarmPolicy.residentEnough` are in RAM. Not cancelled with the caller: the release needs those pages
    /// anyway. From the compressor it measured no slower than the GPU pass faulting them (342 vs 421 ms), and it
    /// reads swapped pages in parallel. A resident model costs one sampled `mincore` pass (about 2 ms).
    @discardableResult
    public func restorePages(why: String, threads: Int) async -> PageResidency.TouchReport? {
        guard let regions = await engine.memoryRegions() else { return nil }
        let before = PageResidency.sample(regions, stride: PageResidency.sampleStride(regions))
        guard before.fraction < WarmPolicy.residentEnough else { return nil }
        let report = await Task.detached(priority: .userInitiated) {
            PageResidency.touch(regions, threads: threads)
        }.value
        MLXLog.model.notice("mlx pages restored why=\(why, privacy: .public) before=\(before.fraction, format: .fixed(precision: 3)) pages=\(report.pages) threads=\(report.threads) ms=\(Int(report.milliseconds))")
        return report
    }

    public func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        try await respondMeasured(instructions: instructions, prompt: prompt, schema: schema, options: options).json
    }

    /// `respond` plus its timings (murmur-eval `model-diag --mlx-probe`); `usePrefixCache: false`
    /// prefills the whole prompt for this call, as a backend without a prefix cache must.
    /// `speculate` overrides `configuration.speculation` for this call (A/B measurements).
    public func respondMeasured(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions,
        usePrefixCache: Bool? = nil, speculate: Bool? = nil
    ) async throws -> (json: String, timings: CallTimings) {
        if case .unavailable(let reason) = availability { throw LanguageModelError.unavailable(reason) }
        let callStarted = ContinuousClock.now
        state.withLock {
            $0.stats.calls += 1
            $0.schemaByInstructions[instructions] = schema
        }
        do {
            let report = try await engine.respond(
                system: systemText(instructions: instructions, schema: schema), prompt: prompt, schema: schema,
                temperature: options.sampling == .greedy ? nil : 0.7,
                usePrefixCache: usePrefixCache ?? configuration.usePrefixCache, options: options,
                speculation: speculationSettings(override: speculate ?? state.withLock { $0.measurementSpeculation }))
            let loadMs = await engine.loadMilliseconds
            recordSuccess(report, loadMilliseconds: loadMs, callStarted: callStarted)
            let timings = Self.timings(report)
            state.withLock { $0.lastCallTimings = timings }
            return (report.json, timings)
        } catch is CancellationError {
            state.withLock { $0.stats.cancellations += 1 }
            throw CancellationError()
        } catch {
            let mapped = Self.classify(error)
            if case .busy = mapped {
                // Out of GPU memory right now: transient, like Apple FM under memory pressure.
                state.withLock { $0.stats.failures += 1 }
                MLXLog.model.error("mlx call busy: \(String(describing: error), privacy: .public)")
            } else {
                recordFailure(error, callStarted: callStarted)
            }
            throw mapped
        }
    }

    private static func timings(_ report: MLXEngine.CallReport) -> CallTimings {
        CallTimings(
            prefixUse: report.prefixUse.rawValue, prefixTokens: report.prefixTokens, promptTokens: report.promptTokens,
            generatedTokens: report.generatedTokens, forcedTokens: report.forcedTokens, loadMilliseconds: report.loadMilliseconds,
            prefixMilliseconds: report.prefixMilliseconds,
            timeToFirstTokenMilliseconds: report.timeToFirstTokenMilliseconds,
            totalMilliseconds: report.totalMilliseconds, earlyTokens: report.earlyTokens,
            earlySampledTokens: report.earlySampledTokens, speculation: report.speculation)
    }

    /// Measurement only (`murmur-eval intent-run`): `system` and `prompt` are the chat turns verbatim
    /// (no schema block appended, no prompt profile), greedy. With `schema` nil the answer is decoded
    /// without a grammar, up to `maxTokens`, and returned raw with its special tokens; with a schema it
    /// is decoded under that schema's grammar exactly as `respond` does (prefix cache and speculation
    /// per `configuration`). Not counted in `stats`, and a failure never disables the model.
    public func respondVerbatim(
        system: String, prompt: String, schema: GenerationSchemaSpec?, maxTokens: Int
    ) async throws -> (text: String, timings: CallTimings) {
        if case .unavailable(let reason) = availability { throw LanguageModelError.unavailable(reason) }
        do {
            let report: MLXEngine.CallReport
            if let schema {
                report = try await engine.respond(
                    system: system, prompt: prompt, schema: schema, temperature: nil,
                    usePrefixCache: configuration.usePrefixCache, options: .greedy,
                    speculation: speculationSettings(override: nil))
            } else {
                report = try await engine.respondUnconstrained(system: system, prompt: prompt, maxTokens: maxTokens)
            }
            return (report.json, Self.timings(report))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.classify(error)
        }
    }

    /// Measurement only (`murmur-eval draft-accept`): `answer` as tokens and this model's greedy pick at each of them,
    /// fed the chat and the answer so far (teacher forcing, no grammar).
    public func teacherForcedPicks(system: String, prompt: String, answer: String) async throws -> (answer: [Int], picks: [Int]) {
        try await engine.teacherForcedPicks(system: system, prompt: prompt, answer: answer)
    }

    /// MLX's allocator counters in bytes (active now, peak since launch), Metal buffers included.
    public static var allocatorMemoryBytes: (active: Int, peak: Int) { MLXEngine.memoryBytes() }

    /// Diagnostic load boundary for eval measurements; normal calls still load lazily.
    public func loadForMeasurement() async throws {
        if case .unavailable(let reason) = availability { throw LanguageModelError.unavailable(reason) }
        try await engine.loadForMeasurement()
    }

    /// Frees the model and its caches (memory pressure, idle unload — M4/M5 policy).
    public func unload() async {
        await engine.unload()
    }

    // MARK: - Prompt shape

    /// The system message: the caller's instructions, then the answer schema. Apple's framework
    /// injects the schema itself; here it is ordinary prompt text, and part of the cached prefix.
    public static func systemText(instructions: String, schema: GenerationSchemaSpec) -> String {
        """
        \(instructions)

        Reply with only a JSON object that conforms to this JSON schema (each field's description \
        says what goes in it):
        \(schema.json.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// The system text for this model's `promptProfile`: under `.compact`, cleanup instructions
    /// become `CompactCleanupPrompt` (which already names the `{"text": …}` answer); anything
    /// else, and every call under `.production`, is `systemText(instructions:schema:)`.
    func systemText(instructions: String, schema: GenerationSchemaSpec) -> String {
        Self.systemText(instructions: instructions, schema: schema, profile: configuration.promptProfile)
    }

    /// Shared with `HushyModelsRemote`, which sends the same system message to a GPU server.
    package static func systemText(instructions: String, schema: GenerationSchemaSpec, profile: PromptProfile) -> String {
        if profile == .intent, schema.name == SmartCleaner.cleanedSchema.name {
            return IntentCleanupPrompt.system(register: IntentRegister.detecting(in: instructions))
        }
        if profile == .groupContract, schema.name == SmartCleaner.groupCleanedSchema.name {
            return CompactCleanupPrompt.systemText(level: .clean, version: .groupContract)
        }
        let compactVersion: CompactCleanupPrompt.Version? = switch profile {
        case .compact: .v2
        case .compactV3: .v3
        case .compactV4: .v4
        case .compactV4PolishedBridge: .v4PolishedBridge
        case .compactContext: .v2Context
        case .compactParagraphs: .v2Paragraphs
        case .groupContract: nil
        case .intent: nil
        case .production: nil
        }
        if let compactVersion, schema.name == SmartCleaner.cleanedSchema.name,
           let compact = CompactCleanupPrompt.systemText(forInstructions: instructions, version: compactVersion) {
            return compact
        }
        return systemText(instructions: instructions, schema: schema)
    }

    /// The decoder's sampled-token budget for a user prompt of `promptTokens` tokens
    /// (`MLXEngine.maxAnswerTokens`); `HushyModelsRemote` sizes its requests from it.
    package static func answerTokenBudget(promptTokens: Int) -> Int {
        MLXEngine.maxAnswerTokens(promptTokens: promptTokens)
    }

    /// The schema last used with `instructions` (cleanup's `Cleaned` before any call).
    private func schema(for instructions: String) -> GenerationSchemaSpec {
        state.withLock { $0.schemaByInstructions[instructions] } ?? SmartCleaner.cleanedSchema
    }

    // MARK: - Bookkeeping

    private func recordSuccess(_ report: MLXEngine.CallReport, loadMilliseconds: Double, callStarted: ContinuousClock.Instant) {
        state.withLock {
            $0.stats.successes += 1
            $0.health.recordSuccess(callStarted: callStarted)
            $0.stats.loadMilliseconds = loadMilliseconds
            switch report.prefixUse {
            case .hit: $0.stats.prefixHits += 1
            case .built: $0.stats.prefixBuilds += 1
            case .partial, .none: $0.stats.prefixMisses += 1
            case .disabled: break
            }
        }
    }

    private func recordFailure(_ error: Error, callStarted: ContinuousClock.Instant) {
        // An answer that ran past its cap is the model's output, not its health: three runaways in a row must
        // not switch the model off for the rest of the process.
        var isRunaway = false
        if case LanguageModelError.malformedOutput = error { isRunaway = true }
        // A sealed model waiting for its key is not unhealthy: the key can arrive (sign-in, a fresh fetch).
        if case LanguageModelError.busy(let reason) = error, reason.hasPrefix(SealedModelLoader.keyUnavailablePrefix) { isRunaway = true }
        let countsAgainstHealth = !isRunaway
        var loadFailed = false
        if case LanguageModelError.unavailable(let reason) = error, reason.hasPrefix("MLX model failed to load") { loadFailed = true }
        let pause: Duration? = state.withLock {
            $0.stats.failures += 1
            guard countsAgainstHealth else { return nil }
            return $0.health.recordFailure(String(describing: error), loadFailed: loadFailed, callStarted: callStarted, at: .now)
        }
        MLXLog.model.error("mlx call failed: \(String(describing: error), privacy: .public) pausedSeconds=\(pause?.components.seconds ?? 0, privacy: .public)")
    }

    /// Maps an engine error onto the seam's failure classes: Metal allocation failures are `busy`
    /// (the system is short of memory — transient, says nothing about speed); everything else is
    /// `unavailable` unless it already is a `LanguageModelError`.
    static func classify(_ error: any Error) -> LanguageModelError {
        if let modelError = error as? LanguageModelError { return modelError }
        let text = String(describing: error).lowercased()
        let memory = ["unable to allocate", "insufficient memory", "out of memory", "outofmemory", "kiogpucommandbuffercallbackerroroutofmemory"]
        if memory.contains(where: text.contains) {
            return .busy("MLX out of GPU memory: \(error.localizedDescription)")
        }
        return .unavailable("MLX generation failed: \(error.localizedDescription)")
    }

    static func missingFiles(in directory: URL) -> String? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            return "no MLX model at \(directory.lastPathComponent) (config.json missing)"
        }
        let files = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        guard files.contains(where: { $0.hasSuffix(".safetensors") }) || SealedFormat.containsSealedWeights(in: directory) else {
            return "MLX model weights missing"
        }
        guard files.contains("tokenizer.json") || files.contains("tokenizer_config.json") else {
            return "MLX tokenizer missing"
        }
        return nil
    }
}

/// Where MLX will look for its Metal kernels (mirrors `mlx/backend/metal/device.cpp`): a
/// colocated `mlx.metallib` (or `Resources/mlx.metallib`) beside the executable, or
/// `default.metallib` in an `mlx-swift_Cmlx` SwiftPM bundle — beside the executable, or in the
/// app's `Contents/Resources` (where `scripts/build-app.sh` puts it: MLX searches every loaded
/// bundle's resources for `mlx-swift_Cmlx.bundle`). Without one, the first GPU op aborts the
/// process — so availability checks it first.
enum MetalLibraryLocator {
    static func find(executable: URL? = Bundle.main.executableURL, resources: URL? = Bundle.main.resourceURL) -> URL? {
        candidates(executable: executable, resources: resources).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func candidates(executable: URL?, resources: URL?) -> [URL] {
        var urls: [URL] = []
        if let directory = executable?.resolvingSymlinksInPath().deletingLastPathComponent() {
            urls += [
                directory.appendingPathComponent("mlx.metallib"),
                directory.appendingPathComponent("Resources/mlx.metallib"),
                directory.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
                directory.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib"),
                directory.appendingPathComponent("Resources/default.metallib"),
            ]
        }
        if let resources {
            urls += [
                resources.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
                resources.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib"),
            ]
        }
        return urls
    }
}
