import Foundation
import MurmurCore

/// `murmur-eval learn [--max-false-learn 0.NN] [--max-mean-edits N] [--report path.json]`
///
/// Runs in both policy modes: **suggest-only** (the shipping default — a term is offered once it
/// has 2 fixes in 14 days, and the simulated user confirms it then) and **auto-activate**
/// (`FeatureFlags.autoActivateLearnedTerms`, for when the Undo notice exists).
///
/// Simulates the on-device learn-from-corrections loop end to end on synthetic data
/// (`LearnFixtures`): dictation text goes through the production rules pipeline
/// (`DictationPipeline.clean`, `.rules`, deterministic), the simulated user fixes it in the
/// field, `CorrectionCapture.derive` + `Store.recordCorrections` learn from the edit (in-memory
/// store), and the next dictation uses the learned personalizer. Measures:
///   1. edits needed before a term is learned (active),
///   2. false-learn rate on adversarial edits (rewrites, deliberate one-offs, common-word swaps,
///      privacy exclusions),
///   3. term accuracy / WER on a follow-up set containing the learned terms (text-only: the ASR
///      boosting half needs audio and is covered by `murmur-eval vocab`),
///   4. that sentences without learned terms come out byte-identical.
enum LearnRunner {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400
    static let maxAttempts = 5
    static let app = "com.apple.mail"

    enum Mode: String, CaseIterable {
        case suggestOnly = "suggest-only (confirm)"
        case autoActivate = "auto-activate (flag on)"

        var policy: LearningPolicy { LearningPolicy(autoActivateTerms: self == .autoActivate) }
    }

    struct TermResult {
        let term: LearnFixtures.Term
        /// Fixes until the term was in use (suggest-only: including the user's confirm).
        let editsToLearn: Int?
        let totalEdits: Int
        /// A confirmable suggestion existed after the first fix.
        let suggestedAfterFirstEdit: Bool
        /// The term became active without the user confirming it.
        let activatedSilently: Bool
    }

    struct ModeResult {
        let mode: Mode
        let terms: [TermResult]
        let followUp: FollowUp
        let adversarial: [AdversarialResult]
    }

    struct FollowUp {
        var cases = 0
        var baselineHits = 0
        var learnedHits = 0
        var baselineWER = 0.0
        var learnedWER = 0.0
        var controlCases = 0
        var controlChanged = 0
    }

    struct AdversarialResult {
        let scenario: LearnFixtures.Scenario
        let activated: [String]
        let candidates: [String]
        /// Candidates with full evidence (what suggest-only mode would offer as "ready").
        let readySuggestions: [String]
    }

    static func run(_ args: Arguments) async throws {
        let suite = "hushy-learn-eval-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw EvalError.missing("learn could not create isolated defaults") }
        let previous = FeatureFlags.source
        FeatureFlags.source = defaults
        defer {
            FeatureFlags.source = previous
            defaults.removePersistentDomain(forName: suite)
        }
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: SmartCleaner(model: NullLanguageModel()))
        var results: [ModeResult] = []
        for mode in Mode.allCases {
            let store = try Store()
            var nextID: Int64 = 1
            var terms: [TermResult] = []
            for term in LearnFixtures.terms {
                terms.append(try await learn(term, mode: mode, store: store, pipeline: pipeline, nextID: &nextID))
            }
            let followUp = await followUp(learned: try store.learnedItems(), pipeline: pipeline)
            let adversarial = try LearnFixtures.adversarial.map { try runScenario($0, policy: mode.policy, pipeline: pipeline) }
            results.append(ModeResult(mode: mode, terms: terms, followUp: followUp, adversarial: adversarial))
        }
        var short: [ShortModeResult] = []
        for mode in Mode.allCases { short.append(try await runShort(mode: mode, pipeline: pipeline)) }
        report(results, args: args)
        reportShort(short)
        try reportEditSignals()
    }

    // MARK: Learning phase

    static func learn(
        _ term: LearnFixtures.Term, mode: Mode, store: Store, pipeline: DictationPipeline, nextID: inout Int64
    ) async throws -> TermResult {
        var edits = 0
        var suggested = false
        for attempt in 0..<maxAttempts {
            let template = LearnFixtures.learningTemplates[attempt % LearnFixtures.learningTemplates.count]
            let heard = term.heardAs[attempt % term.heardAs.count]
            let raw = template.replacingOccurrences(of: "{T}", with: heard)
            let personalizer = LearnedPersonalization.personalizer(dictionary: [], snippets: [], learned: try store.learnedItems())
            let inserted = await clean(raw, personalizer: personalizer, pipeline: pipeline)
            if containsWord(inserted, term.term) { break }
            let fixed = replacingFirst(heard, with: term.term, in: inserted)
            let field = attempt.isMultiple(of: 2) ? fixed : "Hi team,\n\(fixed)\nThanks"
            edits += 1
            let id = nextID
            nextID += 1
            if let capture = CorrectionCapture.derive(
                inserted: inserted, raw: raw, fieldValue: field,
                context: LearningContext(appBundleID: app, elapsed: 12), dictationID: id,
                now: base.addingTimeInterval(Double(attempt) * day)) {
                try store.recordCorrections(capture, policy: mode.policy)
            }
            var item = try store.learnedItems().first { $0.kind == .term && $0.key == term.term.lowercased() }
            if edits == 1, item != nil { suggested = true }
            let silent = item?.status == .active && item?.confirmed == false
            // Suggest-only: the simulated user taps "Add" once the suggestion is ready.
            if mode == .suggestOnly, let ready = item, ready.isReadySuggestion, let id = ready.id {
                item = try store.confirmLearnedItem(id: id, now: base.addingTimeInterval(Double(attempt) * day))
            }
            if item?.status == .active {
                return TermResult(term: term, editsToLearn: edits, totalEdits: edits,
                                  suggestedAfterFirstEdit: suggested, activatedSilently: silent)
            }
        }
        return TermResult(term: term, editsToLearn: nil, totalEdits: edits, suggestedAfterFirstEdit: suggested,
                          activatedSilently: false)
    }

    // MARK: Follow-up set

    static func followUp(learned: [LearnedItem], pipeline: DictationPipeline) async -> FollowUp {
        let learnedPersonalizer = LearnedPersonalization.personalizer(dictionary: [], snippets: [], learned: learned)
        var result = FollowUp()
        for term in LearnFixtures.terms {
            for (index, template) in LearnFixtures.followUpTemplates.enumerated() {
                let heard = term.heardAs[index % term.heardAs.count]
                let raw = template.replacingOccurrences(of: "{T}", with: heard)
                let expected = await clean(template.replacingOccurrences(of: "{T}", with: term.term), personalizer: Personalizer(), pipeline: pipeline)
                let baseline = await clean(raw, personalizer: Personalizer(), pipeline: pipeline)
                let withLearning = await clean(raw, personalizer: learnedPersonalizer, pipeline: pipeline)
                result.cases += 1
                result.baselineHits += containsWord(baseline, term.term) ? 1 : 0
                result.learnedHits += containsWord(withLearning, term.term) ? 1 : 0
                result.baselineWER += EvalMetrics.wer(reference: expected, hypothesis: baseline)
                result.learnedWER += EvalMetrics.wer(reference: expected, hypothesis: withLearning)
            }
        }
        for sentence in LearnFixtures.controlSentences {
            let plain = await clean(sentence, personalizer: Personalizer(), pipeline: pipeline)
            let withLearning = await clean(sentence, personalizer: learnedPersonalizer, pipeline: pipeline)
            result.controlCases += 1
            result.controlChanged += plain == withLearning ? 0 : 1
        }
        return result
    }

    // MARK: Adversarial set

    static func runScenario(
        _ scenario: LearnFixtures.Scenario, policy: LearningPolicy = .standard, pipeline: DictationPipeline
    ) throws -> AdversarialResult {
        let store = try Store()
        for (index, edit) in scenario.edits.enumerated() {
            let context = LearningContext(
                appBundleID: app, excludedBundleIDs: scenario.excluded ? [app] : [], isSecureField: scenario.isSecure,
                isCodeContext: scenario.isCode, elapsed: 12)
            guard let capture = CorrectionCapture.derive(
                inserted: edit.inserted, raw: edit.inserted, fieldValue: edit.edited, context: context,
                dictationID: Int64(index + 1), now: base.addingTimeInterval(edit.dayOffset * day))
            else { continue }
            try store.recordCorrections(capture, policy: policy)
        }
        let items = try store.learnedItems()
        return AdversarialResult(
            scenario: scenario,
            activated: items.filter { $0.status == .active }.map(\.value),
            candidates: items.filter { $0.status == .candidate }.map(\.value),
            readySuggestions: items.filter(\.isReadySuggestion).map(\.value))
    }

    // MARK: Helpers

    static func clean(_ raw: String, personalizer: Personalizer, pipeline: DictationPipeline) async -> String {
        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: .clean), personalizer: personalizer)
        return await pipeline.clean(raw, settings: settings, strategy: .rules).text
    }

    static func containsWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "(?<![\\w])\(NSRegularExpression.escapedPattern(for: word))(?![\\w])", options: .regularExpression) != nil
    }

    /// Replaces the first case-insensitive whole-word occurrence (rules may have capitalized it).
    static func replacingFirst(_ target: String, with replacement: String, in text: String) -> String {
        let pattern = "(?<![\\w])\(NSRegularExpression.escapedPattern(for: target))(?![\\w])"
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return text }
        return text.replacingCharacters(in: range, with: replacement)
    }
}
