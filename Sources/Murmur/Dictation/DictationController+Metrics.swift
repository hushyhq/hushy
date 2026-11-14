import ApplicationServices
import Foundation
import MurmurCore

/// What `AppModel` hands the dictation path for usage numbers. Every closure returns at once.
struct DictationMetricsHooks {
    /// Whether anything would be recorded. Checked first, so a dictation costs nothing extra when sharing is off.
    var isCollecting: () -> Bool = { false }
    /// A dictation that is finished as far as usage numbers go.
    var record: (DictationMetricInput) -> Void = { _ in }
    /// A pasted dictation waiting for the edit watcher's verdict; returns the token to resolve it with.
    var hold: (DictationMetricInput) -> UUID? = { _ in nil }
    var resolve: (UUID, DictationEditObservation.Verdict, DictationEditObservation.Coverage, MetricsEditSize) -> Void = { _, _, _, _ in }
    var cleanupBackend: () -> EffectiveCleanupBackend = { .apple }
    var modelState: (ModelOutcome?, Date) -> MetricsModelState? = { _, _ in nil }
    /// A dictation was delivered (pasted or copied). Feeds the once-a-day count (`DailyCountSender`),
    /// which has its own gate and sends no content, so it is called before `isCollecting`.
    var dictationDelivered: () -> Void = {}
}

/// Usage numbers for one finished dictation: the single place the dictation path turns what just
/// happened into counts and timings. It reads a word count (already computed for the pill) and a
/// handful of closed-vocabulary facts; the text, the app, the window and the mode's name never
/// reach it. A failure here can only drop the metric, never change the dictation.
extension DictationMetricsHooks {
    /// Returns the token of a pasted dictation that is now waiting for the edit watcher, else nil.
    @discardableResult
    func report(
        _ result: DictationMetricInput.Result, _ cleaned: SmartCleaner.Output?, _ words: Int, _ mode: MurmurCore.Mode,
        _ audioSeconds: Double, _ timing: LatencyBreakdown, _ releasedAt: Date, tone: @autoclosure () -> MetricsTone? = nil,
        appKind: MetricsAppKind? = nil
    ) -> UUID? {
        if (result == .pasted || result == .copied), words > 0 { dictationDelivered() }
        guard isCollecting() else { return nil }   // sharing off costs the dictation nothing
        let outcome = cleaned.map { ModelOutcome(usedModel: $0.usedModel, rejection: $0.rejection) }
        let input = DictationMetricInput(
            result: result, modelOutcome: outcome, backend: cleanupBackend(), cleanupLevel: mode.cleanupLevel,
            mode: mode, wordCount: words, audioSeconds: audioSeconds, speechMilliseconds: timing.milliseconds(of: .speech),
            cleanupMilliseconds: timing.milliseconds(of: .cleanup),
            releaseToDeliveryMilliseconds: result == .pasted ? timing.totalMs : nil,
            modelState: modelState(outcome, releasedAt), tone: cleaned == nil ? nil : tone(),   // none when cleanup never ran
            appKind: appKind)
        // A paste the edit watcher will look at is recorded once, when it reports (or its window closes).
        guard result == .pasted, !(cleaned?.pressEnter ?? false), words > 0 else {
            record(input)
            return nil
        }
        return hold(input)
    }
}

extension DictationController {
    /// The handler that releases a held dictation when the edit watcher's verdict read decides.
    func metricsVerdict(_ token: UUID?) -> EditWatcher.VerdictHandler? {
        guard let token else { return nil }
        let resolve = metrics.resolve
        return { verdict, coverage, size in resolve(token, verdict, coverage, size) }
    }

    /// Starts the edit watcher for a pasted dictation (verdict, learning and usage numbers).
    func watchEdit(
        _ savedID: Int64?, _ status: Dictation.Status, _ cleaned: SmartCleaner.Output, _ element: AXUIElement?,
        _ raw: String, _ target: FocusTarget, _ language: String?, _ token: UUID?,
        swaps: [VocabularySwap] = [], evidence: TermEvidence = .none
    ) {
        // Every dictation that gets here ends with one `learning` log line, watched or not.
        let unwatched = EditWatcher.notWatched(isSaved: savedID != nil, status: status, pressesReturn: cleaned.pressEnter)
        guard let savedID, unwatched == nil else {
            EditWatcher.report(LearningDiagnosis(bundleID: target.bundleID, outcome: .notWatched(unwatched ?? .notSaved)))
            return
        }
        let learning = EditWatcher.learning(raw: raw, target: target, settings: settings, detectedLanguage: language, swaps: swaps, evidence: evidence)
        EditWatcher.watch(
            element: element, inserted: cleaned.text, dictationID: savedID, store: store,
            learning: learning.input, refusal: learning.refusal, app: target.bundleID,
            memory: FeatureFlags.personMemory ? MemoryStore.shared() : nil, onVerdict: metricsVerdict(token))
    }
}
