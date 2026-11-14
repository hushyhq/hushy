import Testing
@testable import MurmurCore

@Suite struct CorrectionEditPairsTests {
    @Test func termFixIsLearnableButMixedMeaningChangeIsNot() {
        let before = "ask Pria to send the report today"
        #expect(CorrectionEditPairs.containsOnlyCorrections(EditPair(before: before, after: "ask Priya to send the report today"), raw: before))
        #expect(!CorrectionEditPairs.containsOnlyCorrections(EditPair(before: before, after: "ask Priya to send the report tomorrow"), raw: before))
    }

    @Test func aQuestionChangedToAStatementIsNeverAStyleExample() {
        #expect(!CorrectionEditPairs.containsOnlyCorrections(EditPair(before: "ask Pria to send it?", after: "ask Priya to send it."), raw: "ask Pria to send it?"))
        #expect(CorrectionClassifier.formattingSignal(before: "Ready!", after: "Ready?") == nil)
        #expect(CorrectionClassifier.formattingSignal(before: "Ready.", after: "Ready?") == nil)
    }

    @Test func latestRewriteCannotBorrowAnEarlierTermVerdict() {
        let before = "ask Pria to send the report today"
        let snapshots = [FieldSnapshot(value: before, elapsed: 2),
                         FieldSnapshot(value: "ask Priya to send the report today", elapsed: 4),
                         FieldSnapshot(value: "ask Priya to send the report today", elapsed: 6),
                         FieldSnapshot(value: "ask Priya to send the report tomorrow", elapsed: 8),
                         FieldSnapshot(value: "ask Priya to send the report tomorrow", elapsed: 12)]
        let pairs = EditPair.derive(inserted: before, snapshots: snapshots, context: LearningContext(appBundleID: "app.test"))
        #expect(!pairs.isEmpty)
        #expect(pairs.filter { CorrectionEditPairs.containsOnlyCorrections($0, raw: before) }.isEmpty)
    }
}
