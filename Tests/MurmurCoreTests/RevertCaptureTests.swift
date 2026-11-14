import Foundation
import Testing
@testable import MurmurCore

@Suite struct RevertCaptureTests {
    private let app = "app.quillpad.mail"

    @Test func ordinaryRevertStopsBoostInThisApp() throws {
        let store = try Store()
        let swap = VocabularySwap(heard: "text", written: "Next", source: .boost)
        let capture = try #require(CorrectionCapture.derive(inserted: "please paste the Next here", raw: "please paste the Next here",
            fieldValue: "please paste the text here", context: LearningContext(appBundleID: app), dictationID: 41, swaps: [swap]))
        #expect(capture.events.isEmpty)
        #expect(capture.reverts.count == 1)
        let record = try store.reportCorrections(capture)
        #expect(record.keptHeard == 1)
        #expect(try store.learnedItems().isEmpty)
        let boosted = TranscriptionResult(text: "the Next field", unboosted: "the text field")
        #expect(try ReleaseSwaps.apply(boosted, keep: store.keepHeardSet(for: app)).text == "the text field")
        #expect(try ReleaseSwaps.apply(boosted, keep: store.keepHeardSet(for: "app.other")).text == "the Next field")
    }

    @Test func nonwordRevertNeverTeachesBackwardsTerm() throws {
        let swap = VocabularySwap(heard: "codec", written: "Codex", source: .dictionaryAlias)
        let capture = try #require(CorrectionCapture.derive(inserted: "ask Codex to refactor this", raw: "ask Codex to refactor this",
            fieldValue: "ask codec to refactor this", context: LearningContext(appBundleID: app), dictationID: 42, swaps: [swap]))
        #expect(capture.events.isEmpty)
        #expect(Learner.observe(capture, existing: [], knownTerms: []).isEmpty)
    }

    @Test func unrelatedRewriteTeachesNothing() {
        let capture = CorrectionCapture.derive(inserted: "please paste the Next here", raw: "please paste the Next here",
            fieldValue: "please paste the previous here", context: LearningContext(appBundleID: app), dictationID: 43,
            swaps: [VocabularySwap(heard: "text", written: "Next", source: .boost)])
        #expect(capture == nil)
    }

    @Test func shortRevertNeedsAnchoredStableReads() throws {
        let swap = VocabularySwap(heard: "text", written: "Next", source: .boost)
        let snapshots = [FieldSnapshot(value: "prefix Next suffix", elapsed: 2),
                         FieldSnapshot(value: "prefix text suffix", elapsed: 4),
                         FieldSnapshot(value: "prefix text suffix", elapsed: 6)]
        let capture = try #require(CorrectionCapture.deriveLatest(inserted: "Next", raw: "Next", snapshots: snapshots,
            context: LearningContext(appBundleID: app), dictationID: 44, swaps: [swap]))
        #expect(capture.events.isEmpty)
        #expect(capture.reverts.map(\.swap) == [swap])
        #expect(CorrectionCapture.deriveLatest(inserted: "Next", raw: "Next", snapshots: Array(snapshots.dropFirst()),
            context: LearningContext(appBundleID: app), dictationID: 44, swaps: [swap]) == nil)
    }

    @Test func staleDictationOrGenerationNeverRecordsRevert() throws {
        let store = try Store()
        let capture = CorrectionCapture(dictationID: 99, appBundleID: app, capturedAt: Date(), events: [],
            reverts: [Revert(swap: VocabularySwap(heard: "text", written: "Next", source: .boost), typed: "text")])
        #expect(try store.reportCorrections(capture, expectedInsertedText: "missing").skip == .stale)
        #expect(try store.reportCorrections(capture, expectedObservationGeneration: "stale").skip == .stale)
        #expect(try store.keepHeardEntries().isEmpty)
    }

    @Test func capitalizationRevertKeepsAttachedPunctuation() throws {
        let swap = VocabularySwap(heard: "notion", written: "Notion", source: .dictionaryAlias)
        let capture = try #require(CorrectionCapture.derive(inserted: "please open Notion.", raw: "please open notion",
            fieldValue: "please open notion.", context: LearningContext(appBundleID: app), dictationID: 46, swaps: [swap]))
        #expect(capture.reverts.map(\.swap) == [swap])
        #expect(capture.events.isEmpty)
    }

    @Test func capitalizationRevertIsNotStyleOrTermLearning() throws {
        let swap = VocabularySwap(heard: "notion", written: "Notion", source: .dictionaryAlias)
        #expect(VocabularySwaps.diff(from: "use notion for notes", to: "use Notion for notes", source: .dictionaryAlias) == [swap])
        let capture = try #require(CorrectionCapture.derive(inserted: "use Notion for notes", raw: "use notion for notes",
            fieldValue: "use notion for notes", context: LearningContext(appBundleID: app), dictationID: 45, swaps: [swap]))
        #expect(capture.reverts.map(\.swap) == [swap])
        #expect(capture.events.isEmpty)
    }
}
