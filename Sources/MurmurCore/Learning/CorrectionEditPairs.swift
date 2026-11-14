import Foundation

/// Memory examples must pass the same correction classifier as vocabulary learning.
/// Judge each actual pair, since the newest pair can differ from an earlier captured fix.
public enum CorrectionEditPairs {
    public static func containsOnlyCorrections(_ pair: EditPair, raw: String,
                                               evidence: TermEvidence = .none, swaps: [VocabularySwap] = []) -> Bool {
        let alignment = CorrectionAlignment.align(inserted: CorrectionAlignment.tokens(pair.before),
                                                  edited: CorrectionAlignment.tokens(pair.after))
        let reverted = RevertDetector.split(alignment, swaps: swaps)
        let styled = StyleEditSignals.split(reverted.rest)
        let classified = CorrectionClassifier.classify(styled.rest, raw: raw, evidence: evidence)
        guard classified.count == styled.rest.edits.count + styled.rest.surfaceChanges.count else { return false }
        let events = classified + styled.events
        return !events.contains { $0.kind == .rewrite } && (!events.isEmpty || !reverted.reverts.isEmpty)
    }
}
