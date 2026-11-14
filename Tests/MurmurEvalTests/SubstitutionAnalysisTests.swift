import Foundation
import Testing

@testable import murmur_eval

/// `SubstitutionAnalysis` is the pure edit-alignment logic behind `murmur-eval accent`'s
/// top-substitution-pairs report (e.g. "notes → nodes", the product owner's own reported ASR
/// error — see `.claude/DECISIONS.md`, "Indian-accent ASR accuracy"). Pinned down independently
/// of any network access so the alignment/classification logic has coverage without a dataset
/// download.
@Suite("SubstitutionAnalysis")
struct SubstitutionAnalysisTests {
    @Test func identicalTextHasNoSubstitutions() {
        let subs = SubstitutionAnalysis.substitutions(referenceText: "take some notes please", hypothesisText: "take some notes please")
        #expect(subs.isEmpty)
    }

    @Test func singleWordSubstitutionIsDetected() {
        let subs = SubstitutionAnalysis.substitutions(referenceText: "take some notes please", hypothesisText: "take some nodes please")
        #expect(subs.count == 1)
        #expect(subs.first == SubstitutionAnalysis.Substitution(reference: "notes", hypothesis: "nodes"))
    }

    @Test func deletionIsMarkedWithTheEmptySetSymbol() {
        let subs = SubstitutionAnalysis.substitutions(referenceText: "take some notes please", hypothesisText: "take notes please")
        #expect(subs.contains(SubstitutionAnalysis.Substitution(reference: "some", hypothesis: "∅")))
    }

    @Test func insertionIsMarkedWithTheEmptySetSymbol() {
        let subs = SubstitutionAnalysis.substitutions(referenceText: "take notes please", hypothesisText: "take some notes please")
        #expect(subs.contains(SubstitutionAnalysis.Substitution(reference: "∅", hypothesis: "some")))
    }

    @Test func multipleSubstitutionsInOneUtteranceAreAllFound() {
        // The product owner's own reported failures: "Jev" -> "Jav", "notes" -> "nodes".
        let subs = SubstitutionAnalysis.substitutions(referenceText: "ask jev to save these notes", hypothesisText: "ask jav to save these nodes")
        #expect(subs.contains(SubstitutionAnalysis.Substitution(reference: "jev", hypothesis: "jav")))
        #expect(subs.contains(SubstitutionAnalysis.Substitution(reference: "notes", hypothesis: "nodes")))
    }

    @Test func topSubstitutionsTalliesAcrossACorpusSortedByFrequency() {
        let pairs: [(reference: String, hypothesis: String)] = [
            ("take some notes please", "take some nodes please"),
            ("save the notes now", "save the nodes now"),
            ("open the notes app", "open the notes app"),
            ("eye contact matters", "i contact matters"),
        ]
        let top = SubstitutionAnalysis.topSubstitutions(pairs, top: 10)
        #expect(top.first?.pair == SubstitutionAnalysis.Substitution(reference: "notes", hypothesis: "nodes"))
        #expect(top.first?.count == 2)
        #expect(top.contains { $0.pair == SubstitutionAnalysis.Substitution(reference: "eye", hypothesis: "i") })
    }

    @Test func topSubstitutionsExcludesPureInsertionsAndDeletions() {
        let pairs: [(reference: String, hypothesis: String)] = [("take some notes", "take notes")]
        let top = SubstitutionAnalysis.topSubstitutions(pairs, top: 10)
        #expect(!top.contains { $0.pair.reference == "∅" || $0.pair.hypothesis == "∅" })
    }

    @Test func topSubstitutionsRespectsTheTopLimit() {
        let pairs: [(reference: String, hypothesis: String)] = [
            ("alpha", "beta"), ("gamma", "delta"), ("epsilon", "zeta"),
        ]
        let top = SubstitutionAnalysis.topSubstitutions(pairs, top: 2)
        #expect(top.count == 2)
    }

    @Test func functionWordSubstitutionsAreClassifiedAsNotBoostable() {
        let classification = AccentRunner.classify(SubstitutionAnalysis.Substitution(reference: "the", hypothesis: "a"))
        #expect(classification == .notBoostable)
    }

    @Test func shortWordSubstitutionsAreClassifiedAsNotBoostable() {
        // "eye" -> "i": three letters, not a function word, but not proper-noun/jargon-shaped
        // either — a vowel-shift case boosting can't reach.
        let classification = AccentRunner.classify(SubstitutionAnalysis.Substitution(reference: "eye", hypothesis: "i"))
        #expect(classification == .notBoostable)
    }

    @Test func longContentWordSubstitutionsAreClassifiedAsBoostable() {
        // A content word of reasonable length, not in the function-word list — the shape a
        // proper noun or jargon term (e.g. "Jev") would have.
        let classification = AccentRunner.classify(SubstitutionAnalysis.Substitution(reference: "notes", hypothesis: "nodes"))
        #expect(classification == .boostable)
    }
}
