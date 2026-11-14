import Foundation

extension PipelineSettings {
    /// The settings one dictation runs with, decided here and nowhere else: the tone plan for the app
    /// (level, tone, layout), the mode's level, and the options that depend on the kind of app. The live
    /// dictation, the History retry and the eval all call this, so a path cannot leave the tone out.
    ///
    /// - Parameters:
    ///   - cleanup: the app-wide options (voice commands, American spelling…); the level is replaced.
    ///   - mode: the mode resolved for this dictation. Its own level wins over the app-wide one. The level an app or
    ///     site in As spoken gets reaches the dictation through it: the stock Default mode is resolved with
    ///     `ToneSettings.dictationLevel(for:site:)` at key-down (`Mode.resolvingAppCleanupLevel`).
    ///   - site: the placed website a browser tab was matched to at key-down (`WebsiteMatcher`), or nil.
    public static func forDictation(
        cleanup: CleanupOptions, tone tones: ToneSettings, mode: Mode, category: AppCategory,
        bundleID: String?, windowTitle: String?, site: String? = nil, personalizer: Personalizer = Personalizer(),
        projectVocabulary: ProjectVocabulary? = nil, contextTerms: [String] = [],
        installedApps: [InstalledAppInfo] = []
    ) -> PipelineSettings {
        let plan = tones.plan(for: category, bundleID: bundleID, site: site)
        let isCodeContext = category == .code
        var options = cleanup
        options.level = plan.level(for: mode)
        options.isCodeContext = isCodeContext
        options.register = tones.register(for: category, bundleID: bundleID, site: site)
        // An AI app (Claude, ChatGPT, Codex) is where people dictate prompts in plain English: it is a prose app with full
        // cleanup, lists and paragraphs, and no code handling (founder, 2026-10-23).
        options.isCasualContext = [.personalMessages, .workMessages].contains(category)
        options.technicalTokens = TechnicalTokenContext.make(category: category, bundleID: bundleID, windowTitle: windowTitle)
        options.projectVocabulary = isCodeContext ? projectVocabulary : nil
        options.knownNames = personalizer.vocabulary + installedApps.map(\.name)
        return PipelineSettings(
            cleanupOptions: options, personalizer: personalizer, style: plan.style, tone: plan.tone,
            mode: mode, contextTerms: contextTerms, installedApps: installedApps,
            frontmostBundleID: bundleID,
            focusedAgentSession: category == .aiPrompts && TerminalAgentContext.isCandidate(bundleID: bundleID),
            aiPromptApp: category == .aiPrompts)
    }

    /// The settings for re-running a saved dictation from History: the same plan the live dictation used for
    /// the kind of app it was made in. That kind is the saved category when there is one (a dictation made in a
    /// Gmail tab was email, which the browser's bundle ID alone cannot say), else the one the saved app's bundle ID
    /// gives. With neither there is no kind of app to plan for, so it is cleaned at the app-wide level with no layout.
    public static func forRetry(
        cleanup: CleanupOptions, tone tones: ToneSettings, mode: Mode, bundleID: String?,
        category savedCategory: AppCategory? = nil, personalizer: Personalizer = Personalizer()
    ) -> PipelineSettings {
        guard let category = savedCategory ?? bundleID.map({ AppCategory.classify(bundleID: $0) }) else {
            return PipelineSettings(cleanupOptions: cleanup, personalizer: personalizer, style: nil)
        }
        return forDictation(
            cleanup: cleanup, tone: tones, mode: mode, category: category,
            bundleID: bundleID, windowTitle: nil, personalizer: personalizer)
    }
}
