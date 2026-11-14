import Foundation
import Testing
@testable import MurmurCore

/// The AI apps (Claude, ChatGPT, Codex) are where people dictate prompts in plain English (founder, 2026-10-23). They are prose
/// apps with full cleanup, lists and paragraphs, and no code handling: no spoken code is written, and no guard holds a word
/// such as "GitHub", "README" or "PRs" to the draft. Only a code editor or terminal (`isCodeContext`) keeps code literal.
@Suite("AI apps are prose apps", .timeLimit(.minutes(1)))
struct AICodingAppTests {
    private let claude = "com.anthropic.claudefordesktop"
    private let chatGPT = "com.openai.chat"
    private let terminal = "com.apple.Terminal"

    private func settings(_ tones: ToneSettings = .standard, bundleID: String) -> PipelineSettings {
        let resolved = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        return PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: tones.dictationLevel), tone: tones, mode: resolved,
            category: AppCategory.classify(bundleID: bundleID, windowTitle: nil), bundleID: bundleID, windowTitle: nil)
    }

    private func clean(_ spoken: String, bundleID: String, tones: ToneSettings = .standard, model: some LanguageModel,
                       strategy: SmartCleaner.Strategy? = .model) async -> PipelineResult {
        let pipeline = DictationPipeline(transcriber: NoSpeech(), cleaner: SmartCleaner(model: model, health: ModelHealth()))
        return await pipeline.clean(spoken, settings: settings(tones, bundleID: bundleID), strategy: strategy, incremental: false)
    }

    // MARK: The plan

    @Test("Claude and ChatGPT are AI prompt apps with a tone, and neither is a code context; a terminal is")
    func aiAppsAreNotCodeContexts() {
        #expect(AppCategory.classify(bundleID: claude) == .aiPrompts)
        #expect(AppCategory.classify(bundleID: chatGPT) == .aiPrompts)
        for id in [claude, chatGPT] {
            let options = settings(bundleID: id).cleanupOptions
            #expect(!options.isCodeContext, "\(id)")
            #expect(options.level == .polished, "\(id)")
            let row = AppToneRow.row(for: KnownWritingApps.app(forBundleID: id)!, in: .standard)
            #expect(row.usesTone && row.isAI, "\(id)")
        }
        #expect(settings(bundleID: terminal).cleanupOptions.isCodeContext)
    }

    @Test("the Claude app keeps its tone and style, and an app's own tone choice reaches it")
    func keepsItsToneAndStyle() {
        let result = settings(bundleID: claude)
        #expect(result.style != nil && result.tone != nil)
        let casual = settings(ToneSettings.standard.settingApp(.tone(.casual), bundleIDs: [claude]), bundleID: claude)
        #expect(casual.tone == .casual)
    }

    @Test("an app that is not an AI app is unchanged: code apps have no style, a chat app has the style and no code handling")
    func otherAppsAreUnchanged() {
        for id in [terminal, "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.microsoft.VSCode"] {
            let editor = settings(bundleID: id)
            #expect(editor.cleanupOptions.isCodeContext && editor.style == nil && editor.tone == nil, "\(id)")
        }
        let notes = settings(bundleID: "com.apple.Notes")
        #expect(!notes.cleanupOptions.isCodeContext && notes.style != nil)
        // A terminal still reads a plain-word line as a command.
        let terminalOptions = settings(bundleID: terminal).cleanupOptions
        #expect(TextCleaner(options: terminalOptions).clean("git push origin main").text == "git push origin main")
    }

    // MARK: Prose in the AI apps

    @Test("the rules treat a spoken file name or flag in Claude exactly as in ChatGPT: as words, since nobody types code by voice there")
    func rulesAreTheSameAsChatGPT() {
        let claudeOptions = settings(bundleID: claude).cleanupOptions
        let chatOptions = settings(bundleID: chatGPT).cleanupOptions
        for spoken in [
            "please run swift test dash dash parallel and tell me which ones fail", "can you open auth dot swift and check the retry",
            "the total equals one thousand dollars", "camel case is hard to read", "slash the budget by ten percent",
            "update the readme so new people can set it up and then merge the prs",
        ] {
            #expect(TextCleaner(options: claudeOptions).clean(spoken).text == TextCleaner(options: chatOptions).clean(spoken).text, "\(spoken)")
        }
        #expect(TextCleaner(options: claudeOptions).clean("git push origin main").text == "Git push origin main.")
    }

    @Test("a model answer that capitalises README, PRs, GitHub or writes README.md stands in Claude, as in ChatGPT")
    func properCapitalsStand() async {
        let cases = [
            ("can you open the pull request on github and merge it when the tests pass",
             "Can you open the pull request on GitHub and merge it when the tests pass?"),
            ("update the readme dot md and then merge the prs after you review them",
             "Update the README.md and then merge the PRs after you review them."),
            ("we should move the site from javascript to typescript and check it on iphone",
             "We should move the site from JavaScript to TypeScript and check it on iPhone."),
        ]
        for (spoken, answer) in cases {
            let model = Rewrite { _ in answer }
            for id in [claude, chatGPT] {
                let output = await clean(spoken, bundleID: id, model: model)
                #expect(output.text == answer && output.usedModel && output.rejection == nil, "\(id): \(spoken) -> \(output.text)")
            }
        }
    }

    @Test("a model answer in Claude is not held to a token of the draft: a rewritten file name stands as it does in ChatGPT")
    func noTokenGuard() async {
        let model = Rewrite { _ in "Can you open auth.swift and call parse_header for me?" }
        for id in [claude, chatGPT] {
            let output = await clean("can you open auth dot swift and call parse header for me", bundleID: id, model: model)
            #expect(output.text.contains("parse_header"), "\(id)")
        }
    }

    @Test("ordinary prose goes through the model exactly as in ChatGPT, including a sentence with an everyday symbol word")
    func ordinaryProseIsUnchanged() async {
        let model = Rewrite { draft in draft.prefix(1).uppercased() + draft.dropFirst() + (draft.hasSuffix(".") ? "" : ".") }
        for spoken in [
            "the tests is failing on the login page and I have three more", "the total equals one thousand dollars",
            "we need to quote the report and quote the memo again", "sounds good thanks",
        ] {
            let inClaude = await clean(spoken, bundleID: claude, model: model)
            let inChat = await clean(spoken, bundleID: chatGPT, model: model)
            #expect(inClaude.text == inChat.text && inClaude.usedModel == inChat.usedModel, "\(spoken)")
        }
    }

    // MARK: Groups and prewarm

    @Test("the Claude app keeps its groups and prewarm: later groups are hits, as in any other prose app, and a terminal has none")
    func groupsAndPrewarmAreKept() async {
        let streamed = (0..<9).map { "Please check the report for region number \($0) in file report dot swift today." }.joined(separator: " ")
        let groups = TextSegmentation.groups(streamed)
        #expect(groups.count >= 3)
        var hits: [String: Int] = [:]
        for (name, id) in [("claude", claude), ("chatgpt", chatGPT), ("terminal", terminal)] {
            let cleaner = SmartCleaner()
            let options = settings(bundleID: id).cleanupOptions
            for group in groups where !group.isTail {
                await cleaner.prewarmGroup(group.text, options: options, strategy: .hybrid)
            }
            let output = await cleaner.clean(streamed, options: options, strategy: .hybrid)
            hits[name] = output.groupSources.filter { $0 == .prewarmHit }.count
        }
        #expect(hits["claude"] == groups.count - 1)
        #expect(hits["claude"] == hits["chatgpt"])
        #expect(hits["terminal"] == 0)
    }
}

private struct NoSpeech: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

private struct Rewrite: LanguageModel {
    let answer: @Sendable (String) -> String
    init(_ answer: @escaping @Sendable (String) -> String) { self.answer = answer }
    var identifier: String { "synthetic-ai-coding-app" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
        return String(decoding: try JSONEncoder().encode(["text": answer(draft)]), as: UTF8.self)
    }
}
