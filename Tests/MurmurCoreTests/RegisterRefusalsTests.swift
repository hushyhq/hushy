import Foundation
import Synchronization
import Testing
@testable import MurmurCore

private struct NoSpeech: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

/// Answers `registerAnswer` to a call that carries a register line and `plainAnswer` to one that does not.
private final class ScriptedModel: LanguageModel, Sendable {
    let registerAnswer: String
    let plainAnswer: String
    private let seen = Mutex<[Bool]>([])
    init(registerAnswer: String, plainAnswer: String) {
        self.registerAnswer = registerAnswer
        self.plainAnswer = plainAnswer
    }
    var callsWithRegister: [Bool] { seen.withLock { $0 } }
    var identifier: String { "register-refusals-scripted" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        let hasRegister = IntentRegister.detecting(in: instructions) != nil
        seen.withLock { $0.append(hasRegister) }
        return String(decoding: try JSONEncoder().encode(["text": hasRegister ? registerAnswer : plainAnswer]), as: UTF8.self)
    }
}

/// Three refusals seen on a Mac (TRY-100), reproduced with invented lines: a register rewording that states a limit as a
/// negation, a prompt that turns "I go with that" into "I will go with that", and a plain answer that dropped a noun.
@Suite("Register answers that were refused although their meaning held", .timeLimit(.minutes(2)))
struct RegisterRefusalsTests {
    private let mail = "com.apple.mail"
    private let claude = "com.anthropic.claudefordesktop"

    private func run(spoken: String, registerAnswer: String, plainAnswer: String, bundleID: String)
        async -> (result: PipelineResult, calls: [Bool]) {
        let model = ScriptedModel(registerAnswer: registerAnswer, plainAnswer: plainAnswer)
        let cleaner = SmartCleaner(model: model, health: ModelHealth(), wholeTranscript: { true }, registerLines: { true })
        let tones = ToneSettings.standard
        let mode = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        let settings = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: tones.dictationLevel), tone: tones, mode: mode,
            category: AppCategory.classify(bundleID: bundleID), bundleID: bundleID, windowTitle: nil)
        let result = await DictationPipeline(transcriber: NoSpeech(), cleaner: cleaner).clean(spoken, settings: settings)
        return (result, model.callsWithRegister)
    }

    // MARK: A limit worded as a decline

    private let mumbled = "hey um so about that task you sent over i i'm honestly way too busy right now like totally swamped with the launch stuff so yeah next month maybe"

    @Test("a Professional rewording that says 'I don't have the bandwidth' for 'too busy' is taken from the first ask")
    func limitWordedAsDecline() async {
        let reworded = "About the task you sent over, I don't have the bandwidth to take it on right now, as I am swamped with the launch. Next month may work."
        let run = await run(spoken: mumbled, registerAnswer: reworded, plainAnswer: "NOT USED", bundleID: mail)
        #expect(run.calls == [true])
        #expect(run.result.usedModel)
        #expect(run.result.text.contains("bandwidth"), "\(run.result.text)")
        #expect(run.result.groups.first?.registerDropped == false)
    }

    @Test("a polarity flip is still refused under a register, and the plain answer, which keeps the meaning, is used")
    func flipStillRefused() async {
        let run = await run(spoken: "hi dana i can do it by friday", registerAnswer: "Hi Dana, I can't do it by Friday.",
                            plainAnswer: "Hi Dana, I can do it by Friday.", bundleID: mail)
        #expect(run.calls == [true, false])
        #expect(run.result.text.contains("can do it"), "\(run.result.text)")
        #expect(!run.result.text.contains("can't"), "\(run.result.text)")
        #expect(run.result.groups.first?.registerDropped == true)
    }

    // MARK: "I go with that" written as a promise

    private let handOver = "go with your recommendations this is a product that we both are building so whatever you think is the best success for our app and i go with that"

    @Test("a Prompt answer that writes 'I go with that' as 'I will go with whatever you think' is taken from the first ask")
    func saidCommitmentAsPromise() async {
        let answer = "Go with your recommendations. This is a product we both are building, so I will go with whatever you think is the best success for our app."
        let run = await run(spoken: handOver, registerAnswer: answer, plainAnswer: "NOT USED", bundleID: claude)
        #expect(run.calls == [true])
        #expect(run.result.usedModel)
        #expect(run.result.text.contains("I will go with whatever"), "\(run.result.text)")
    }

    @Test("a Prompt answer that promises something the speaker never said is still refused")
    func unsaidPromiseRefused() async {
        // Two sentences: a short one-sentence ask is sent no Prompt line (`SmartCleaner.isShortAsk`).
        let run = await run(spoken: "can you review the draft before the call. it starts at noon",
                            registerAnswer: "I will review the draft before the call. It starts at noon.",
                            plainAnswer: "Can you review the draft before the call? It starts at noon.", bundleID: claude)
        #expect(run.calls == [true, false])
        #expect(run.result.groups.first?.registerDropped == true)
    }

    // MARK: A noun lost

    @Test("a plain answer that drops 'our app' gets it back where the speaker said it")
    func droppedNounIsPutBack() async {
        let register = "Understood. Here is my plan: first I will review the roadmap, then I will draft the launch checklist."
        let plain = "Go with your recommendations. This is a product we both are building, so whatever you think is the best success for, and I go with that."
        let run = await run(spoken: handOver, registerAnswer: register, plainAnswer: plain, bundleID: claude)
        #expect(run.result.usedModel)
        #expect(run.result.text.contains("for our app"), "\(run.result.text)")
    }

    @Test("a clause the model takes out whole, with the sentence closed behind it, stays its choice")
    func omittedClauseStaysTheModelsChoice() async {
        let spoken = "send the outline to prepare for the review. then ping me"
        let run = await run(spoken: spoken, registerAnswer: "Send the outline. Then ping me.", plainAnswer: "NOT USED", bundleID: claude)
        #expect(run.result.usedModel)
        #expect(run.result.text == "Send the outline. Then ping me.", "\(run.result.text)")
        #expect(run.calls == [true])
    }
}
