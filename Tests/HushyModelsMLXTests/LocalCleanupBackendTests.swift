import Foundation
import Testing
@testable import HushyModelsMLX
@testable import MurmurCore

/// M6: how the app runs a registry entry (shared with `murmur-eval --backend local`).
@Suite("Local cleanup backend wiring")
struct LocalCleanupBackendTests {
    @Test("registry entries retain their measured speculation setting and prompt profile")
    func speculationEnabled() {
        for entry in ModelRegistry.entries {
            let configuration = LocalCleanupBackend.configuration(for: entry, directory: URL(fileURLWithPath: "/tmp/x"))
            #expect((configuration.speculation != nil) == entry.speculation, "\(entry.id): measured speculation setting")
            #expect(configuration.promptProfile.rawValue == entry.promptProfile.rawValue)
            #expect(configuration.toolGrammar == "strict")
            #expect(configuration.usePrefixCache)
        }
        // The compact profile a fine-tuned entry will carry maps onto the MLX adapter's.
        for profile in LocalModelEntry.PromptProfile.allCases {
            #expect(MLXLanguageModel.PromptProfile(rawValue: profile.rawValue) != nil)
        }
    }

    @Test("a missing model falls through the chain to the fallback, and the call log sees both legs")
    func chainFallsThrough() async throws {
        let log = ModelCallLog()
        let entry = try #require(ModelRegistry.entry(id: ModelRegistry.qwen08B4bit))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-model-\(UUID().uuidString)")
        let chain = LocalCleanupBackend.chain(
            entry: entry, directory: missing, fallback: StubAnswer(json: #"{"text":"from apple"}"#), idleSeconds: 120, callLog: log)
        #expect(!chain.local.isAvailable)
        #expect(chain.local.residency.idleSeconds == 120)
        #expect(chain.mlx.configuration.speculation != nil)
        let json = try await chain.model.respond(
            instructions: "i", prompt: "p", schema: SmartCleaner.cleanedSchema, options: .greedy)
        #expect(json == #"{"text":"from apple"}"#)
        #expect(log.recent.map(\.backend) == ["apple"], "an unavailable local model is skipped, not called")
    }

    @Test("engine failures map onto the seam: out of GPU memory is busy, anything else unavailable")
    func errorClassification() {
        struct EngineError: Error, CustomStringConvertible { let description: String }
        guard case .busy = MLXLanguageModel.classify(EngineError(description: "[metal::malloc] Unable to allocate 1073741824 bytes")) else {
            Issue.record("allocation failure must be busy"); return
        }
        guard case .busy = MLXLanguageModel.classify(EngineError(description: "Command buffer failed: Insufficient Memory (kIOGPUCommandBufferCallbackErrorOutOfMemory)")) else {
            Issue.record("GPU OOM must be busy"); return
        }
        guard case .unavailable = MLXLanguageModel.classify(EngineError(description: "shape mismatch")) else {
            Issue.record("other errors are unavailable"); return
        }
        #expect(MLXLanguageModel.classify(LanguageModelError.unsupportedSchema("x")) == .unsupportedSchema("x"))
    }

    @Test("the Metal kernels are found in the app bundle's resources, where build-app.sh puts them")
    func metallibInAppResources() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Fake-\(UUID().uuidString).app/Contents")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let executable = app.appendingPathComponent("MacOS/Hushy")
        let resources = app.appendingPathComponent("Resources")
        #expect(MetalLibraryLocator.find(executable: executable, resources: resources) == nil)
        let bundle = resources.appendingPathComponent("mlx-swift_Cmlx.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bundle.appendingPathComponent("default.metallib").path, contents: Data([0]))
        #expect(MetalLibraryLocator.find(executable: executable, resources: resources)?.lastPathComponent == "default.metallib")
    }
}

private struct StubAnswer: LanguageModel {
    let json: String
    var identifier: String { "stub" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        json
    }
}
