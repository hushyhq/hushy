import FluidAudio
import Foundation

/// `VocabularyBoostingSession.rescore` in its two halves, so the release can start the CTC pass (about 130 ms, a
/// fixed 15 s window) together with the primary recogniser pass instead of after it. The CTC pass reads only the
/// audio; the rescore then needs the transcript and its token timings.
///
/// Both halves are FluidAudio's own public calls with the session's arguments, so the text is the session's: the
/// spotter and rescorer are built from the session's tokenized vocabulary and the same models and rescorer config.
/// The one difference is the return value: the rescored text only when the rescorer changed it, nil otherwise.
/// `SpeechEngine` treats nil and "the same text" alike, so a detection without a replacement changes nothing.
/// `murmur-eval release-paste --boost ab` compares the two paths on the same audio.
///
/// A copy of `Sources/Murmur/Speech/BoostingPasses.swift` (the eval cannot import the app target), as `Engine`
/// mirrors `SpeechEngine`. Keep the two the same.
struct BoostingPasses: Sendable {
    let vocabulary: CustomVocabularyContext
    private let spotter: CtcKeywordSpotter
    private let rescorer: VocabularyRescorer
    private let sizeConfig: ContextBiasingConstants.VocabSizeConfig

    init(session: VocabularyBoostingSession, models: CtcModels, config: VocabularyRescorer.Config) async throws {
        vocabulary = session.vocabulary
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        self.spotter = spotter
        sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: session.vocabulary.terms.count)
        rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: session.vocabulary, config: config,
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: models.variant))
    }

    /// The CTC pass over the audio. Nil on failure, which the session also absorbs (boosting never breaks a dictation).
    func spot(_ audio: [Float]) async -> CtcKeywordSpotter.SpotKeywordsResult? {
        guard !audio.isEmpty else { return nil }
        return try? await spotter.spotKeywordsWithLogProbs(audioSamples: audio, customVocabulary: vocabulary, minScore: nil)
    }

    /// The rescored transcript when the rescorer replaced something, else nil.
    func rescoredText(_ text: String, tokenTimings: [TokenTiming], spot: CtcKeywordSpotter.SpotKeywordsResult) -> String? {
        guard !tokenTimings.isEmpty, !spot.logProbs.isEmpty else { return nil }
        let output = rescorer.ctcTokenRescore(
            transcript: text, tokenTimings: tokenTimings, logProbs: spot.logProbs, frameDuration: spot.frameDuration,
            cbw: sizeConfig.cbw, marginSeconds: 0.5,
            minSimilarity: max(sizeConfig.minSimilarity, vocabulary.minSimilarity))
        return output.wasModified ? output.text : nil
    }
}
