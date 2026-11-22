import Foundation
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import MurmurCore

/// Owns one loaded MLX model, its tokenizer and the cache of prefilled instruction prefixes (`PrefixCacheStore`).
///
/// Runs on its own serial dispatch queue: MLX evaluation is synchronous GPU work, so it gets a
/// dedicated thread instead of blocking a cooperative-pool thread, and every MLX call happens on
/// the same queue. All `MLXArray`/`KVCache` state stays inside this actor.
actor MLXEngine {
    struct Settings: Sendable {
        var directory: URL
        /// Cached prefixes of cleanup's own prompts (`PrefixSlot.pinned`): the plain prompt and the three register
        /// lines. Nothing but another cleanup prompt evicts one.
        var pinnedPrefixCapacity = 4
        /// Cached prefixes of every other prompt a person waits on (`PrefixSlot.transient`): actions, voice edit,
        /// restyle. Background calls use neither (`PrefixPolicy.background`).
        var transientPrefixCapacity = 2
        /// Quantize prefix KV caches to this many bits (4 or 8); nil keeps them in the model dtype.
        var kvCacheBits: Int?
        /// Prefill chunk size for instruction prefixes; cancellation is checked between chunks.
        var prefillChunk = 256
        /// Prompts longer than twice this are prefilled in chunks of this size before decoding
        /// (`prefillLeading`); the decoder's first pass then sees only the last chunk.
        var promptChunk = 512
        /// The same for work no one waits on (`PrefixPolicy.background`: a meeting summary or extract). Smaller, so a
        /// dictation that cancels the call waits for at most one such forward pass (`promptPlan`).
        var backgroundPromptChunk = 128
        /// MLX's GPU buffer cache limit (it otherwise grows toward available memory).
        var bufferCacheLimitBytes = 256 * 1024 * 1024
        /// Grammar for the tools-v1 envelope (`ToolEnvelopeGrammar`).
        var toolGrammar = ToolEnvelopeGrammar.Mode.strict
        /// SPIKE (FINETUNE.md §3.32): a PEFT LoRA adapter applied unfused after load; nil = none.
        var adapterDirectory: URL?
        /// SPIKE: `all` = the adapter is on for every call; `tools` = only for tools-v1 envelope calls
        /// (the task-arithmetic layout: fused cleanup model + a tools adapter toggled per call).
        var adapterScope = "all"
        /// Sealed weights (`weights-*.hse` in `directory`): the model id the key is filed under, and where to get
        /// the key. Plain models ignore both.
        var sealedModelID: String?
        var sealedKeys: (any SealedKeySource)?
        /// How long a sealed model that had no key waits before it asks for one again.
        var keyRetryDelay = Duration.seconds(30)
    }

    /// Per-call measurements, for logs and `model-diag`.
    struct CallReport: Sendable {
        enum PrefixUse: String, Sendable {
            case hit, built, partial, none, disabled
        }

        var json: String
        var prefixUse: PrefixUse
        var prefixTokens: Int
        var promptTokens: Int
        var generatedTokens: Int
        var forcedTokens: Int
        var loadMilliseconds: Double
        var prefixMilliseconds: Double
        var timeToFirstTokenMilliseconds: Double
        var totalMilliseconds: Double
        /// Tokens in the answer by `EarlyTokens.windowMilliseconds` after the call started
        /// (sampled and forced together), and the sampled ones alone.
        var earlyTokens: Int
        var earlySampledTokens: Int
        /// Prompt-lookup speculation counters; nil when the call decoded without it.
        var speculation: SpeculationStats?
        /// Each prompt chunk fed before decoding (`prefillLeading`), in milliseconds, and its size in tokens.
        var leadChunkMilliseconds: [Double] = []
        var leadChunkTokens = 0
    }

    private final class CachedPrefix {
        let tokens: [Int]
        let cache: [KVCache]

        init(tokens: [Int], cache: [KVCache]) {
            self.tokens = tokens
            self.cache = cache
        }
    }

    private final class Loaded {
        let context: ModelContext
        let endTokens: Set<Int>
        let grammars: GrammarCache
        /// The weight arrays and their byte spans, read once on first use (`memoryRegions`).
        var weights: (arrays: [MLXArray], spans: [(address: UInt, bytes: Int)])?

        init(context: ModelContext, endTokens: Set<Int>, grammars: GrammarCache) {
            self.context = context
            self.endTokens = endTokens
            self.grammars = grammars
        }
    }

    private enum LoadState {
        case idle
        case loading
        case loaded(Loaded)
        case failed(String)
    }

    /// Carries the freshly loaded (non-Sendable) context from the load task into the actor.
    struct Handoff: @unchecked Sendable {
        let result: Result<ModelContext, Error>
        let milliseconds: Double
    }

    private let queue = DispatchSerialQueue(label: "app.hushy.mlx", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private(set) var settings: Settings
    private var state = LoadState.idle
    private var prefixes: PrefixCacheStore<CachedPrefix>
    /// Measurement only (`murmur-eval intent-app --ab argmax`): decode the old way, masking each row before argmax.
    private var measurementMasksFirst = false
    func setMeasurementMasksFirst(_ on: Bool) { measurementMasksFirst = on }
    /// Measurement only (`murmur-eval prefill-yield`): the background prompt chunk for the calls that follow.
    func setMeasurementBackgroundPromptChunk(_ tokens: Int) { settings.backgroundPromptChunk = max(1, tokens) }
    private(set) var loadMilliseconds: Double = 0
    /// This chip's forward-pass cost curve for speculation (`Speculation/`), measured once.
    private(set) var passCosts: PassCostModel?
    private let loadModel: @Sendable (URL) async -> Handoff
    private(set) var loadTask: Task<Void, Never>?

    init(settings: Settings, loadModel: (@Sendable (URL) async -> Handoff)? = nil) {
        self.settings = settings
        self.prefixes = PrefixCacheStore(
            pinnedCapacity: settings.pinnedPrefixCapacity, transientCapacity: settings.transientPrefixCapacity)
        let sealed = settings.sealedKeys.map { (settings.sealedModelID ?? settings.directory.lastPathComponent, $0) }
        self.loadModel = loadModel ?? { directory in await MLXEngine.loadModel(directory, sealed: sealed) }
    }

    var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    func loadForMeasurement() async throws { _ = try await loaded() }

    // MARK: - Loading

    /// Loads the model once. Waiting is cancellable (the load itself is not: it finishes in the
    /// background so the next call is warm).
    private func loaded() async throws -> Loaded {
        try Task.checkCancellation()
        // A failed load is tried again: the model in front of the engine decides when (`MLXHealth`).
        if case .failed = state { startLoad() }
        if case .idle = state {
            // A sealed model whose key was just refused is not asked again at once: dictation must not wait on
            // the network for a key that is not there.
            if let until = keyRetryNotBefore, ContinuousClock.now < until, let reason = keyFailureReason {
                throw LanguageModelError.busy(reason)
            }
            startLoad()
        }
        let generation = loadGeneration
        while true {
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
            switch state {
            case .loaded(let loaded): return loaded
            case .failed(let reason): throw LanguageModelError.unavailable(reason)
            case .idle:
                if let reason = keyFailureReason, keyRetryNotBefore != nil { throw LanguageModelError.busy(reason) }
                throw CancellationError()
            case .loading: try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Bumped by `unload` and by each `startLoad`, so a load that finishes after it was
    /// superseded does not install its model or mark the replacement failed.
    private var loadGeneration = 0

    /// Set when a sealed model could not get its key: the reason, and when to try again.
    private var keyFailureReason: String?
    private var keyRetryNotBefore: ContinuousClock.Instant?
    private func startLoad() {
        keyFailureReason = nil
        keyRetryNotBefore = nil
        state = .loading
        loadGeneration += 1
        let generation = loadGeneration
        let directory = settings.directory
        let loadModel = loadModel
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let handoff = await loadModel(directory)
            await self?.finishLoad(handoff, generation: generation)
        }
    }

    nonisolated static func loadModel(_ directory: URL, sealed: (modelID: String, keys: any SealedKeySource)? = nil) async -> Handoff {
        let start = ContinuousClock.now
        let result: Result<ModelContext, Error>
        do {
            if SealedFormat.containsSealedWeights(in: directory) {
                guard let sealed else { throw SealedModelLoader.Failure.noKeySource }
                result = .success(try await SealedModelLoader.load(directory: directory, modelID: sealed.modelID, keys: sealed.keys))
            } else {
                let loadDirectory = try MLXShardMaterializer.loadDirectory(directory)
                result = .success(try await LLMModelFactory.shared.load(from: loadDirectory, using: TokenizerLoaderBridge()))
            }
        } catch {
            result = .failure(error)
        }
        return Handoff(result: result, milliseconds: Self.milliseconds(since: start))
    }

    private func finishLoad(_ handoff: Handoff, generation: Int) {
        guard generation == loadGeneration else { return }
        switch handoff.result {
        case .success(let context):
            Memory.cacheLimit = settings.bufferCacheLimitBytes
            touchedMLX = true
            let start = ContinuousClock.now
            let endTokens = Self.endTokens(context)
            if let adapter = settings.adapterDirectory {
                do {
                    let summary = try PEFTAdapterLoader.load(adapter, into: context.model)
                    adapterLayers = context.model.namedModules().compactMap { $0.1 as? LoRALayer }
                    MLXLog.model.info("mlx adapter loaded tensors=\(summary.tensors, privacy: .public) params=\(summary.parameters, privacy: .public) rank=\(summary.rank, privacy: .public)")
                } catch {
                    state = .failed("MLX adapter failed to load: \(error)")
                    return
                }
            }
            do {
                // The grammar vocabulary is extracted once per model (~0.1–0.3 s for a 250k vocab).
                let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
                let eos = context.tokenizer.eosTokenId ?? endTokens.min() ?? 0
                let grammarTokenizer = try GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType, eosTokenId: Int32(eos))
                state = .loaded(Loaded(
                    context: context, endTokens: endTokens,
                    grammars: GrammarCache(
                        tokenizer: grammarTokenizer, hostTokenizer: context.tokenizer, toolGrammar: settings.toolGrammar)))
            } catch {
                state = .failed("MLX model failed to load: grammar vocabulary (\(error))")
                MLXLog.model.error("mlx grammar vocab failed: \(String(describing: error), privacy: .public)")
                return
            }
            loadMilliseconds = handoff.milliseconds + Self.milliseconds(since: start)
            MLXLog.model.info("mlx load ok ms=\(Int(self.loadMilliseconds), privacy: .public)")
        case .failure(let error):
            if let failure = error as? SealedModelLoader.Failure, case .keyUnavailable = failure {
                // Not a broken model: back to idle, and the next call after a short wait asks for the key again.
                keyFailureReason = failure.localizedDescription
                keyRetryNotBefore = ContinuousClock.now + settings.keyRetryDelay
                state = .idle
                MLXLog.model.error("mlx sealed model has no key: \(failure.localizedDescription, privacy: .public)")
                return
            }
            state = .failed("MLX model failed to load: \(error.localizedDescription)")
            MLXLog.model.error("mlx load failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether a load reached MLX. Until then there is no buffer cache to clear, and touching `Memory` would start
    /// MLX's Metal device (in tests with a fake loader, that fails for want of the metallib).
    private var touchedMLX = false

    /// Drops the model, its prefixes and MLX's buffer cache.
    func unload() {
        loadGeneration += 1
        prefixes.removeAll()
        adapterLayers = []
        state = .idle
        if touchedMLX { Memory.clearCache() }
    }

    // MARK: - Memory residency

    /// The loaded weights and cached prefixes as raw byte ranges (nil until a load has finished). The returned
    /// object retains the arrays, so the memory stays mapped while a page touch runs even if `unload` happens.
    func memoryRegions() -> ModelMemoryRegions? {
        guard case .loaded(let loaded) = state else { return nil }
        if loaded.weights == nil {
            let arrays = loaded.context.model.parameters().flattened().map(\.1)
            loaded.weights = (arrays, arrays.compactMap(Self.span))
        }
        guard let weights = loaded.weights else { return nil }
        let prefixArrays = prefixes.allEntries.flatMap { entry in entry.cache.flatMap { $0.state } }
        let spans = weights.spans + prefixArrays.compactMap(Self.span)
        return ModelMemoryRegions(spans: spans, owner: RetainedArrays(weights.arrays + prefixArrays))
    }

    private final class RetainedArrays {
        let arrays: [MLXArray]
        init(_ arrays: [MLXArray]) { self.arrays = arrays }
    }

    private static func span(_ array: MLXArray) -> (address: UInt, bytes: Int)? {
        let data = array.asData(access: .noCopy).data
        return data.withUnsafeBytes { raw in raw.baseAddress.map { (UInt(bitPattern: $0), raw.count) } }
    }

    // MARK: - Prefixes

    /// Prefills `system`'s prefix if it is not cached yet and compiles `schema`'s grammar
    /// (prewarm / `prefixCache(instructions:)`), so the next call pays neither.
    /// SPIKE: LoRA layers of a loaded adapter, cached for a cheap per-call toggle.
    private var adapterLayers: [LoRALayer] = []

    /// The per-call adapter toggle. `tools`: on only for the tools-v1 envelope (SPIKE). `meeting-records`: the meeting
    /// extract adapter (Run A), on only for `MeetingExtractPrompt.schemaName` calls, so no dictation, summary or prefix
    /// build ever runs with it. A nil schema (a call that builds no prefix) is never an adapter call. Called after
    /// `loaded()` and before any forward pass, with no suspension in between, so a call always runs in its own scope.
    private func applyAdapterScope(_ schema: GenerationSchemaSpec?) {
        guard !adapterLayers.isEmpty else { return }
        let enabled: Bool
        switch settings.adapterScope {
        case "tools": enabled = schema?.name == VoiceToolCatalog.envelopeSchema.name
        case Self.meetingRecordsScope: enabled = schema?.name == MeetingExtractPrompt.schemaName
        default: return
        }
        guard adapterLayers.first?.loraEnabled != enabled else { return }
        for layer in adapterLayers { layer.loraEnabled = enabled }
    }

    static let meetingRecordsScope = "meeting-records"

    func warm(system: String, schema: GenerationSchemaSpec, calibrateSpeculation: Bool = false) async throws {
        let loaded = try await loaded()
        applyAdapterScope(schema)
        let built = try prefix(for: system, schema: schema, loaded: loaded, policy: .warmUp)
        if calibrateSpeculation, passCosts == nil, let entry = built?.0 {
            passCosts = MLXSpeculativeContext.calibrate(model: loaded.context.model, cache: entry.cache.map { $0.copy() }) ?? .m4ProDefault
        }
        _ = try loaded.grammars.withConstraint(for: schema) { constraint, _ in try constraint.computeMask() }
    }

    /// One forward pass on a copy of the cached instructions. The response cache stays untouched.
    func touchCachedPrefix(system: String, schema: GenerationSchemaSpec) async throws {
        let loaded = try await loaded()
        try Task.checkCancellation()
        applyAdapterScope(schema)
        guard let prefix = try prefix(for: system, schema: schema, loaded: loaded, policy: .dictation)?.0,
              let token = prefix.tokens.last else { return }
        // Outside `withError` an MLX error (out of memory at key-down) ends the process; here it is thrown, and the caller
        // drops the warm-up.
        try withError {
            let cache = prefix.cache.map { $0.copy() }
            _ = loaded.context.model(MLXArray([Int32(token)])[.newAxis], cache: cache)
            eval(cache)
        }
    }

    /// Feeds `count` prefix tokens to `step` in chunks of `chunk`. Unless `policy` is `.warmUp`, a cancelled caller stops
    /// it before the next chunk with `CancellationError`, after `rebuild` under `.dictation`.
    static func prefill(
        count: Int, chunk: Int, policy: PrefixPolicy, rebuild: () -> Void, step: (Range<Int>) throws -> Void
    ) throws {
        var offset = 0
        while offset < count {
            if policy != .warmUp, Task.isCancelled {
                if policy == .dictation { rebuild() }
                throw CancellationError()
            }
            let end = min(offset + chunk, count)
            try step(offset..<end)
            offset = end
        }
    }

    /// The cached prefix of `system` and how long it took to build (0 on a hit); nil for a call that does not use the
    /// cache (`PrefixPolicy.background`) or whose prompt has no prefix. `schema` picks the partition (`PrefixSlot`);
    /// call it after `applyAdapterScope(schema)`, so the key carries this call's adapter state.
    private func prefix(
        for system: String, schema: GenerationSchemaSpec, loaded: Loaded, policy: PrefixPolicy
    ) throws -> (CachedPrefix, Double)? {
        let adapterOn = ["tools", Self.meetingRecordsScope].contains(settings.adapterScope) && adapterLayers.first?.loraEnabled == true
        let (key, slot) = PrefixKey.filing(system: system, schema: schema, adapterOn: adapterOn)
        var elapsed = 0.0
        let resolved = try prefixes.resolve(key, slot: slot, policy: policy) {
            let start = ContinuousClock.now
            guard let entry = try buildPrefix(for: system, schema: schema, loaded: loaded, policy: policy) else { return nil }
            elapsed = Self.milliseconds(since: start)
            return entry
        }
        guard let resolved else { return nil }
        if resolved.built {
            MLXLog.model.info("mlx prefix built tokens=\(resolved.entry.tokens.count, privacy: .public) ms=\(Int(elapsed), privacy: .public) slot=\(slot == .pinned ? "pinned" : "transient", privacy: .public) cached=\(self.prefixes.count, privacy: .public)")
        }
        return (resolved.entry, elapsed)
    }

    private func buildPrefix(
        for system: String, schema: GenerationSchemaSpec, loaded: Loaded, policy: PrefixPolicy
    ) throws -> CachedPrefix? {
        let tokens = try prefixTokens(system: system, tokenizer: loaded.context.tokenizer)
        guard !tokens.isEmpty else { return nil }
        let model = loaded.context.model
        var cache = try model.newCache(parameters: nil)
        try withError {
            try Self.prefill(
                count: tokens.count, chunk: settings.prefillChunk, policy: policy,
                rebuild: { Task { try? await self.warm(system: system, schema: schema) } }
            ) { range in
                _ = model(MLXArray(tokens[range].map(Int32.init))[.newAxis], cache: cache)
                eval(cache)
            }
        }
        if let bits = settings.kvCacheBits {
            try withError {
                maybeQuantizeKVCache(cache: &cache, kvBits: bits)
                eval(cache)
            }
        }
        return CachedPrefix(tokens: tokens, cache: cache)
    }

    /// The prompt tokens every call with this system text shares: the longest common prefix of the
    /// chat template rendered with two different user messages (so it ends right where user
    /// content starts, whatever the template adds around it).
    private func prefixTokens(system: String, tokenizer: any MLXLMCommon.Tokenizer) throws -> [Int] {
        let a = try render(system: system, user: "A", tokenizer: tokenizer)
        let b = try render(system: system, user: "Z", tokenizer: tokenizer)
        return Array(a.prefix(PrefixReuse.commonPrefixLength(a, b)))
    }

    private func render(system: String, user: String, tokenizer: any MLXLMCommon.Tokenizer) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: [["role": "system", "content": system], ["role": "user", "content": user]],
            tools: nil, additionalContext: ["enable_thinking": false])
    }

    // MARK: - Generation

    func respond(
        system: String, prompt: String, schema: GenerationSchemaSpec, temperature: Float?, usePrefixCache: Bool,
        options: LanguageModelOptions, speculation: SpeculationSettings? = nil
    ) async throws -> CallReport {
        let policy = PrefixPolicy(options)
        let start = ContinuousClock.now
        let wasLoaded = isLoaded
        let loaded = try await loaded()
        let loadMs = wasLoaded ? 0 : Self.milliseconds(since: start)
        try Task.checkCancellation()
        applyAdapterScope(schema)

        let tokenizer = loaded.context.tokenizer
        let full = try render(system: system, user: prompt, tokenizer: tokenizer)
        var cache: [KVCache]
        var suffix = full
        var use = CallReport.PrefixUse.disabled
        var prefixMs = 0.0
        var prefixCount = 0
        if usePrefixCache, let built = try prefix(for: system, schema: schema, loaded: loaded, policy: policy) {
            let (prefix, builtMs) = built
            prefixMs = builtMs
            switch PrefixReuse.plan(prefix: prefix.tokens, prompt: full) {
            case .full(let suffixStart):
                cache = prefix.cache.map { $0.copy() }
                suffix = Array(full[suffixStart...])
                use = builtMs > 0 ? .built : .hit
                prefixCount = suffixStart
            case .partial(let length) where canTrimPromptCache(prefix.cache):
                cache = prefix.cache.map { $0.copy() }
                trimPromptCache(cache, numTokens: prefix.tokens.count - length)
                suffix = Array(full[length...])
                use = .partial
                prefixCount = length
            case .partial, .none:
                cache = try loaded.context.model.newCache(parameters: nil)
                use = .none
            }
        } else {
            cache = try loaded.context.model.newCache(parameters: nil)
        }

        let promptCount = suffix.count
        let plan = Self.promptPlan(count: suffix.count, policy: policy, settings: settings)
        let leadChunks = try prefillLeading(suffix, plan: plan, policy: policy, model: loaded.context.model, cache: cache)
        suffix = Array(suffix[plan.lead...])
        var firstTokenAt: ContinuousClock.Instant?
        var early = EarlyTokenRecorder(start: start)
        let answerBudget = Self.maxAnswerTokens(promptTokens: full.count - prefixCount, schemaName: schema.name)
        var speculationStats: SpeculationStats?
        let result: GuidedJSONDecoder.Result
        if let speculation, MLXSpeculativeContext.supports(cache) {
            if passCosts == nil { passCosts = MLXSpeculativeContext.calibrate(model: loaded.context.model, cache: cache) ?? .m4ProDefault }
            let costs = passCosts ?? .m4ProDefault
            // Prompt-lookup speculation (Speculation/): drafts are copied from the user's part of the prompt.
            let userStart = use == .disabled || use == .none ? try prefixTokens(system: system, tokenizer: tokenizer).count : prefixCount
            (result, speculationStats) = try loaded.grammars.withConstraint(for: schema) { constraint, commits in
                let context = MLXSpeculativeContext(model: loaded.context.model, cache: cache)
                var decoder = SpeculativeJSONDecoder(
                    model: context, constraint: constraint,
                    endTokens: loaded.endTokens, grammarVocabSize: loaded.grammars.tokenizer.vocabSize,
                    temperature: temperature, maxSampledTokens: answerBudget, settings: speculation,
                    costs: costs)
                decoder.commits = commits
                decoder.texts = TokenizerTexts(tokenizer)
                decoder.onFirstToken = { firstTokenAt = ContinuousClock.now }
                decoder.onEmit = { early.record(sampled: $0, forced: $1) }
                var (result, stats) = try decoder.decode(prompt: suffix, draftSource: Array(full[min(userStart, full.count)...]))
                for timing in context.passTimings.dropFirst() { stats.passMilliseconds[timing.tokens, default: []].append(timing.milliseconds) }
                return (result, stats)
            }
        } else {
            let reusesArgmax = !measurementMasksFirst
            result = try loaded.grammars.withConstraint(for: schema) { constraint, commits in
                var decoder = GuidedJSONDecoder(
                    model: MLXTokenContext(model: loaded.context.model, cache: cache, reusesArgmax: reusesArgmax),
                    constraint: constraint,
                    endTokens: loaded.endTokens, grammarVocabSize: loaded.grammars.tokenizer.vocabSize,
                    temperature: temperature, maxSampledTokens: answerBudget)
                decoder.commits = commits
                decoder.onFirstToken = { firstTokenAt = ContinuousClock.now }
                decoder.onEmit = { early.record(sampled: $0, forced: $1) }
                return try decoder.decode(prompt: suffix)
            }
        }
        let json = tokenizer.decode(tokenIds: result.tokens, skipSpecialTokens: true)

        let total = Self.milliseconds(since: start)
        let ttft = firstTokenAt.map { Self.milliseconds(from: start, to: $0) } ?? total
        let earlyCount = early.count
        let report = CallReport(
            json: json, prefixUse: use, prefixTokens: prefixCount, promptTokens: promptCount,
            generatedTokens: result.sampled, forcedTokens: result.forced, loadMilliseconds: loadMs, prefixMilliseconds: prefixMs,
            timeToFirstTokenMilliseconds: ttft, totalMilliseconds: total,
            earlyTokens: earlyCount.total, earlySampledTokens: earlyCount.sampled, speculation: speculationStats,
            leadChunkMilliseconds: leadChunks, leadChunkTokens: plan.chunk)
        if let speculationStats { Self.log(speculationStats) }
        MLXLog.model.info(
            "mlx call prefix=\(use.rawValue, privacy: .public) prefixTokens=\(prefixCount, privacy: .public) promptTokens=\(promptCount, privacy: .public) genTokens=\(result.sampled, privacy: .public) forcedTokens=\(result.forced, privacy: .public) loadMs=\(Int(loadMs), privacy: .public) prefixMs=\(Int(prefixMs), privacy: .public) ttftMs=\(Int(ttft), privacy: .public) totalMs=\(Int(total), privacy: .public) earlyTokens=\(earlyCount.total, privacy: .public) earlySampled=\(earlyCount.sampled, privacy: .public) leadChunks=\(leadChunks.count, privacy: .public)x\(plan.chunk, privacy: .public) leadChunkMaxMs=\(Int(leadChunks.max() ?? 0), privacy: .public)")
        return report
    }

    /// Measurement only (`murmur-eval intent-run`): the same load, chat-template rendering, end tokens
    /// and forward pass as `respond`, but greedy with no grammar and no prefix cache, the way
    /// `mlx_lm.generate` runs a model, so a converted model's answers can be compared with Python's.
    /// `json` is the raw answer with its special tokens (thinking channels included, if any).
    func respondUnconstrained(system: String, prompt: String, maxTokens: Int) async throws -> CallReport {
        let start = ContinuousClock.now
        let wasLoaded = isLoaded
        let loaded = try await loaded()
        applyAdapterScope(nil)
        let loadMs = wasLoaded ? 0 : Self.milliseconds(since: start)
        let full = try render(system: system, user: prompt, tokenizer: loaded.context.tokenizer)
        let cache = try loaded.context.model.newCache(parameters: nil)
        let plan = Self.promptPlan(count: full.count, policy: .dictation, settings: settings)
        _ = try prefillLeading(full, plan: plan, policy: .dictation, model: loaded.context.model, cache: cache)
        var pending = Array(full[plan.lead...])
        let context = MLXTokenContext(model: loaded.context.model, cache: cache)
        var output: [Int] = []
        var firstTokenAt: ContinuousClock.Instant?
        while output.count < maxTokens {
            try Task.checkCancellation()
            let token = try context.append(pending).choose(mask: nil, grammarVocabSize: 0, temperature: nil)
            if firstTokenAt == nil { firstTokenAt = .now }
            if loaded.endTokens.contains(token) { break }
            output.append(token)
            pending = [token]
        }
        let total = Self.milliseconds(since: start)
        return CallReport(
            json: loaded.context.tokenizer.decode(tokenIds: output, skipSpecialTokens: false), prefixUse: .disabled,
            prefixTokens: 0, promptTokens: full.count, generatedTokens: output.count, forcedTokens: 0,
            loadMilliseconds: loadMs, prefixMilliseconds: 0,
            timeToFirstTokenMilliseconds: firstTokenAt.map { Self.milliseconds(from: start, to: $0) } ?? total,
            totalMilliseconds: total, earlyTokens: 0, earlySampledTokens: 0, speculation: nil)
    }

    /// Measurement only (`murmur-eval draft-accept`): the answer `answer` (JSON text) as tokens, and this model's
    /// unmasked greedy pick at each of its positions when fed the prompt and the answer's earlier tokens.
    func teacherForcedPicks(system: String, prompt: String, answer: String) async throws -> (answer: [Int], picks: [Int]) {
        let loaded = try await loaded()
        applyAdapterScope(nil)
        let tokenizer = loaded.context.tokenizer
        let promptTokens = try render(system: system, user: prompt, tokenizer: tokenizer)
        let answerTokens = tokenizer.encode(text: answer, addSpecialTokens: false)
        guard let last = promptTokens.last, !answerTokens.isEmpty else { return (answerTokens, []) }
        let cache = try loaded.context.model.newCache(parameters: nil)
        let picks: [Int] = try withError {
            let lead = Array(promptTokens.dropLast())
            var offset = 0
            while offset < lead.count {
                let end = min(offset + settings.promptChunk, lead.count)
                _ = loaded.context.model(MLXArray(lead[offset..<end].map(Int32.init))[.newAxis], cache: cache)
                eval(cache)
                offset = end
            }
            let fed = [last] + answerTokens.dropLast()
            let output = loaded.context.model(MLXArray(fed.map(Int32.init))[.newAxis], cache: cache)
            let best = argMax(output[0], axis: -1)
            eval(best)
            return best.asArray(Int32.self).map(Int.init)
        }
        return (answerTokens, picks)
    }

    /// MLX's own allocator counters in bytes (Metal buffers included), for measurement reports.
    nonisolated static func memoryBytes() -> (active: Int, peak: Int) {
        (Memory.activeMemory, Memory.peakMemory)
    }

    /// How a prompt reaches the model before the decoder's first pass: the first `lead` tokens in chunks of `chunk`,
    /// evaluating only the cache, then the rest (at most one chunk) as the decoder's first pass.
    ///
    /// - A dictation's prompt keeps `promptChunk` (512), fed in chunks only past twice that: one forward pass is
    ///   cheaper than four, and the dictation is the call being waited on.
    /// - A background prompt (`PrefixPolicy.background`: a summary or an extract, up to about 6k tokens) goes in
    ///   chunks of `backgroundPromptChunk` (128) once it is longer than one, and the decoder's first pass sees at most
    ///   one such chunk. The call checks for cancellation before every chunk and every decoded token, so a dictation
    ///   that cancels it waits for at most one 128-token forward pass (meetings schema freeze section 8, "Preemption
    ///   latency"), never a 512-token one.
    struct PromptPlan: Equatable {
        let chunk: Int
        let lead: Int
    }

    static func promptPlan(count: Int, policy: PrefixPolicy, settings: Settings) -> PromptPlan {
        if policy == .background {
            let chunk = max(1, settings.backgroundPromptChunk)
            return PromptPlan(chunk: chunk, lead: count > chunk ? count - chunk : 0)
        }
        let chunk = max(1, settings.promptChunk)
        return PromptPlan(chunk: chunk, lead: count > chunk * 2 ? count - chunk : 0)
    }

    /// Feeds the first `plan.lead` tokens of a long prompt (a meeting transcript) in chunks, evaluating only the
    /// cache; the caller hands the rest to the decoder. Feeding it all at once would make the first forward pass
    /// build a [tokens × vocabulary] logits matrix — about 6 GB for a 12k-token prompt with Qwen3.5's 248k
    /// vocabulary — to read one row of it. A cancelled caller stops before the next chunk (`prefill`). Returns each
    /// chunk's milliseconds.
    private func prefillLeading(
        _ tokens: [Int], plan: PromptPlan, policy: PrefixPolicy, model: any MLXLMCommon.LanguageModel, cache: [KVCache]
    ) throws -> [Double] {
        guard plan.lead > 0 else { return [] }
        var timings: [Double] = []
        try withError {
            // A prompt is not a prefix: nothing to rebuild when the caller goes away.
            try Self.prefill(count: plan.lead, chunk: plan.chunk, policy: policy == .warmUp ? .dictation : policy, rebuild: {}) { range in
                let start = ContinuousClock.now
                _ = model(MLXArray(tokens[range].map(Int32.init))[.newAxis], cache: cache)
                eval(cache)
                timings.append(Self.milliseconds(since: start))
            }
        }
        return timings
    }

    /// Sampled-token budget for one answer: about twice the user prompt (cleanup answers are
    /// roughly the draft's length), never less than 96 tokens and never more than 2,048 (a
    /// meeting digest's merge answer — key points, decisions, item edits — can pass 1,024).
    static func maxAnswerTokens(promptTokens: Int) -> Int {
        min(2_048, max(96, promptTokens * 2 + 32))
    }

    /// The budget for one call by answer shape. A cleanup answer is the draft with fillers removed and
    /// punctuation added, so it is about as long as the user turn and never twice that: a runaway
    /// (a model repeating itself until the cap) must not be allowed to decode five times the answer's
    /// length, which at a loaded Mac's speed is the whole wait for the dictation (a cap of 136 tokens
    /// for an 18-word draft ran for the full 8 s ceiling). Other schemas keep `maxAnswerTokens(promptTokens:)`.
    static func maxAnswerTokens(promptTokens: Int, schemaName: String) -> Int {
        let general = maxAnswerTokens(promptTokens: promptTokens)
        if schemaName == MeetingExtractPrompt.schemaName { return min(general, meetingRecordsAnswerTokens) }
        guard Self.cleanupSchemaNames.contains(schemaName) else { return general }
        return min(general, max(Self.minimumCleanupAnswerTokens, promptTokens + promptTokens / 4 + 16))
    }

    /// Schemas whose answer is the dictation's own text (`SmartCleaner.Cleaned` and `.GroupCleaned`).
    static let cleanupSchemaNames: Set<String> = [SmartCleaner.cleanedSchema.name, SmartCleaner.groupCleanedSchema.name]
    static let minimumCleanupAnswerTokens = 48
    /// The meeting-extract eval's `MAX_NEW_TOKENS` (`scripts/meeting-extract/eval_ami_extract.py`).
    static let meetingRecordsAnswerTokens = 1_500

    // MARK: - Vocabulary helpers

    private static func endTokens(_ context: ModelContext) -> Set<Int> {
        var ids = context.configuration.eosTokenIds
        let tokenizer = context.tokenizer
        if let eos = tokenizer.eosTokenId { ids.insert(eos) }
        for token in context.configuration.extraEOSTokens.union(["<|im_end|>", "<|endoftext|>", "<|end_of_text|>", "<|eot_id|>"]) {
            if let id = tokenizer.convertTokenToId(token) { ids.insert(id) }
        }
        return ids
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        milliseconds(from: start, to: .now)
    }

    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let elapsed = end - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }
}
