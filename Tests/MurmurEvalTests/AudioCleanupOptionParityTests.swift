import Foundation
import MurmurCore
import Synchronization
import Testing

@testable import murmur_eval

@Suite("Audio cleanup option parity")
struct AudioCleanupOptionParityTests {
    private func settings(_ command: String, _ flags: [String]) throws -> PipelineSettings {
        let resolved = try Runners.audioCleanupSettings(Arguments(([command] + flags)[...]))
        return try #require(resolved)
    }

    private func run(_ command: String, flags: [String], raw: String, answer: String, model suppliedModel: AudioReplyModel? = nil) async throws -> PipelineResult {
        let model = suppliedModel ?? AudioReplyModel(answer: answer)
        let pipeline = DictationPipeline(
            transcriber: AudioFixedTranscriber(text: raw),
            cleaner: SmartCleaner(model: model, health: ModelHealth()))
        let selected = try settings(command, flags)
        // Both entry points consume these resolved settings: e2e processes the mock ASR;
        // voice-trace cleans the traced ASR string twice (rules and selected strategy).
        let strategy = Runners.audioCleanupStrategy(Arguments(([command] + flags)[...]), settings: selected)
        if command == "voice-trace" {
            return await pipeline.clean(raw, settings: selected, strategy: strategy)
        }
        return try await pipeline.run(samples: [Float](repeating: 0, count: 16_000), settings: selected, strategy: strategy)
    }

    @Test(arguments: ["e2e", "voice-trace"])
    func verbatimPreservesFillersWhileCleanRemovesThem(command: String) async throws {
        let raw = "um, send the report tomorrow"
        let verbatim = try await run(command, flags: ["--level", "verbatim"], raw: raw, answer: "Send the report tomorrow.")
        let clean = try await run(command, flags: ["--level", "clean"], raw: raw, answer: "Send the report tomorrow.")
        #expect(verbatim.text.lowercased().contains("um"))
        #expect(!verbatim.usedModel)
        #expect(clean.text == "Send the report tomorrow.")
    }

    @Test(arguments: ["e2e", "voice-trace"])
    func minimalContractReachesModelInstructions(command: String) async throws {
        let raw = "I saw a apple"
        let legacyModel = AudioReplyModel(answer: "I saw an apple.")
        let minimalModel = AudioReplyModel(answer: "I saw an apple.")
        _ = try await run(command, flags: [], raw: raw, answer: "I saw an apple.", model: legacyModel)
        let minimal = try await run(command, flags: ["--clean-grammar-contract", "minimal"], raw: raw, answer: "I saw an apple.", model: minimalModel)
        #expect(legacyModel.instructions.first?.contains("Do not fix grammar") == true)
        #expect(minimalModel.instructions.first?.contains("auxiliary agreement among am/is/are") == true)
        #expect(minimal.text == "I saw an apple.")
        #expect(minimal.usedModel)
    }

    @Test(arguments: ["e2e", "voice-trace"])
    func polishedAndCasualContextReachActualCleanup(command: String) async throws {
        let raw = "hey, that works for me. see you around 6!"
        let result = try await run(command, flags: ["--level", "polished", "--casual-context"], raw: raw, answer: raw)
        #expect(result.text == raw)
        #expect(result.usedModel)
    }

    @Test(arguments: ["e2e", "voice-trace"])
    func codeContextKeepsSpokenPunctuation(command: String) async throws {
        let result = try await run(command, flags: ["--code-context"], raw: "open the file", answer: "open the file")
        #expect(result.text == "open the file")
    }

    @Test(arguments: ["e2e", "voice-trace"])
    func explicitRulesStrategyOverridesPolishedDefault(command: String) async throws {
        let result = try await run(command, flags: ["--level", "polished", "--strategy", "rules"], raw: "send the report", answer: "Send the report.")
        #expect(!result.usedModel)
        #expect(result.text == "Send the report.")
    }

    @Test(arguments: ["e2e", "voice-trace"])
    func invalidOptionsFailBeforeRunnerLoadsAudioOrModels(command: String) async {
        for flags in [["--level", "mystery"], ["--level"], ["--clean-grammar-contract", "mystery"]] {
            let args = Arguments(([command] + flags)[...])
            do {
                if command == "e2e" { try await Runners.endToEnd(args) }
                else { try await VoiceTraceRunner.run(args) }
                Issue.record("invalid cleanup options were accepted")
            } catch {
                let expectedFlag = flags[0]
                #expect(error.localizedDescription.contains(expectedFlag))
            }
        }
    }

    @Test(arguments: [["--raw"], ["--raw", "true"]])
    func rawASRHasNoEffectiveCleanupEvenWithCleanupFlags(rawFlags: [String]) throws {
        let args = Arguments((["e2e"] + rawFlags + ["--level", "polished", "--clean-grammar-contract", "mystery"])[...])
        #expect(try Runners.audioCleanupSettings(args) == nil)
        let metadata = Runners.cleanupSettingsMetadata(nil)
        #expect(metadata["applied"] as? Bool == false)
        #expect(metadata["level"] == nil)
    }
}

private struct AudioFixedTranscriber: Transcriber {
    let text: String
    func transcribe(_ samples: [Float]) async throws -> String { text }
}

private final class AudioReplyModel: LanguageModel, Sendable {
    let answer: String
    private let calls = Mutex<[String]>([])
    var instructions: [String] { calls.withLock { $0 } }
    init(answer: String) { self.answer = answer }
    var identifier: String { "audio-parity-test" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        calls.withLock { $0.append(instructions) }
        return CompactCleanupPrompt.answerJSON(answer)
    }
}
