import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// Answers every call with `answer` as the cleanup JSON, or fails, and counts its calls.
private final class Leg: LanguageModel {
    let answer: String?
    let available: Bool
    private let calls = Mutex(0)
    var callCount: Int { calls.withLock { $0 } }

    init(answer: String?, available: Bool = true) {
        self.answer = answer
        self.available = available
    }

    var identifier: String { "leg" }
    var availability: LanguageModelAvailability { available ? .available : .unavailable(reason: "paused") }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        calls.withLock { $0 += 1 }
        guard let answer else { throw LanguageModelError.unavailable("local model failed") }
        return String(decoding: try JSONEncoder().encode(["text": answer]), as: UTF8.self)
    }
}

private struct SilentTranscriber: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

/// The whole-transcript prompt is written for the local intent model, and its guard (`IntentOutputGuard`) leaves out the
/// word-level checks that model was measured without. The fallback model was built and measured on the rules-draft prompt
/// under `OutputGuard`; it must only ever be asked that way, and judged that way.
@Suite("Fallback after the intent model fails", .timeLimit(.minutes(2)))
struct IntentFallbackTests {
    static let raw = "send the outline to prepare for the review"
    /// What the intent guard lets the intent model leave out (a purpose phrase), and the word-level guard does not.
    static let shortened = "Send the outline."

    private func clean(_ model: any LanguageModel, wholeTranscript: @escaping @Sendable () -> Bool) async -> PipelineResult {
        let cleaner = SmartCleaner(model: model, health: ModelHealth(), wholeTranscript: wholeTranscript)
        let pipeline = DictationPipeline(transcriber: SilentTranscriber(), cleaner: cleaner)
        return await pipeline.clean(Self.raw, settings: PipelineSettings(cleanupOptions: CleanupOptions(level: .polished)))
    }

    @Test("the intent guard does let the intent model shorten this, so the cases below test the fallback alone")
    func intentModelMayShorten() async {
        let result = await clean(Leg(answer: Self.shortened), wholeTranscript: { true })
        #expect(result.text == Self.shortened, "rejection: \(String(describing: result.rejection))")
    }

    @Test("a failed intent call is not handed to the fallback model under the intent prompt and guard")
    func failedCallStaysOffTheFallback() async {
        let secondary = Leg(answer: Self.shortened)
        let chain = FallbackLanguageModel(primary: Leg(answer: nil), secondary: secondary)
        let result = await clean(chain, wholeTranscript: { true })
        #expect(result.text != Self.shortened, "the fallback's answer was judged by the intent guard")
        #expect(secondary.callCount == 0)
    }

    @Test("while the intent model cannot answer, cleanup asks the fallback the way it was built for")
    func pausedIntentModel() async {
        let secondary = Leg(answer: Self.shortened)
        let switchable = SwitchableLanguageModel(FallbackLanguageModel(primary: Leg(answer: nil, available: false), secondary: secondary))
        switchable.usesWholeTranscript = true
        #expect(switchable.usesWholeTranscript == false)
        let result = await clean(switchable, wholeTranscript: { switchable.usesWholeTranscript })
        #expect(result.text != Self.shortened, "the fallback's answer was judged by the intent guard")
        #expect(secondary.callCount >= 1, "the fallback still answers, on its own prompt")
    }

    @Test("a backend that was not trained on the whole transcript never says it was")
    func plainBackend() {
        let switchable = SwitchableLanguageModel(Leg(answer: "x"))
        #expect(switchable.usesWholeTranscript == false)
        switchable.usesWholeTranscript = true
        #expect(switchable.usesWholeTranscript == true)
    }

    @Test("other calls through the chain still fall back")
    func otherCallsFallBack() async throws {
        let chain = FallbackLanguageModel(primary: Leg(answer: nil), secondary: Leg(answer: "s"))
        let json = try await chain.respond(instructions: "i", prompt: "p", schema: SmartCleaner.cleanedSchema, options: .greedy)
        #expect(json.contains("\"s\""))
    }
}
