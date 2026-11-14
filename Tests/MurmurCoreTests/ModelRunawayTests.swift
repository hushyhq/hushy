import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// A model that runs past its answer cap fails at once, and the cleaner takes the rules text at once: no retry of
/// a call that would repeat itself, no wait for the dictation's deadline.
@Suite("Model runaway answers", .timeLimit(.minutes(1)), .serialized)
struct ModelRunawayTests {
    private let spoken = "so we need to finish the report before friday and send it to the team"

    @Test("a call that fails on its answer cap returns the rules text well under the budget, without a retry")
    func capErrorFallsBackAtOnce() async {
        let model = RunawayModel(failsAfter: .milliseconds(150))
        let cleaner = SmartCleaner(
            budget: .seconds(8), correctionBudget: .seconds(8), polishedBudget: .seconds(8), segmentBudget: .seconds(8),
            model: model, health: ModelHealth(), dictationCeiling: .seconds(20))
        let start = SuspendingClock.now
        let output = await cleaner.clean(spoken, options: CleanupOptions(level: .polished))
        let took = ModelPace.ms(SuspendingClock.now - start) / 1000
        #expect(took < 2.0, "the fallback waited \(took) s for a call that had already failed")
        #expect(model.calls == 1, "a runaway call was asked again")
        #expect(output.text.lowercased().contains("finish the report"))
        #expect(output.groups.first?.outcome == .modelError)
        #expect(output.groups.first?.retries == 0)
    }

    @Test("an output that did not decode is a malformed failure that is not retried")
    func malformedIsNotRetryable() {
        let failure = ModelCallFailure(LanguageModelError.malformedOutput("MLX answer exceeded 136 tokens"))
        #expect(failure == .malformed)
        #expect(!SmartCleaner.isRetryable(failure))
        #expect(SmartCleaner.isRetryable(.error))
        #expect(SmartCleaner.rejection(for: failure) == "model error")
    }
}

/// Fails every call with the answer-cap error after `failsAfter`, and counts the calls.
private final class RunawayModel: LanguageModel {
    private let count = Mutex(0)
    private let failsAfter: Duration
    init(failsAfter: Duration) { self.failsAfter = failsAfter }
    var calls: Int { count.withLock { $0 } }
    var identifier: String { "runaway" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        count.withLock { $0 += 1 }
        try await Task.sleep(for: failsAfter)
        throw LanguageModelError.malformedOutput("MLX answer exceeded 136 tokens")
    }
}
