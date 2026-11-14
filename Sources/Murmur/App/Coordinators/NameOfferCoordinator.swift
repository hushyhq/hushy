import Foundation
import MurmurCore
import os

/// The pill's offer to add one new name to the person's words (`PillNameChip`). Decides whether
/// a finished dictation gets one, and writes the word when the person takes it. Behind
/// `FeatureFlags.personMemory`: with the flag off it answers no and touches nothing.
///
/// An offer that is closed or ignored writes nothing anywhere: how often to ask, and which words
/// were already asked about, are kept in memory and gone when the app quits.
@MainActor
final class NameOfferCoordinator {
    /// What one finished dictation gives the choice.
    struct Dictation {
        /// The text that went into the field.
        var pasted: String
        /// The recogniser's word confidences; nil when vocabulary boosting changed the text.
        var confidences: [WordConfidence]?
        /// The person's words as read at key-down; nil when memory was not ready or is paused.
        var index: MemoryIndex?
        /// The Dictionary's words, which are known too.
        var vocabulary: VocabularyContext = .empty
        /// Learning is allowed for this dictation (`LearningGate`): not an excluded app, a
        /// password manager, code or another language, and "Learn from my edits" is on.
        var isLearningAllowed: Bool
    }

    static let saveFailedMessage = "Couldn't save that word"
    /// The spelling the person typed is one they told Hushy to forget; only they can bring it back.
    static let forgottenMessage = "You asked Hushy to forget that word"

    /// What to say instead of "Added" when the word did not go in, or nil when it did.
    static func failureMessage(for write: MemoryWrite?) -> String? {
        switch write {
        case .written, .merged: nil
        case .forgotten: forgottenMessage
        case .full, .empty, .missing, nil: saveFailedMessage
        }
    }

    private let memory: MemoryStore
    private let isEnabled: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let isDictionaryWord: (String) -> Bool
    private(set) var pacing = NameOfferPacing()
    /// Says, on the pill, that a word could not be saved (the dictation controller's error row).
    var onSaveFailed: (@MainActor (String) -> Void)?
    /// The last word's write, so a test can wait for it.
    private(set) var lastWrite: Task<MemoryWrite?, Never>?
    private let log = Logger(subsystem: "app.hushy", category: "name-offer")

    init(
        memory: MemoryStore = .shared(), isEnabled: @escaping @MainActor () -> Bool = { FeatureFlags.personMemory },
        now: @escaping @MainActor () -> Date = { Date() },
        isDictionaryWord: @escaping (String) -> Bool = NameOfferChoice.isDictionaryWord
    ) {
        self.memory = memory
        self.isEnabled = isEnabled
        self.now = now
        self.isDictionaryWord = isDictionaryWord
    }

    /// Shows Done with an offer when this dictation has one, and says whether it did. Only a
    /// plain, confirmed paste is ever followed by an offer: Done with nothing else to say.
    func present(_ presentation: DeliveryPresentation, on pill: PillModel, for dictation: Dictation) -> Bool {
        guard isEnabled(), dictation.isLearningAllowed,
              case .pill(.done(let words, let usedContext, asHeard: false, notSent: false, notARewrite: false)) = presentation.feedback,
              let candidate = candidate(for: dictation) else { return false }
        pacing.shown(NameOfferChoice.key(candidate.word), at: now())
        log.notice("name offer shown")
        pill.present(nameOffer: candidate.word, words: words, usedContext: usedContext) { [weak self, weak pill] answer in
            self?.settle(answer, on: pill)
        }
        return true
    }

    /// The word this dictation would offer now, or nil. Changes nothing.
    func candidate(for dictation: Dictation) -> NameCandidate? {
        guard let index = dictation.index, pacing.allows(at: now()) else { return nil }
        let known = Set(dictation.vocabulary.terms.flatMap { [$0.text] + $0.aliases }.flatMap { text in
            [MemoryIndex.key(text)] + CorrectionAlignment.tokens(text).map(NameOfferChoice.key)
        })
        return NameOfferChoice.candidate(
            pasted: dictation.pasted, confidences: dictation.confidences, index: index, knownKeys: known,
            skipping: pacing.offeredKeys, isDictionaryWord: isDictionaryWord)
    }

    /// What the person did with the offer. Only adding writes anything.
    private func settle(_ answer: NameOfferAnswer, on pill: PillModel?) {
        switch answer {
        case .add(let word, let heardAs):
            pacing.answered(added: true)
            let entry = MemoryEntry(kind: .term, value: word, heardAs: heardAs.map { [$0] } ?? [], createdAt: now())
            lastWrite = Task { [memory, log, weak self, weak pill] in
                let write = try? await memory.add(entry)
                log.notice("name offer added heardAs \(heardAs == nil ? 0 : 1) written \(write == nil ? 0 : 1)")
                // The row already says "Added": if the word did not go in, say so instead.
                if let message = Self.failureMessage(for: write), pill?.state.nameOfferPhase == .added {
                    self?.onSaveFailed?(message)
                }
                return write
            }
        case .dismissed:
            pacing.answered(added: false)
            log.notice("name offer closed")
        case .ignored:
            pacing.answered(added: false)
            log.notice("name offer ignored")
        }
    }
}
