import Foundation
import MurmurCore

extension LearnRunner {
    /// Invented end-to-end regressions alongside the unchanged adversarial simulation.
    static func reportEditSignals() throws {
        let cases: [(String, String, VocabularySwap.Source)] = [
            ("text", "Next", .boost), ("codec", "Codex", .dictionaryAlias),
        ]
        var stopped = 0
        var backwardsTerms = 0
        for (heard, written, source) in cases {
            let store = try Store()
            let inserted = "please paste the \(written) here"
            let fixed = "please paste the \(heard) here"
            let swap = VocabularySwap(heard: heard, written: written, source: source)
            if let capture = CorrectionCapture.derive(inserted: inserted, raw: fixed, fieldValue: fixed,
                                                     context: LearningContext(appBundleID: app), dictationID: 1,
                                                     swaps: [swap]) {
                try store.recordCorrections(capture)
                let keep = try store.keepHeardSet(for: app)
                let result = VocabularySwaps.restore(from: fixed, to: inserted, source: source, keeping: keep)
                stopped += result.text == fixed ? 1 : 0
                backwardsTerms += try store.learnedItems().filter { $0.kind == .term }.count
            }
        }
        let evidence = TermEvidence(dictionary: [], screenTerms: ["Codex"], appNames: [])
        let capture = CorrectionCapture.derive(inserted: "please ask codec for help", raw: "please ask codec for help",
                                              fieldValue: "please ask Codex for help", context: LearningContext(appBundleID: app),
                                              dictationID: 1, evidence: evidence)
        let supported = capture.map { Learner.observe($0, existing: [], knownTerms: []).filter { $0.status == .active }.count } ?? 0
        print("| Reverts stop the same swap | \(stopped)/2 |")
        print("| Reverts learned backwards as terms | \(backwardsTerms)/2 |")
        print("| Evidence-supported fixes active after one edit | \(supported)/1 |")
        guard stopped == 2, backwardsTerms == 0, supported == 1 else {
            throw NSError(domain: "LearnEditSignals", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Edit-learning regression checks failed"])
        }
    }
}
