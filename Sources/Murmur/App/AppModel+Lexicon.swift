import MurmurCore
import Observation

extension AppModel {
    /// Starts the personal lexicon: built from History, learning and meeting attendees in the background, rebuilt when
    /// History or learning changes, and handed to dictation. Not in a disposable run (snapshots, tests), which must
    /// not write the pack state file. Off with "Learn from my edits" off or `FeatureFlags.personalLexicon` false.
    func startLexicon() {
        guard !isDisposableRun else { return }
        let coordinator = LexiconCoordinator(store: store) { [weak self] in
            FeatureFlags.personalLexicon && (self?.settings.learnFromEdits ?? false)
        }
        coordinator.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.dictation.lexicon = snapshot
            self.warmStandingVocabulary()
        }
        dictation.onScreenTerms = { [weak coordinator] terms in coordinator?.recordScreen(terms) }
        library.onHistoryChange = { [weak coordinator] in coordinator?.scheduleRebuild() }
        library.onLexiconErase = { [weak coordinator] in _ = coordinator?.eraseScreenEvidence() }
        setLexicon(coordinator)
        coordinator.scheduleRebuild()
        trackLexiconSwitch()
    }

    /// "Learn from my edits" switched off: the rebuild erases the pack state file and empties the lexicon; switched
    /// on: it rebuilds. (`FeatureFlags.personalLexicon` is read at every rebuild, so the kill switch erases on the next.)
    private func trackLexiconSwitch() {
        withObservationTracking {
            _ = settings.learnFromEdits
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.settings.learnFromEdits { self.lexicon?.scheduleRebuild() } else { self.lexicon?.eraseScreenEvidence() }
                self.trackLexiconSwitch()
            }
        }
    }

    /// Keeps the boosting session warm for the vocabulary every dictation starts from: the Dictionary, learned terms
    /// and the lexicon's boost terms (rebuilds only the session).
    func warmStandingVocabulary() {
        var standing = PipelineSettings(personalizer: dictation.personalizer)
        standing.lexiconTerms = dictation.lexicon.boostTerms(
            excluding: Set(dictation.personalizer.vocabulary.map { $0.lowercased() }))
        let vocabulary = standing.vocabulary
        let speech = speech
        Task { await speech.setBoostingVocabulary(vocabulary) }
    }
}
