import Foundation
import MurmurCore

/// Short dictations (one or two words) in `murmur-eval learn`. They are located by an earlier
/// read of the same field, so every scenario here is a *sequence* of reads (the dictation as
/// pasted, then the field after the user's edit), fed to `CorrectionCapture.deriveLatest`.
/// "Before" is the single-read path every short dictation took until now (`derive` on the
/// edited field alone), which refuses them all.
extension LearnRunner {
    struct ShortTermResult {
        let term: LearnFixtures.Term
        /// Fixes until the term was in use (suggest-only: including the user's confirm).
        let fixesToLearn: Int?
        let attempts: Int
        /// Fixes the pre-change single-read path would have captured from the same edits.
        let legacyCaptures: Int
    }

    struct ShortAdversarialResult {
        let scenario: LearnShortFixtures.Scenario
        let activated: [String]
        let candidates: [String]
    }

    struct ShortModeResult {
        let mode: Mode
        let terms: [ShortTermResult]
        let adversarial: [ShortAdversarialResult]
    }

    static func runShort(mode: Mode, pipeline: DictationPipeline) async throws -> ShortModeResult {
        let store = try Store()
        var nextID: Int64 = 1
        var terms: [ShortTermResult] = []
        for term in LearnFixtures.terms {
            terms.append(try await learnShort(term, mode: mode, store: store, pipeline: pipeline, nextID: &nextID))
        }
        let adversarial = try LearnShortFixtures.adversarial.map { try runShortScenario($0, policy: mode.policy) }
        return ShortModeResult(mode: mode, terms: terms, adversarial: adversarial)
    }

    static func learnShort(
        _ term: LearnFixtures.Term, mode: Mode, store: Store, pipeline: DictationPipeline, nextID: inout Int64
    ) async throws -> ShortTermResult {
        var fixes = 0
        var legacy = 0
        for attempt in 0..<maxAttempts {
            let heard = term.heardAs[attempt % term.heardAs.count]
            let twoWords = !heard.contains(" ") && !attempt.isMultiple(of: 2)
            let raw = twoWords ? "\(heard) \(LearnShortFixtures.surname)" : heard
            let personalizer = LearnedPersonalization.personalizer(dictionary: [], snippets: [], learned: try store.learnedItems())
            let inserted = await clean(raw, personalizer: personalizer, pipeline: pipeline)
            if containsWord(inserted, term.term) { break }
            fixes += 1
            let wrap: (String) -> String = { attempt.isMultiple(of: 3) ? $0 : "Hi team,\n\($0)\nThanks" }
            let fixed = replacingFirst(heard, with: term.term, in: inserted)
            let context = LearningContext(appBundleID: app, elapsed: 12)
            let day = base.addingTimeInterval(Double(attempt) * Self.day)
            legacy += CorrectionCapture.derive(
                inserted: inserted, raw: raw, fieldValue: wrap(fixed), context: context, dictationID: nextID, now: day) == nil ? 0 : 1
            let reads = [wrap(inserted), wrap(fixed), wrap(fixed)]
            try record(inserted: inserted, raw: raw, reads: reads, context: context, id: nextID, now: day, policy: mode.policy, store: store)
            nextID += 1
            var item = try store.learnedItems().first { $0.kind == .term && $0.key == term.term.lowercased() }
            if mode == .suggestOnly, let ready = item, ready.isReadySuggestion, let id = ready.id {
                item = try store.confirmLearnedItem(id: id, now: day)
            }
            if item?.status == .active {
                return ShortTermResult(term: term, fixesToLearn: fixes, attempts: fixes, legacyCaptures: legacy)
            }
        }
        return ShortTermResult(term: term, fixesToLearn: nil, attempts: fixes, legacyCaptures: legacy)
    }

    static func runShortScenario(_ scenario: LearnShortFixtures.Scenario, policy: LearningPolicy) throws -> ShortAdversarialResult {
        let store = try Store()
        for (index, edit) in scenario.edits.enumerated() {
            let context = LearningContext(
                appBundleID: app, excludedBundleIDs: scenario.excluded ? [app] : [], isSecureField: scenario.isSecure,
                isCodeContext: scenario.isCode, elapsed: 12)
            try record(inserted: edit.inserted, raw: edit.inserted, reads: edit.reads, context: context,
                       id: Int64(index + 1), now: base.addingTimeInterval(edit.dayOffset * day), policy: policy, store: store)
        }
        let items = try store.learnedItems()
        return ShortAdversarialResult(
            scenario: scenario, activated: items.filter { $0.status == .active }.map(\.value),
            candidates: items.filter { $0.status == .candidate }.map(\.value))
    }

    private static func record(
        inserted: String, raw: String, reads: [String], context: LearningContext, id: Int64, now: Date,
        policy: LearningPolicy, store: Store
    ) throws {
        let snapshots = reads.enumerated().map { FieldSnapshot(value: $1, elapsed: 2 + Double($0) * 2) }
        guard let capture = CorrectionCapture.deriveLatest(
            inserted: inserted, raw: raw, snapshots: snapshots, context: context, dictationID: id, now: now)
        else { return }
        try store.recordCorrections(capture, policy: policy)
    }
}
