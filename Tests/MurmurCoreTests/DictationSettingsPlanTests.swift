import Foundation
import Testing
@testable import MurmurCore

/// The pipeline settings for one dictation are decided in one place, `PipelineSettings.forDictation`, which the
/// live dictation, the History retry and the eval all call, so a path cannot quietly leave the tone out.
@Suite("Dictation settings plan", .timeLimit(.minutes(1)))
struct DictationSettingsPlanTests {
    private let claude = "com.anthropic.claudefordesktop"

    private func tones(_ tone: DictationTone) -> ToneSettings {
        var tones = ToneSettings.standard
        tones.choice = ToneChoice(tone: tone)
        return tones
    }

    private func settings(_ tones: ToneSettings, bundleID: String?, category: AppCategory? = nil) -> PipelineSettings {
        let mode = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        return PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: tones.dictationLevel), tone: tones, mode: mode,
            category: category ?? AppCategory.classify(bundleID: bundleID, windowTitle: nil),
            bundleID: bundleID, windowTitle: nil)
    }

    @Test("an AI app on the Professional default is polished, laid out as Other, and given the Professional tone")
    func professionalInAnAIApp() {
        let result = settings(tones(.professional), bundleID: claude)
        #expect(result.cleanupOptions.level == .polished)
        #expect(result.tone == .professional)
        #expect(result.style?.context == .other)
        #expect(result.cleanupOptions.isCodeContext == false)
        // The tone's own pass turns a contraction into the spelled-out form.
        let context = result.style!.context
        #expect(ToneRegister.apply(.professional, layout: result.style!.style, to: "I'll send it.", in: context) == "I will send it.")
    }

    @Test("a chat app is marked casual and a code editor is never given a tone")
    func contexts() {
        let chat = settings(tones(.professional), bundleID: "com.tinyspeck.slackmacgap")
        #expect(chat.cleanupOptions.isCasualContext)
        let code = settings(tones(.professional), bundleID: "com.microsoft.VSCode")
        #expect(code.tone == nil)
        #expect(code.cleanupOptions.isCodeContext)
    }

    @Test("As spoken stays verbatim with no tone")
    func asSpoken() {
        var spoken = ToneSettings.standard
        spoken.choice = .asSpoken
        let result = settings(spoken, bundleID: claude)
        #expect(result.cleanupOptions.level == .verbatim)
        #expect(result.tone == nil)
    }

    @Test("a History retry for a dictation made in an app gets that app's tone, as the live dictation did")
    func retryKeepsTheTone() {
        let live = settings(tones(.professional), bundleID: claude)
        let retried = PipelineSettings.forRetry(
            cleanup: CleanupOptions(level: tones(.professional).dictationLevel), tone: tones(.professional),
            mode: Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(.polished), bundleID: claude)
        #expect(retried.tone == live.tone)
        #expect(retried.style?.context == live.style?.context)
        #expect(retried.cleanupOptions.level == live.cleanupOptions.level)
    }

    @Test("a retry with no known app is polished with no layout, as before")
    func retryWithoutAnApp() {
        let retried = PipelineSettings.forRetry(
            cleanup: CleanupOptions(level: .polished), tone: tones(.professional),
            mode: Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(.polished), bundleID: nil)
        #expect(retried.cleanupOptions.level == .polished)
    }

    @Test("a retry uses the saved kind of app, so a dictation made in a Gmail tab keeps the email plan")
    func retryUsesTheSavedCategory() {
        let chrome = "com.google.Chrome"
        let live = settings(tones(.professional), bundleID: chrome, category: .email)
        let retried = PipelineSettings.forRetry(
            cleanup: CleanupOptions(level: tones(.professional).dictationLevel), tone: tones(.professional),
            mode: Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(.polished), bundleID: chrome, category: .email)
        #expect(retried.style?.context == live.style?.context)
        #expect(retried.style?.style == live.style?.style)
        #expect(retried.tone == live.tone)
    }

    @Test("a saved category alone is enough when the saved app is unknown")
    func retryWithOnlyACategory() {
        let retried = PipelineSettings.forRetry(
            cleanup: CleanupOptions(level: .polished), tone: tones(.professional),
            mode: Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(.polished), bundleID: nil, category: .code)
        #expect(retried.cleanupOptions.isCodeContext)
        #expect(retried.tone == nil)
    }
}
