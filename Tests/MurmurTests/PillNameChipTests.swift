import AppKit
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The pill's quiet offer to add one new name after a dictation. A memory folder of its own per
/// test, a clock the test moves, a small word list given here; every name is invented. The flag
/// is passed in, never read from or written to anyone's defaults.
@MainActor
@Suite("Pill — the name offer")
struct PillNameChipTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-name-offer-\(UUID())")
    private static let ordinary: Set<String> = ["needs", "the", "deck", "by", "friday", "ask", "about", "plan", "please"]
    private static let text = "Pria needs the deck by Friday."

    /// A clock a test can move.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private func coordinator(enabled: Bool = true, clock: Clock = Clock()) -> NameOfferCoordinator {
        NameOfferCoordinator(memory: MemoryStore(root: root), isEnabled: { enabled }, now: { clock.now },
                             isDictionaryWord: { Self.ordinary.contains($0) })
    }

    /// A finished dictation in which the recogniser was unsure of `unsure`.
    private func dictation(_ text: String = PillNameChipTests.text, unsure: String = "pria", index: MemoryIndex? = MemoryIndex(entries: []),
                           allowed: Bool = true, boosted: Bool = false) -> NameOfferCoordinator.Dictation {
        let confidences = CorrectionAlignment.tokens(text).map {
            WordConfidence(word: $0, confidence: NameOfferChoice.key($0) == unsure ? 0.5 : 0.97)
        }
        return .init(pasted: text, confidences: boosted ? nil : confidences, index: index, isLearningAllowed: allowed)
    }

    private func done(_ text: String = PillNameChipTests.text, result: DeliveryResult = .pasted, asHeard: Bool = false) -> DeliveryPresentation {
        DeliveryPresentation.make(result, text: text, usedContext: false, asHeard: asHeard)
    }

    private func files() -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    private func storedTerms() async throws -> [MemoryEntry] {
        try await MemoryStore(root: root).index().terms
    }

    // MARK: The offer

    @Test("a plain Done with one new, unsure name becomes Done with an offer, and the state carries no word")
    func offerShows() {
        defer { try? FileManager.default.removeItem(at: root) }
        let pill = PillModel()
        #expect(coordinator().present(done(), on: pill, for: dictation()))
        #expect(pill.state == .nameOffer(.offered, words: 6, usedContext: false))
        #expect(pill.nameOffer?.heard == "Pria")
        // The word is beside the state, as the not-pasted card's words are: never in it.
        #expect(!String(describing: pill.state).contains("Pria"))
        #expect(pill.state.isInteractive)
        #expect(pill.state.selfDismissDelay == PillState.nameOfferDelay)
        #expect(pill.accessibilityLabel.contains("Pria"))
        #expect(files().isEmpty, "showing an offer writes nothing")
    }

    @Test("with the flag off nothing is offered and nothing is touched")
    func flagOff() {
        defer { try? FileManager.default.removeItem(at: root) }
        let pill = PillModel()
        let coordinator = coordinator(enabled: false)
        #expect(!coordinator.present(done(), on: pill, for: dictation()))
        #expect(pill.state == .idle)
        #expect(pill.nameOffer == nil)
        #expect(coordinator.pacing == NameOfferPacing())
        #expect(files().isEmpty)
        // The presentation the caller goes on to show is Done exactly as it was.
        #expect(done().feedback == .pill(.done(words: 6)))
        #expect(done().hold == .milliseconds(700))
    }

    nonisolated private static let otherResults: [DeliveryResult] = [
        .pastedReturnSkipped(nil), .unknownUnreadable, .noField(copied: true), .heldForSecureField(nil), .unknownNotLanded,
    ]

    @Test("only a plain, confirmed paste is followed by an offer", arguments: otherResults)
    func otherOutcomes(result: DeliveryResult) {
        defer { try? FileManager.default.removeItem(at: root) }
        let pill = PillModel()
        #expect(!coordinator().present(done(result: result), on: pill, for: dictation()))
        #expect(pill.state == .idle)
    }

    @Test("no offer when the model did not answer in time, where learning is refused, when memory was not read or is paused, or after boosting")
    func refusals() {
        defer { try? FileManager.default.removeItem(at: root) }
        let pill = PillModel()
        let coordinator = coordinator()
        #expect(!coordinator.present(done(asHeard: true), on: pill, for: dictation()))
        #expect(!coordinator.present(done(), on: pill, for: dictation(allowed: false)))
        #expect(!coordinator.present(done(), on: pill, for: dictation(index: nil)))
        #expect(!coordinator.present(done(), on: pill, for: dictation(boosted: true)))
        #expect(!coordinator.present(done(), on: pill, for: dictation(unsure: "nothing")))
        #expect(pill.state == .idle)
        #expect(coordinator.pacing == NameOfferPacing(), "a dictation with no offer does not count as one")
    }

    @Test("a word in the Dictionary, in the person's words or forgotten is not offered")
    func knownWords() {
        defer { try? FileManager.default.removeItem(at: root) }
        let pill = PillModel()
        let coordinator = coordinator()
        var inDictionary = dictation()
        inDictionary.vocabulary = VocabularyContext(terms: [VocabularyTerm(text: "Pria Raman")])
        #expect(!coordinator.present(done(), on: pill, for: inDictionary))
        let theirs = MemoryIndex(entries: [MemoryEntry(kind: .term, value: "Priya", heardAs: ["Pria"])])
        #expect(!coordinator.present(done(), on: pill, for: dictation(index: theirs)))
        let forgotten = MemoryIndex(entries: [MemoryEntry(kind: .forgotten, value: "Pria")])
        #expect(!coordinator.present(done(), on: pill, for: dictation(index: forgotten)))
        #expect(pill.state == .idle)
    }

    // MARK: Answers

    @Test("one tap on the tick adds the word as Hushy wrote it")
    func tapAdds() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pill = PillModel()
        let coordinator = coordinator()
        #expect(coordinator.present(done(), on: pill, for: dictation()))
        pill.acceptNameOffer()
        #expect(pill.state == .nameOffer(.added, words: 6, usedContext: false))
        #expect(!pill.state.isInteractive)
        #expect(pill.state.selfDismissDelay == PillState.nameAddedDelay)
        let write = await coordinator.lastWrite?.value
        #expect(write == MemoryWrite.written)
        let terms = try await storedTerms()
        #expect(terms.map(\.value) == ["Pria"])
        #expect(terms.first?.heardAs == [])
        #expect(coordinator.pacing.unanswered == 0)
        // A second tap, or the row leaving, adds nothing more.
        pill.acceptNameOffer()
        pill.state = .idle
        #expect(pill.nameOffer == nil)
        let after = try await storedTerms()
        #expect(after.count == 1)
    }

    @Test("correcting the spelling first adds the corrected word and keeps what was written as its heard-as")
    func correctedSpelling() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pill = PillModel()
        let coordinator = coordinator()
        #expect(coordinator.present(done(), on: pill, for: dictation()))
        pill.openNameOffer()
        #expect(pill.state == .nameOffer(.editing, words: 6, usedContext: false))
        #expect(pill.isEditingName)
        #expect(pill.nameOffer?.spelling == "Pria", "the field opens with the word in it")
        pill.nameOffer?.spelling = "  Priya "
        #expect(pill.isTypingName, "the row is not cleared under someone's fingers")
        pill.acceptNameOffer()
        let write = await coordinator.lastWrite?.value
        #expect(write == MemoryWrite.written)
        let terms = try await storedTerms()
        #expect(terms.map(\.value) == ["Priya"])
        #expect(terms.first?.heardAs == ["Pria"])
        // The folder holds the word and how it was written. No audio, nothing else of the dictation.
        #expect(files() == ["terms.md"])
        let file = try String(contentsOf: root.appendingPathComponent("terms.md"), encoding: .utf8)
        #expect(!file.contains("deck") && !file.contains("Friday"))
        // The next time that spelling is written, recall brings the word back.
        let index = try await MemoryStore(root: root).index()
        #expect(TermRecall.recall("Pria needs it", from: index).map(\.value) == ["Priya"])
    }

    @Test("a change of capitals alone is the same word, and a blank spelling adds nothing")
    func spellingEdges() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pill = PillModel()
        let coordinator = coordinator()
        #expect(coordinator.present(done(), on: pill, for: dictation()))
        pill.openNameOffer()
        pill.nameOffer?.spelling = "   "
        pill.acceptNameOffer()
        #expect(pill.state.nameOfferPhase == .editing, "a blank field does not add")
        #expect(coordinator.lastWrite == nil)
        pill.nameOffer?.spelling = "PRIA"
        pill.acceptNameOffer()
        let write = await coordinator.lastWrite?.value
        #expect(write == MemoryWrite.written)
        let terms = try await storedTerms()
        #expect(terms.map(\.value) == ["PRIA"])
        #expect(terms.first?.heardAs == [])
        #expect(NameOffer(heard: "Pria").word == "Pria")
        var long = NameOffer(heard: "Pria")
        long.spelling = String(repeating: "a", count: 90)
        #expect(long.word?.count == NameOffer.spellingLimit)
    }

    @Test("a spelling the person told Hushy to forget is not added, and the pill says so instead of Added")
    func correctedToAForgottenWord() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        try await memory.add(MemoryEntry(kind: .term, value: "Priya"))
        let before = try await memory.index()
        let entry = try #require(before.terms.first)
        try await memory.forget(id: entry.id)
        let pill = PillModel()
        let coordinator = coordinator()
        var said: [String] = []
        coordinator.onSaveFailed = { said.append($0) }
        #expect(coordinator.present(done(), on: pill, for: dictation()))
        pill.openNameOffer()
        pill.nameOffer?.spelling = "Priya"
        pill.acceptNameOffer()
        let write = await coordinator.lastWrite?.value
        #expect(write == MemoryWrite.forgotten)
        #expect(said == [NameOfferCoordinator.forgottenMessage])
        let terms = try await storedTerms()
        #expect(terms.isEmpty)
        #expect(NameOfferCoordinator.failureMessage(for: .written) == nil)
        #expect(NameOfferCoordinator.failureMessage(for: .merged) == nil)
        #expect(NameOfferCoordinator.failureMessage(for: nil) == NameOfferCoordinator.saveFailedMessage)
    }

    @Test("an ignored offer leaves no trace: timed out, closed, or replaced by the next dictation", arguments: [0, 1, 2, 3])
    func ignoredLeavesNoTrace(way: Int) {
        defer { try? FileManager.default.removeItem(at: root) }
        let pill = PillModel()
        let coordinator = coordinator()
        #expect(coordinator.present(done(), on: pill, for: dictation()))
        switch way {
        case 0: pill.state = .idle              // its time ran out
        case 1: pill.dismissNameOffer()         // ✕
        case 2: pill.state = .listening         // the next dictation
        default:                                // opened, then esc
            pill.openNameOffer()
            pill.nameOffer?.spelling = "Priya"
            pill.dismissNameOffer()
        }
        #expect(pill.nameOffer == nil)
        #expect(pill.onNameOfferAnswer == nil)
        #expect(coordinator.lastWrite == nil)
        #expect(files().isEmpty, "nothing was written: no word, no tombstone, no note that it was asked")
        #expect(coordinator.pacing.unanswered == 1)
    }

    // MARK: How often

    @Test("at most one offer in ten minutes, a word is offered once, and each unanswered offer doubles the wait")
    func occasional() {
        defer { try? FileManager.default.removeItem(at: root) }
        let pill = PillModel()
        let clock = Clock()
        let coordinator = coordinator(clock: clock)
        let other = "Ask Zorvex about the plan."
        #expect(coordinator.present(done(), on: pill, for: dictation()))
        pill.state = .idle
        // The very next dictation has another new name: not yet.
        #expect(!coordinator.present(done(other), on: pill, for: dictation(other, unsure: "zorvex")))
        clock.now += 19 * 60
        #expect(!coordinator.present(done(other), on: pill, for: dictation(other, unsure: "zorvex")), "ignored once: twenty minutes")
        clock.now += 60
        // The first word again, twenty minutes on: it was offered once already.
        #expect(!coordinator.present(done(), on: pill, for: dictation()))
        #expect(coordinator.present(done(other), on: pill, for: dictation(other, unsure: "zorvex")))
        #expect(pill.nameOffer?.heard == "Zorvex")
        pill.acceptNameOffer()
        #expect(coordinator.pacing.gap == NameOfferPacing.baseGap, "taking one brings the wait back to ten minutes")
    }

    // MARK: The row and the panel

    @Test("an offer waits while the pointer is on the pill; the added line goes on time")
    func timing() {
        #expect(PillState.nameOffer(.offered).selfDismissDecision(pointerOverCard: true) == .wait(PillState.pointerGrace))
        #expect(PillState.nameOffer(.offered).selfDismissDecision(pointerOverCard: false) == .dismiss)
        #expect(PillState.nameOffer(.editing).selfDismissDecision(pointerOverCard: true) == .wait(PillState.pointerGrace))
        #expect(PillState.nameOffer(.added).selfDismissDecision(pointerOverCard: true) == .dismiss)
        #expect(PillState.nameOffer(.editing).selfDismissDelay == PillState.nameEditingDelay)
        // A row, so it lies flat at a side edge and gets a row's panel.
        #expect(!PillLayout.canStandVertical(.nameOffer(.offered)))
        #expect(PillPanel.size(for: .nameOffer(.offered)) == PillPanel.failureSize)
        #expect(PillState.nameOffer(.offered).keyScope == PillState.done(words: 4).keyScope, "it takes no keys through the event tap")
    }

    @Test("the offer's wording offers; it never says Hushy misheard, and asks nothing that needs an answer")
    func wording() {
        let lines = [NameOfferWording.offer, NameOfferWording.editing, NameOfferWording.added, NameOfferWording.addHelp,
                     NameOfferWording.openHelp, NameOfferWording.dismissHelp, NameOfferWording.heardNote("Pria"),
                     NameOfferWording.accessibility(.offered, offer: NameOffer(heard: "Pria")),
                     NameOfferWording.accessibility(.editing, offer: NameOffer(heard: "Pria"))]
        for line in lines {
            #expect(!line.contains("?"), "\(line)")
            for claim in ["misheard", "mis-heard", "wrong", "mistake", "did you mean", "sorry"] {
                #expect(!line.lowercased().contains(claim), "\(line)")
            }
        }
    }

    @Test("the pill's panel may hold the keyboard only while the spelling is open, and a test's panel never does")
    func keyboard() throws {
        _ = NSApplication.shared
        let model = PillModel()
        model.showWhenIdle = true
        let panel = PillPanel(model: model, environment: PillPanelInteractionTests.fakeEnvironment())
        defer { panel.close() }
        #expect(!panel.canBecomeKey)
        model.present(nameOffer: "Pria", words: 0, usedContext: false) { _ in }
        #expect(!model.isEditingName)
        model.openNameOffer()
        #expect(model.isEditingName)
        #expect(!panel.canBecomeKey, "a test's panel cannot take the keyboard of whoever is using the Mac")
        #expect(!PillPanelInteractionTests.fakeEnvironment().allowsKeyboard)
        #expect(PillPanelEnvironment.live.allowsKeyboard)
        model.acceptNameOffer()
        #expect(!model.isEditingName)
        // The keyboard going elsewhere while the spelling is open closes the offer.
        model.present(nameOffer: "Pria", words: 0, usedContext: false) { _ in }
        model.openNameOffer()
        panel.keyboardLeft()
        #expect(model.state == .idle)
    }
}
