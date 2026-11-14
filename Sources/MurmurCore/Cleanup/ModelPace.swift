import Foundation
import Synchronization

/// Predicts whether the on-device model can rewrite a draft within the time budget, so long
/// dictations don't sit through a model call that is certain to time out. Generation time grows
/// with output length (it rewrites the whole draft): a fixed startup cost plus a per-word cost,
/// learned from real calls on this Mac. Timeouts push the estimate up; successes pull it back.
public enum ModelPace {
    public struct Estimator: Sendable {
        /// Session start + prompt processing, roughly independent of length.
        static let overheadMs = 300.0
        /// Weight of the newest measurement in the running average.
        static let smoothing = 0.3
        /// Short drafts are always worth a try: a stale, inflated estimate must never lock the
        /// model out of the everyday case (a few timeouts under load once did exactly that).
        static let alwaysTryWords = 24
        /// Bounds so one bad stretch can't push the estimate out of any realistic range.
        static let minMsPerWord = 25.0
        static let maxMsPerWord = 120.0
        /// Each skipped call relaxes the estimate back toward the default, so skipping can't
        /// become permanent just because skipped calls never produce a new measurement.
        static let skipRecovery = 0.15
        static let defaultMsPerWord = 60.0

        /// Starting guess before any call has been measured (M-series, idle).
        var msPerWord = 60.0

        func fits(words: Int, budgetMs: Double) -> Bool {
            words <= Self.alwaysTryWords || Self.overheadMs + Double(words) * msPerWord <= budgetMs
        }

        mutating func recordSkip() {
            msPerWord += (Self.defaultMsPerWord - msPerWord) * Self.skipRecovery
        }

        mutating func recordSuccess(words: Int, elapsedMs: Double) {
            guard words > 0 else { return }
            let observed = max(0, elapsedMs - Self.overheadMs) / Double(words)
            msPerWord = clamp(msPerWord * (1 - Self.smoothing) + observed * Self.smoothing)
        }

        /// The call for `words` words used the whole budget, so it needed at least that long.
        mutating func recordTimeout(words: Int, budgetMs: Double) {
            guard words > 0 else { return }
            msPerWord = clamp(max(msPerWord, max(0, budgetMs - Self.overheadMs) / Double(words) * 1.1))
        }

        private func clamp(_ value: Double) -> Double {
            min(max(value, Self.minMsPerWord), Self.maxMsPerWord)
        }
    }

    private static let shared = Mutex(Estimator())

    /// Whether to call the model; a "no" also counts as a skip so the estimate recovers.
    public static func fits(words: Int, budget: Duration) -> Bool {
        shared.withLock { pace in
            let fits = pace.fits(words: words, budgetMs: ms(budget))
            if !fits { pace.recordSkip() }
            return fits
        }
    }

    public static func recordSuccess(words: Int, elapsed: Duration) {
        shared.withLock { $0.recordSuccess(words: words, elapsedMs: ms(elapsed)) }
    }

    /// Only a real timeout counts; a fast model error says nothing about speed.
    public static func recordTimeout(words: Int, budget: Duration, elapsed: Duration) {
        guard elapsed >= budget * 0.95 else { return }
        shared.withLock { $0.recordTimeout(words: words, budgetMs: ms(budget)) }
    }

    /// Forget the learned pace — the cleanup backend changed (Apple FM ↔ a local model), and one
    /// backend's speed says nothing about the other's.
    public static func reset() {
        shared.withLock { $0 = Estimator() }
    }

    public static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
