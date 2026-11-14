import Foundation
import Synchronization
import Testing
@testable import MurmurCore

private struct NoSpeechForRegister: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

/// Answers every call with `answer` and remembers the instructions it was given, which is where the register line rides.
private final class RecordingIntentModel: LanguageModel, Sendable {
    let answer: String
    private let seen = Mutex<[String]>([])
    private let answered: @Sendable () -> Void
    init(answer: String, answered: @escaping @Sendable () -> Void = {}) {
        self.answer = answer
        self.answered = answered
    }
    var instructions: [String] { seen.withLock { $0 } }
    var identifier: String { "recording-intent" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        seen.withLock { $0.append(instructions) }
        answered()
        return String(decoding: try JSONEncoder().encode(["text": answer]), as: UTF8.self)
    }
}

@Suite("Intent register line", .timeLimit(.minutes(2)))
struct IntentRegisterTests {
    private let claude = "com.anthropic.claudefordesktop"
    private let slack = "com.tinyspeck.slackmacgap"
    private let mail = "com.apple.mail"
    private let terminal = "com.apple.Terminal"
    private let vsCode = "com.microsoft.VSCode"
    private let notes = "com.apple.Notes"

    // MARK: The capability

    @Test("only the 4B (round 10d) understands register lines; no other model and no unknown one does")
    func capabilityOnlyOnThe4B() {
        #expect(!ModelRegistry.entries.isEmpty)
        for entry in ModelRegistry.entries {
            #expect(entry.understandsRegisterLines == (entry.logicalID == ModelRegistry.hushyCleanup4B), "\(entry.id)")
        }
        #expect(ModelRegistry.understandsRegisterLines(id: ModelRegistry.hushyCleanup4B))
        #expect(!ModelRegistry.understandsRegisterLines(id: ModelRegistry.hushyCleanup2BIntent))
        #expect(!ModelRegistry.understandsRegisterLines(id: "no-such-model"))
    }

    // MARK: Which register a dictation asks for

    private func register(_ tones: ToneSettings, _ bundleID: String, category: AppCategory? = nil) -> IntentRegister? {
        tones.register(for: category ?? AppCategory.classify(bundleID: bundleID), bundleID: bundleID)
    }

    @Test("Refined sends no line in ordinary apps; email is Professional by default; AI apps and agent sessions are prompts")
    func refinedDefault() {
        let tones = ToneSettings.standard
        #expect(register(tones, slack) == nil)
        #expect(register(tones, notes) == nil)
        #expect(register(tones, mail) == .professional)
        #expect(register(tones, claude) == .prompt)
        #expect(register(tones, "com.openai.chat") == .prompt)
        // A terminal agent session reaches the cleaner as an AI-prompt dictation in the terminal's bundle.
        #expect(register(tones, terminal, category: .aiPrompts) == .prompt)
    }

    @Test("a code editor or a plain terminal gets no register, whatever is set")
    func codeGetsNone() {
        var tones = ToneSettings(defaultTone: .casual)
        tones = tones.settingApp(.tone(.professional), bundleIDs: [vsCode, terminal])
        #expect(register(tones, vsCode) == nil)
        #expect(register(tones, terminal) == nil)
        #expect(register(tones, terminal, category: .code) == nil)
    }

    @Test("the default tone and the tone for a kind of app map to Casual and Professional")
    func toneMapping() {
        let casual = ToneSettings(defaultTone: .casual)
        #expect(register(casual, slack) == .casual)
        #expect(register(casual, notes) == .casual)
        #expect(register(casual, mail) == .casual) // the person set Casual as the default and Email keeps its own tone only if shipped
        let professional = ToneSettings(defaultTone: .professional)
        #expect(register(professional, slack) == .professional)
        let placeTone = ToneSettings(defaultTone: .refined).settingTone(.casual, for: .workMessages)
        #expect(register(placeTone, slack) == .casual)
        #expect(register(placeTone, notes) == nil)
    }

    @Test("the person's own choice for an app wins over the AI-app default and over the place's tone")
    func appChoiceWins() {
        let base = ToneSettings(defaultTone: .casual)
        #expect(register(base.settingApp(.tone(.professional), bundleIDs: [claude]), claude) == .professional)
        #expect(register(base.settingApp(.tone(.casual), bundleIDs: [claude]), claude) == .casual)
        // Refined chosen for the app is "no register", not the prompt default.
        #expect(register(base.settingApp(.tone(.refined), bundleIDs: [claude]), claude) == nil)
        #expect(register(base.settingApp(.tone(.professional), bundleIDs: [slack]), slack) == .professional)
        #expect(register(base.settingApp(.tone(.refined), bundleIDs: [slack]), slack) == nil)
    }

    @Test("an app moved to AI tools is a prompt, and an AI app moved elsewhere follows its new place")
    func movedApps() {
        let tones = ToneSettings(defaultTone: .casual)
        #expect(register(tones.movingApp(to: .aiTools, bundleIDs: [notes]), notes) == .prompt)
        #expect(register(tones.movingApp(to: .workMessages, bundleIDs: [claude]), claude) == .casual)
        #expect(register(ToneSettings.standard.movingApp(to: .email, bundleIDs: [claude]), claude) == .professional)
    }

    @Test("a browser tab follows its category; an app choice never applies to a browser")
    func browsers() {
        let chrome = "com.google.Chrome"
        let tones = ToneSettings(defaultTone: .casual).settingApp(.tone(.professional), bundleIDs: [chrome])
        #expect(register(tones, chrome, category: .aiPrompts) == .prompt)
        #expect(register(tones, chrome, category: .workMessages) == .casual)
    }

    @Test("As spoken sends no line anywhere")
    func asSpoken() {
        var tones = ToneSettings.standard
        tones.choice = .asSpoken
        for id in [slack, mail, claude, notes, vsCode] { #expect(register(tones, id) == nil, "\(id)") }
        #expect(register(tones, terminal, category: .aiPrompts) == nil)
    }

    @Test("the settings for a dictation carry the register")
    func settingsCarryRegister() {
        let mode = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(ToneSettings.standard.dictationLevel)
        func options(_ tones: ToneSettings, _ bundleID: String, _ category: AppCategory) -> CleanupOptions {
            PipelineSettings.forDictation(cleanup: CleanupOptions(level: .polished), tone: tones, mode: mode,
                                          category: category, bundleID: bundleID, windowTitle: nil).cleanupOptions
        }
        #expect(options(.standard, claude, .aiPrompts).register == .prompt)
        #expect(options(.standard, mail, .email).register == .professional)
        #expect(options(.standard, slack, .workMessages).register == nil)
        #expect(options(.standard, vsCode, .code).register == nil)
    }

    // MARK: The prompt text

    @Test("each register adds exactly its one line after the first line; no register is today's prompt")
    func promptText() {
        let lines = IntentCleanupPrompt.system.components(separatedBy: "\n")
        #expect(IntentCleanupPrompt.system(register: nil) == IntentCleanupPrompt.system)
        for register in IntentRegister.allCases {
            let withLine = IntentCleanupPrompt.system(register: register).components(separatedBy: "\n")
            #expect(withLine.count == lines.count + 1)
            #expect(withLine[0] == lines[0])
            #expect(withLine[1] == register.line)
            #expect(Array(withLine[2...]) == Array(lines[1...]))
        }
    }

    @Test("Casual is the line round 8 was trained on; Professional is the reworded line of 2026-10-28, Prompt that of 2026-11-11")
    func exactLines() {
        #expect(IntentRegister.casual.line == "Register: casual — Write the same message as a relaxed note to a friend or close colleague: conversational wording and contractions, a friendly tone, and real rewording; keep every fact, hedge, negation and intent exactly as spoken.")
        #expect(IntentRegister.professional.line == "Register: professional — Write the same message in composed, diplomatic workplace wording, as a careful professional would type it, at the length it was said: a fragment or short reply stays short, and a question stays a question with the same yes/no sense; add nothing that was not said, and keep every name, number, fact, hedge, negation and intent exactly as spoken.")
        #expect(IntentRegister.prompt.line == "Register: prompt — Write it as a clear prompt for an AI assistant or agent, in the speaker's own words and order, with mis-heard words and names repaired: keep the speaker's structure (role, steps, requirements, examples) as short paragraphs or lists; a short ask stays one sentence; commands, paths and code the speaker dictated as code in backticks; add nothing that was not said.")
        #expect(IntentRegister(tone: .refined) == nil)
        #expect(IntentRegister(tone: .casual) == .casual && IntentRegister(tone: .professional) == .professional)
    }

    @Test("the Professional line keeps the said shape: no 'complete sentences', fragments stay short, questions stay questions")
    func professionalKeepsShape() {
        let line = IntentRegister.professional.line
        // "complete sentences" made the 4B wrap a clipped fragment in an invented sentence (guard ablation, 2026-10-28).
        #expect(!line.contains("complete sentences"))
        #expect(line.contains("a fragment or short reply stays short"))
        #expect(line.contains("a question stays a question with the same yes/no sense"))
        #expect(line.contains("add nothing that was not said"))
        #expect(!line.contains("\n"))
    }

    @Test("a line is found in instructions only as a whole line, and no ordinary instructions contain one")
    func detecting() {
        for register in IntentRegister.allCases {
            #expect(IntentRegister.detecting(in: "Level: Clean\n" + register.line) == register)
            #expect(IntentRegister.detecting(in: register.line + "\nGuard feedback: x") == register)
            #expect(IntentRegister.detecting(in: register.line + " extra") == nil)
        }
        for confidence in [false, true] {
            #expect(IntentRegister.detecting(in: SmartCleaner.cleanupInstructions(confidenceGuided: confidence)) == nil)
        }
        #expect(IntentRegister.detecting(in: "") == nil)
    }

    // MARK: What the cleaner sends and what the pipeline does with the answer

    private func run(
        raw: String, answer: String, bundleID: String, category: AppCategory? = nil, tones: ToneSettings,
        registerLines: Bool, whole: Bool = true, wholeAfterAnswer: Bool? = nil, clearingRegister: Bool = false
    ) async -> (result: PipelineResult, instructions: [String]) {
        let takesWhole = Mutex(whole)
        let model = RecordingIntentModel(answer: answer) { if let wholeAfterAnswer { takesWhole.withLock { $0 = wholeAfterAnswer } } }
        let cleaner = SmartCleaner(model: model, health: ModelHealth(), wholeTranscript: { takesWhole.withLock { $0 } },
                                   registerLines: { registerLines })
        let mode = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        var settings = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: tones.dictationLevel), tone: tones, mode: mode,
            category: category ?? AppCategory.classify(bundleID: bundleID), bundleID: bundleID, windowTitle: nil)
        if clearingRegister { settings.cleanupOptions.register = nil }
        let pipeline = DictationPipeline(transcriber: NoSpeechForRegister(), cleaner: cleaner)
        let result = await pipeline.clean(raw, settings: settings)
        return (result, model.instructions)
    }

    private let spoken = "Um, we do not know yet."
    private let written = "We do not know yet."

    @Test("with the capability on, the line goes to the model for each tone and kind of app; with it off, never")
    func lineSelection() async {
        let cases: [(ToneSettings, String, AppCategory?, IntentRegister?)] = [
            (ToneSettings(defaultTone: .casual), slack, nil, .casual),
            (ToneSettings(defaultTone: .professional), slack, nil, .professional),
            (ToneSettings(defaultTone: .refined), slack, nil, nil),
            (.standard, mail, nil, .professional),
            (.standard, claude, nil, .prompt),
            (ToneSettings(defaultTone: .casual), claude, nil, .prompt),
            (.standard, terminal, .aiPrompts, .prompt),
            (ToneSettings(defaultTone: .casual).settingApp(.tone(.professional), bundleIDs: [claude]), claude, nil, .professional),
            (ToneSettings(defaultTone: .casual), vsCode, nil, nil),
        ]
        // Two sentences: a one-sentence ask is sent no Prompt line (`oneSentenceAskHasNoPromptLine`).
        let spoken = "Um, we do not know yet. Can you check the logs?"
        let written = "We do not know yet. Can you check the logs?"
        for (tones, bundleID, category, expected) in cases {
            let on = await run(raw: spoken, answer: written, bundleID: bundleID, category: category, tones: tones, registerLines: true)
            #expect(!on.instructions.isEmpty, "\(bundleID)")
            for instructions in on.instructions { #expect(IntentRegister.detecting(in: instructions) == expected, "\(bundleID)") }
            let off = await run(raw: spoken, answer: written, bundleID: bundleID, category: category, tones: tones, registerLines: false)
            for instructions in off.instructions { #expect(IntentRegister.detecting(in: instructions) == nil, "\(bundleID) off") }
            // Off, the instructions are exactly what a dictation with no register sends.
            let bare = await run(raw: spoken, answer: written, bundleID: bundleID, category: category, tones: tones,
                                 registerLines: true, clearingRegister: true)
            #expect(off.instructions == bare.instructions, "\(bundleID) off")
        }
    }

    // Accuracy eval, Claude app, 2026-11-11: asked for a prompt, the 4B repaired mis-heard names and identifiers less often.
    @Test("a one-sentence ask in an AI app is sent no Prompt line and gets the Default's cleanup, with no tone swaps")
    func oneSentenceAskHasNoPromptLine() async {
        let short = await run(raw: spoken, answer: written, bundleID: claude, tones: ToneSettings(defaultTone: .casual), registerLines: true)
        for instructions in short.instructions { #expect(IntentRegister.detecting(in: instructions) == nil) }
        #expect(short.result.text == "We do not know yet", "\(short.result.text)")
        // Professional chosen for the app is not a prompt: its line is still sent for one sentence.
        let professional = await run(raw: spoken, answer: written, bundleID: claude,
                                     tones: ToneSettings(defaultTone: .casual).settingApp(.tone(.professional), bundleIDs: [claude]),
                                     registerLines: true)
        #expect(professional.instructions.contains { IntentRegister.detecting(in: $0) == .professional })
        #expect(SmartCleaner.isShortAsk("Can you loop in Neva on the contract thread?"))
        #expect(!SmartCleaner.isShortAsk("We do not know yet. Can you check the logs?"))
        // A layout direction keeps the line, however short the ask.
        #expect(!SmartCleaner.isShortAsk("make the summary three bullet points no actually five bullet points"))
        #expect(!SmartCleaner.isShortAsk("outline my essay with these sections number them introduction background conclusion"))
        // With no punctuation a long prompt still reads as one sentence; it keeps the line.
        #expect(!SmartCleaner.isShortAsk(String(repeating: "and then check the logs ", count: 6)))
    }

    @Test("a model that is not a whole-transcript model is never sent the line, even with the capability flag on")
    func needsWholeTranscript() async {
        let run = await run(raw: spoken, answer: written, bundleID: claude, tones: .standard, registerLines: true, whole: false)
        for instructions in run.instructions { #expect(IntentRegister.detecting(in: instructions) == nil) }
    }

    @Test("capability off: Casual still gets its word swaps; capability on: the model wrote the register, no swaps")
    func swapsOnlyWithoutTheLine() async {
        let casual = ToneSettings(defaultTone: .casual)
        let off = await run(raw: spoken, answer: written, bundleID: slack, tones: casual, registerLines: false)
        #expect(off.result.text == "We don't know yet", "\(off.result.text)")
        let on = await run(raw: spoken, answer: written, bundleID: slack, tones: casual, registerLines: true)
        #expect(on.result.text == "We do not know yet", "\(on.result.text) \(String(describing: on.result.rejection))")
    }

    @Test("a local model that pauses or comes back during a dictation leaves the dictation as it began")
    func pauseChangesMidDictation() async {
        let casual = ToneSettings(defaultTone: .casual)
        let paused = await run(raw: spoken, answer: written, bundleID: slack, tones: casual, registerLines: true,
                               whole: false, wholeAfterAnswer: true)
        for instructions in paused.instructions { #expect(IntentRegister.detecting(in: instructions) == nil) }
        #expect(paused.result.text == "We don't know yet", "no line was sent, so the swaps give the register: \(paused.result.text)")
        let running = await run(raw: spoken, answer: written, bundleID: slack, tones: casual, registerLines: true,
                                whole: true, wholeAfterAnswer: false)
        #expect(running.result.text == "We do not know yet", "the model wrote the register: \(running.result.text)")
    }

    @Test("Professional swaps are also left out when the line is sent")
    func professionalSwaps() async {
        let professional = ToneSettings(defaultTone: .professional)
        let raw = "Um, we don't know yet."
        let off = await run(raw: raw, answer: "We don't know yet.", bundleID: slack, tones: professional, registerLines: false)
        #expect(off.result.text == "We do not know yet.", "\(off.result.text)")
        let on = await run(raw: raw, answer: "We don't know yet.", bundleID: slack, tones: professional, registerLines: true)
        #expect(on.result.text == "We don't know yet.", "\(on.result.text)")
    }

    @Test("in an AI app the prompt register replaces the tone's swaps when the line is sent, and not otherwise")
    func aiAppSwaps() async {
        let casual = ToneSettings(defaultTone: .casual)
        let off = await run(raw: spoken, answer: written, bundleID: claude, tones: casual, registerLines: false)
        #expect(off.result.text == "We don't know yet", "\(off.result.text)")
        let on = await run(raw: spoken, answer: written, bundleID: claude, tones: casual, registerLines: true)
        #expect(on.result.text == "We do not know yet", "\(on.result.text) \(String(describing: on.result.rejection))")
    }

    @Test("when the model gave no usable answer the line was not written by it, so the swaps still apply")
    func swapsStayWhenModelFails() async {
        let casual = ToneSettings(defaultTone: .casual)
        // An answer that is not made of what was said is refused whole; the rules draft is what is left.
        let result = await run(raw: spoken, answer: "Completely unrelated reply about the weather tomorrow.", bundleID: slack,
                               tones: casual, registerLines: true)
        #expect(result.result.text == "We don't know yet", "\(result.result.text)")
    }

    @Test("As spoken and Refined are unchanged byte for byte whether or not the capability is on")
    func unchangedOutputs() async {
        var asSpoken = ToneSettings.standard
        asSpoken.choice = .asSpoken
        for tones in [ToneSettings.standard, asSpoken] {
            let off = await run(raw: spoken, answer: written, bundleID: slack, tones: tones, registerLines: false)
            let on = await run(raw: spoken, answer: written, bundleID: slack, tones: tones, registerLines: true)
            #expect(off.result.text == on.result.text)
            #expect(off.instructions == on.instructions)
        }
    }
}
