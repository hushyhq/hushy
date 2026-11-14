import Foundation
import Testing
@testable import MurmurCore

private struct ScriptedTranscriber: Transcriber {
    let text: String
    func transcribe(_ samples: [Float]) async throws -> String { text }
}

private struct ScriptedIntentModel: LanguageModel {
    let answer: String
    var identifier: String { "scripted-intent" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        String(decoding: try JSONEncoder().encode(["text": answer]), as: UTF8.self)
    }
}

/// Founder, Hushy-Preview 3136 with rl-v9 loaded: spoken "it mistook RL-v9 as RL-v9", pasted "rl-v99". The digits of a
/// code-like name are part of the name; a value said elsewhere in the dictation, or a correction cue, must not excuse them.
@Suite("Digits inside identifiers")
struct IdentifierDigitsGuardTests {
    private func pasted(_ raw: String, answer: String) async -> String {
        let cleaner = SmartCleaner(model: ScriptedIntentModel(answer: answer), health: ModelHealth(), wholeTranscript: { true })
        let pipeline = DictationPipeline(transcriber: ScriptedTranscriber(text: raw), cleaner: cleaner)
        return await pipeline.clean(raw, settings: PipelineSettings(cleanupOptions: CleanupOptions(level: .polished))).text
    }

    @Test("the founder's answer is refused, alone and beside a correction that says the digits elsewhere", arguments: [
        ("It mistook Rl-v9 as Rl-v9", "It mistook rl-v99 for rl-v99."),
        ("It mistook Rl-v9 as Rl-v9, sorry, it passed 99 prompts", "It mistook rl-v99 for rl-v99, and it passed 99 prompts."),
        ("Ship Rl-v19 today, I mean 9 prompts", "Ship rl-v9 today, 9 prompts."),
        ("Ticket TRY-95 is open, no wait, 96 people saw it", "Ticket TRY-96 is open, 96 people saw it."),
    ])
    func wholeTranscript(_ raw: String, _ answer: String) async {
        #expect(IntentOutputGuard.check(answer, raw: raw) == .rejected("changed digits"))
        let text = await pasted(raw, answer: answer)
        #expect(!text.lowercased().contains("v99") && !text.contains("TRY-96") && !text.lowercased().contains("rl-v9 today"),
                "pasted: \(text)")
    }

    @Test("group cleanup refuses an identifier's digits changed under a correction cue", arguments: [
        ("Rl-v9 passed 99 prompts, sorry, 99 tests.", "rl-v99 passed 99 prompts, sorry, 99 tests."),
        ("Use the m3 box, actually 33 cores.", "Use the m33 box, actually 33 cores."),
    ])
    func group(_ draft: String, _ answer: String) {
        #expect(CriticalTokenGuard.violation(answer: answer, draft: draft) == "changed digits")
    }

    @Test("an added, dropped or changed digit inside a code-like token is refused", arguments: [
        ("Deploy build v2.3 tonight", "Deploy build v2.4 tonight."),
        ("Ship rl-v9 today", "Ship rl-v99 today."),
        ("Ship rl-v19 today", "Ship rl-v9 today."),
        ("Bump gpt4o in the config", "Bump gpt5o in the config."),
        ("Open ticket TRY-95 now", "Open ticket TRY-96 now."),
        ("Use the m3 machine", "Use the m33 machine."),
    ])
    func identifierDigits(_ raw: String, _ answer: String) {
        #expect(IntentOutputGuard.check(answer, raw: raw) == .rejected("changed digits"))
    }

    @Test("an identifier said as it was, in another case or style, is accepted", arguments: [
        ("It mistook Rl-v9 as Rl-v9", "It mistook RL-v9 for RL-v9."),
        ("Ship rl v9 today", "Ship rl-v9 today."),
        ("Open ticket try 95 now", "Open ticket TRY-95 now."),
        ("We run gpt4o and qwen3 locally", "We run GPT4o and Qwen3 locally."),
        ("Deploy v2 point 3 tonight", "Deploy v2.3 tonight."),
        ("Ship Rl-v9 no wait Rl-v10 today", "Ship RL-v10 today."),
    ])
    func sameIdentifier(_ raw: String, _ answer: String) {
        #expect(IntentOutputGuard.check(answer, raw: raw) == .accepted(answer))
    }

    @Test("spoken numbers are still read the way people say them", arguments: [
        ("It costs two to three hundred dollars", "It costs $200 to $300."),
        ("Meet at seven fifteen on the third floor", "Meet at 7:15 on the third floor."),
        ("We need two point five million", "We need 2.5 million."),
        ("Meet in room B2 at three", "Meet in room B2 at 3."),
    ])
    func spokenValues(_ raw: String, _ answer: String) {
        #expect(IntentOutputGuard.check(answer, raw: raw) == .accepted(answer))
    }
}
