import MurmurCore
import os

extension DictationController {
    private nonisolated static let siteLog = Logger(subsystem: "app.hushy", category: "dictation")

    /// The focused app and field at key-down, and in a browser the website placed on a tone that the tab is
    /// (`WebPageSite`, read only while some website is placed).
    func keyDownTarget() -> FocusTarget {
        let target = FocusTarget.current(sites: settings.toneSettings.siteMatcher, forDictation: true)
        if let lookup = target.siteLookup {
            // The site key at most: never the address, the title or the page.
            Self.siteLog.notice("key-down: website \(WebsiteMatcher.logKey(lookup.key), privacy: .public) via \(lookup.source.rawValue, privacy: .public) in \(lookup.microseconds) µs, \(lookup.steps) steps")
        }
        return target
    }

    /// Everything a dictation captures once, at key-down.
    ///
    /// The level is this dictation's: the mode resolved for the focused app (or placed website), which is word for
    /// word when that app or site sits in As spoken, unless a mode was picked for this one dictation. The model
    /// warm-up at key-down is skipped when it is word for word.
    func sessionSettings(for target: FocusTarget, contextTerms: [String] = []) -> SessionSettings {
        let personalizer = personalizer.scoped(to: target.bundleID)
        let mode = settings.consumeActiveMode(bundleID: target.bundleID, site: target.site)
        var cleanupOptions = settings.cleanupOptions
        cleanupOptions.level = mode.cleanupLevel
        cleanupOptions.protectedTerms = personalizer.vocabulary + contextTerms
        return SessionSettings(
            cleanupOptions: cleanupOptions,
            tone: settings.toneSettings,
            retainAudio: settings.audioRetentionDays != 0,
            personalizer: personalizer,
            mode: mode,
            contextTerms: contextTerms,
            projectVocabulary: projectVocabulary,
            learning: .capture(store: store, app: target.bundleID),
            lexiconTerms: lexicon.boostTerms(excluding: Set(personalizer.vocabulary.map { $0.lowercased() })))
    }

    /// Builds immutable cleanup settings, style, and vocabulary for one session.
    func pipelineSettings(for target: FocusTarget, settings: SessionSettings) -> PipelineSettings {
        // Terms the window read found before this call join the field's, for the vocabulary, the spelling fixer and the
        // protected terms; before it has finished (or when it found none) the field's terms stand.
        var cleanup = settings.cleanupOptions
        var contextTerms = settings.contextTerms
        if let windowTerms = settings.windowContext?.terms {
            let known = Set(cleanup.protectedTerms.map { $0.lowercased() })
            cleanup.protectedTerms += windowTerms.filter { !known.contains($0.lowercased()) }
            contextTerms = windowTerms
        }
        contextTerms = ScreenBoostPolicy.filter(contextTerms).terms
        var pipeline = PipelineSettings.forDictation(
            cleanup: cleanup, tone: settings.tone, mode: settings.mode, category: target.category,
            bundleID: target.bundleID, windowTitle: target.windowTitle, site: target.site, personalizer: settings.personalizer,
            projectVocabulary: settings.projectVocabulary, contextTerms: contextTerms,
            installedApps: RankedInstalledApps.shared.apps(from: InstalledAppCatalog.shared.snapshot()))
        pipeline.keepHeard = settings.learning.keep
        pipeline.lexiconTerms = settings.lexiconTerms
        onScreenTerms?(contextTerms)
        return pipeline
    }
}
