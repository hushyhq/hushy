import Foundation
import MurmurCore

/// Starts at key-down and returns immediately. A slow snapshot misses this dictation.
@MainActor
final class EditLearningPreparation {
    private(set) var keep: KeepHeardSet = .empty
    private(set) var learned: PersonBlockAssembler.Prepared?
    var screenTerms: [String] = []
    private(set) var task: Task<Void, Never>?

    static func capture(store: Store, app: String?) -> EditLearningPreparation {
        let preparation = EditLearningPreparation()
        preparation.task = Task { [weak preparation] in
            let snapshot = await Task.detached(priority: .utility) {
                let keep = (try? store.keepHeardSet(for: app)) ?? .empty
                let learned = app.flatMap { try? PersonBlockAssembler.prepareLearned(history: store, app: $0) }
                return (keep, learned)
            }.value
            preparation?.keep = snapshot.0
            preparation?.learned = snapshot.1
        }
        return preparation
    }
}

extension PipelineSettings {
    func termEvidence(frontmostName: String?, screenTerms: [String] = []) -> TermEvidence {
        TermEvidence(dictionary: personalizer.dictionary, screenTerms: contextTerms + screenTerms,
                     appNames: installedApps.map(\.name) + [frontmostName].compactMap { $0 })
    }
}

extension DictationController {
    struct SessionSettings {
        let cleanupOptions: CleanupOptions
        let tone: ToneSettings
        let retainAudio: Bool
        let personalizer: Personalizer
        /// The mode resolved for this session at key-down (see `AppSettings.consumeActiveMode`):
        /// a manual mode-chip pick for this one dictation, else the app assigned to the focused
        /// app, else Default. Captured once per session, like every other field here, so a mode
        /// switch mid-recording never changes which mode a dictation already in flight uses.
        /// `MurmurCore.Mode`, qualified because this file's own `Mode` enum (`.pushToTalk`/
        /// `.handsFree`) shadows the name.
        let mode: MurmurCore.Mode
        /// Candidate names/terms pulled from the surrounding editor text by `ContextReader` +
        /// `ContextExtractor`, for "Context awareness" (off by default; see
        /// `AppSettings.contextAwarenessEnabled`). Captured once at key-down alongside everything
        /// else in `SessionSettings`, used for this one dictation's vocabulary boosting and
        /// spelling-fix pass, and never written anywhere — see `.claude/DECISIONS.md`.
        var contextTerms: [String] = []
        /// The conversation read from the focused window while the person speaks (`WindowContextReader`): its terms
        /// join `contextTerms` once the read has finished, and not at all if it is late. nil when nothing is read.
        var windowContext: WindowContextBox?
        let projectVocabulary: ProjectVocabulary?
        /// Set on a Try again run: the History row its failed first attempt saved (the save may
        /// still be under way). The run fills that row in and writes no second audio file (`save`).
        var retryOf: Task<Dictation?, Never>? = nil
        var learning = EditLearningPreparation()
        /// The personal lexicon's boost terms at key-down (`LexiconSnapshot.boostTerms`); empty without evidence.
        var lexiconTerms: [VocabularyTerm] = []
        /// The selection at key-down, for voice edit (`SelectionReader`); nil without one or with the flag off.
        var selection: SelectedText?
    }

}

extension DictationController {
    /// Retry uses the saved app's exceptions, even if a different app is now frontmost.
    func retrySettings(for dictation: Dictation) -> PipelineSettings {
        var run = PipelineSettings.forRetry(
            cleanup: settings.cleanupOptions, tone: settings.toneSettings,
            mode: settings.previewActiveMode(bundleID: dictation.appBundleID), bundleID: dictation.appBundleID,
            category: dictation.appCategory.flatMap(AppCategory.init(rawValue:)), personalizer: personalizer)
        run.keepHeard = (try? store.keepHeardSet(for: dictation.appBundleID)) ?? .empty
        return run
    }
}
