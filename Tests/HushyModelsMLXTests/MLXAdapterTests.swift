import Foundation
import Testing
@testable import HushyModelsMLX
@testable import MurmurCore

@Suite("MLX adapter plumbing")
struct MLXAdapterTests {
    @Test("prefix LRU: hits refresh recency, inserts evict the least recently used")
    func lru() {
        var store = PrefixCacheStore<Int>(capacity: 2)
        store.insert(1, for: "a")
        store.insert(2, for: "b")
        #expect(store.entry(for: "a") == 1)
        let evicted = store.insert(3, for: "c")
        #expect(evicted == ["b"])
        #expect(store.entry(for: "b") == nil)
        #expect(store.keys == ["c", "a"])
        store.insert(4, for: "a")
        #expect(store.count == 2)
        #expect(store.entry(for: "a") == 4)
        store.removeAll()
        #expect(store.count == 0)
    }

    @Test("prefix reuse: full hit feeds only the suffix; divergence falls back")
    func reusePlan() {
        #expect(PrefixReuse.plan(prefix: [1, 2, 3], prompt: [1, 2, 3, 4, 5]) == .full(suffixStart: 3))
        #expect(PrefixReuse.plan(prefix: [1, 2, 3], prompt: [1, 2, 9, 4]) == .partial(length: 2))
        #expect(PrefixReuse.plan(prefix: [1, 2, 3], prompt: [7, 8]) == .none)
        // A prompt that *is* the prefix still leaves one token to feed.
        #expect(PrefixReuse.plan(prefix: [1, 2, 3], prompt: [1, 2, 3]) == .partial(length: 2))
        #expect(PrefixReuse.plan(prefix: [], prompt: [1]) == .none)
    }

    @Test("string budget scales with the prompt within [96, 2048]")
    func stringBudget() {
        #expect(MLXEngine.maxAnswerTokens(promptTokens: 10) == 96)
        #expect(MLXEngine.maxAnswerTokens(promptTokens: 100) == 232)
        #expect(MLXEngine.maxAnswerTokens(promptTokens: 5_000) == 2_048)
    }

    @Test("a cleanup answer is capped near the draft's length, so a runaway cannot decode several times its size")
    func cleanupBudgetIsTight() {
        let cleaned = SmartCleaner.cleanedSchema.name
        // An 18-word draft (52 prompt tokens) used to be allowed 136 tokens.
        #expect(MLXEngine.maxAnswerTokens(promptTokens: 52, schemaName: cleaned) == 52 + 13 + 16)
        #expect(MLXEngine.maxAnswerTokens(promptTokens: 52, schemaName: SmartCleaner.groupCleanedSchema.name) == 81)
        #expect(MLXEngine.maxAnswerTokens(promptTokens: 5, schemaName: cleaned) == 48)
        // A long cleanup never gets more than the general budget; other schemas keep it as it was.
        #expect(MLXEngine.maxAnswerTokens(promptTokens: 5_000, schemaName: cleaned) == 2_048)
        #expect(MLXEngine.maxAnswerTokens(promptTokens: 52, schemaName: "MeetingDigest") == 136)
    }

    @Test("the system text is instructions then the schema (both part of the cached prefix)")
    func systemText() {
        let text = MLXLanguageModel.systemText(instructions: "Clean it.", schema: SmartCleaner.cleanedSchema)
        #expect(text.hasPrefix("Clean it.\n\n"))
        #expect(text.hasSuffix(SmartCleaner.cleanedSchema.json.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test("compact prompt profile: cleanup gets the short trained prompt, everything else stays production")
    func compactProfile() {
        let clean = SmartCleaner.cleanupInstructions(confidenceGuided: false)
        let compact = MLXLanguageModel.systemText(instructions: clean, schema: SmartCleaner.cleanedSchema, profile: .compact)
        #expect(compact == CompactCleanupPrompt.systemText(level: .clean))
        let candidateInstructions = SmartCleaner.cleanupInstructions(confidenceGuided: false, localGrammar: true)
        #expect(MLXLanguageModel.systemText(instructions: candidateInstructions, schema: SmartCleaner.cleanedSchema, profile: .compact)
            == CompactCleanupPrompt.systemText(level: .clean, version: .v2))
        #expect(MLXLanguageModel.systemText(instructions: candidateInstructions, schema: SmartCleaner.cleanedSchema, profile: .compactV3)
            == CompactCleanupPrompt.systemText(level: .clean, version: .v3))
        #expect(compact.count * 5 < MLXLanguageModel.systemText(instructions: clean, schema: SmartCleaner.cleanedSchema).count)
        #expect(MLXLanguageModel.systemText(instructions: clean, schema: SmartCleaner.cleanedSchema, profile: .production)
            == MLXLanguageModel.systemText(instructions: clean, schema: SmartCleaner.cleanedSchema))
        // Other calls (rerank, actions, modes) never get the cleanup prompt, even under .compact.
        let other = GenerationSchemaSpec(name: "RerankAnswer", json: "{}")
        #expect(MLXLanguageModel.systemText(instructions: clean, schema: other, profile: .compact)
            == MLXLanguageModel.systemText(instructions: clean, schema: other))
        #expect(MLXLanguageModel.systemText(instructions: "Pick a tool.", schema: SmartCleaner.cleanedSchema, profile: .compact)
            == MLXLanguageModel.systemText(instructions: "Pick a tool.", schema: SmartCleaner.cleanedSchema))
        #expect(MLXLanguageModel.Configuration.fromEnvironment(["HUSHY_MLX_MODEL_DIR": "/tmp/m", "HUSHY_MLX_PROMPT_PROFILE": "compact"])?.promptProfile == .compact)
        #expect(MLXLanguageModel.Configuration.fromEnvironment(["HUSHY_MLX_MODEL_DIR": "/tmp/m"])?.promptProfile == .production)
    }

    @Test("group contract profile uses the exact training system text only for group answers")
    func groupContractProfile() {
        let group = CompactCleanupPrompt.systemText(level: .clean, version: .groupContract)
        #expect(MLXLanguageModel.PromptProfile(rawValue: "group-contract") == .groupContract)
        #expect(MLXLanguageModel.systemText(instructions: group, schema: SmartCleaner.groupCleanedSchema, profile: .groupContract) == group)
        #expect(MLXLanguageModel.systemText(instructions: "Pick a tool.", schema: SmartCleaner.cleanedSchema, profile: .groupContract)
            == MLXLanguageModel.systemText(instructions: "Pick a tool.", schema: SmartCleaner.cleanedSchema))
    }

    @Test("configuration from the environment")
    func environment() {
        #expect(MLXLanguageModel.Configuration.fromEnvironment([:]) == nil)
        let configuration = MLXLanguageModel.Configuration.fromEnvironment(["HUSHY_MLX_MODEL_DIR": "/tmp/m", "HUSHY_MLX_KV_BITS": "8"])
        #expect(configuration?.directory.path == "/tmp/m")
        #expect(configuration?.kvCacheBits == 8)
        #expect(MLXLanguageModel.Configuration.fromEnvironment(["HUSHY_MLX_MODEL_DIR": "/tmp/m", "HUSHY_MLX_KV_BITS": "3"])?.kvCacheBits == nil)
    }

    @Test("missing model files → unavailable, and respond throws instead of crashing")
    func missingModelIsUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-mlx-\(UUID().uuidString)")
        let model = MLXLanguageModel(configuration: .init(directory: directory))
        #expect(!model.isAvailable)
        await #expect(throws: LanguageModelError.self) {
            try await model.respond(instructions: "x", prompt: "y", schema: SmartCleaner.cleanedSchema, options: .greedy)
        }
        #expect(model.identifier == "mlx:\(directory.lastPathComponent)")
    }

    @Test("files present but no mlx.metallib beside the test runner → unavailable (never aborts in MLX)")
    func missingMetalLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-mlx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for file in ["config.json", "model.safetensors", "tokenizer.json"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(file).path, contents: Data("{}".utf8))
        }
        #expect(MLXLanguageModel.missingFiles(in: directory) == nil)
        let emptyDir = directory.appendingPathComponent("bin/tool")
        #expect(MetalLibraryLocator.find(executable: emptyDir) == nil)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("mlx.metallib").path, contents: Data())
        #expect(MetalLibraryLocator.find(executable: directory.appendingPathComponent("tool")) != nil)
    }

    @Test("an unavailable MLX model falls through to the secondary backend")
    func fallsBackToSecondary() async throws {
        let missing = MLXLanguageModel(configuration: .init(directory: URL(fileURLWithPath: "/nonexistent/model")))
        let chain = FallbackLanguageModel(primary: missing, secondary: StubModel(json: #"{"text": "from apple"}"#))
        let answer = try await chain.respond(instructions: "x", prompt: "y", schema: SmartCleaner.cleanedSchema, options: .greedy)
        #expect(answer == #"{"text": "from apple"}"#)
        #expect(chain.identifier == "mlx:model>stub")
    }
}

private struct StubModel: LanguageModel {
    let json: String
    var identifier: String { "stub" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String { json }
}
