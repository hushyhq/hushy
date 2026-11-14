import Foundation
import Synchronization

/// Whether the on-device model is answering in time *right now*, so a dictation never waits a
/// whole budget for an answer that is almost certain not to come (2026-09-27 report: the pill
/// showed the words, then the unpolished rules text pasted 2.4–3.5 s later, three times in a row).
///
/// Measured (DECISIONS "Don't wait for a slow model"): model latency is bimodal. On a quiet Mac a
/// short cleanup call answers in ~1–2 s. When another process is using the on-device model (an
/// eval, another app), Apple's inference service runs requests one at a time and every call takes
/// 5–7 s — at a load average of only ~5, so CPU load and thermal state are poor proxies. Slow calls
/// cluster (19 of 19 calls after a slow call were slow too), so one miss predicts the next.
///
/// The gate, from direct measurements only:
/// - **Breaker**: two timeouts in a row open it for calls with budgets up to the ones that timed
///   out; any answered call or fast probe closes it.
/// - **Probe**: after a timeout (or while open), `SmartCleaner.prewarm()` at key-down sends one
///   small cleanup call while the user is still talking. Its latency is a lower bound on the real
///   call's; if it alone can't answer within the call's budget, the call is skipped
///   (`skipped-slow`) and the rules text is pasted at once. A probe that is still running at
///   release past that point says the same thing. A real call cancels a probe that is still
///   running and not yet slow, so the two never queue behind each other.
/// - Skips never reset anything: only a measurement (answer, timeout, probe) changes the state,
///   and a skip starts a background probe so the gate recovers without making anyone wait.
/// - Only a timeout is a measurement of speed. A call or probe that fails with an error — the
///   system refusing to run the model under memory pressure (`model busy`), the safety layer
///   declining the text (`model refused`), anything else — changes nothing here
///   (`ModelCallFailure`; DECISIONS 2026-09-27 "Apple FM errors are memory pressure").
public final class ModelHealth: Sendable {
    public enum SkipReason: String, Sendable, CaseIterable {
        /// A recent probe (or one still running) shows the model can't answer within this budget.
        case skippedSlow = "skipped-slow"
        /// Consecutive timeouts; closes on the next answered call or fast probe.
        case breakerOpen = "breaker-open"
    }

    public enum Verdict: Equatable, Sendable {
        case call
        case skip(SkipReason)
    }

    public struct Tracker: Sendable {
        /// Consecutive timeouts that open the breaker. One is not enough: on an idle Mac ~5% of
        /// calls brush the budget, and a lone timeout must not turn the model off.
        static let breakerThreshold = 2
        /// A probe is "slow" for a call when its latency alone exceeds this share of the call's
        /// budget: the real call does at least as much work, so it would miss. The whole budget,
        /// not less: when the model answers in time only some of the time (another process using
        /// it lightly), 0.85 kept the breaker shut on probes that the real calls would have beaten
        /// (cleanup-hybrid model use 18 → 1 of 68 in that condition).
        static let slowShare = 1.0
        /// How long a slow probe keeps the model off without a newer measurement.
        static let slowEvidenceSeconds = 60.0
        /// Minimum gap between probes, so a burst of skips sends one probe, not one each.
        let probeIntervalSeconds: Double

        var consecutiveTimeouts = 0
        /// The largest budget that timed out in the current streak. The breaker only covers calls
        /// with budgets up to it: two Clean timeouts at 2.4 s say nothing certain about a
        /// Polished call's 4 s, which still gets its own try.
        var timeoutFloorMs = 0.0
        /// Latest finished probe: its latency (ms) and when it finished.
        var lastProbe: (ms: Double, at: ContinuousClock.Instant)?
        /// A probe in flight: when it started, and the budget it is judged against.
        var probeStartedAt: ContinuousClock.Instant?
        var probeBudgetMs = 0.0

        public init(probeIntervalSeconds: Double = 3) {
            self.probeIntervalSeconds = probeIntervalSeconds
        }

        func verdict(budgetMs: Double, now: ContinuousClock.Instant) -> Verdict {
            if consecutiveTimeouts >= Self.breakerThreshold, budgetMs <= timeoutFloorMs { return .skip(.breakerOpen) }
            let limit = budgetMs * Self.slowShare
            if let started = probeStartedAt, ModelPace.ms(now - started) > limit { return .skip(.skippedSlow) }
            if let probe = lastProbe, probe.ms > limit,
               ModelPace.ms(now - probe.at) < Self.slowEvidenceSeconds * 1_000 {
                return .skip(.skippedSlow)
            }
            return .call
        }

        /// Whether the model's health is in doubt for a call with this budget (a recent timeout,
        /// or a probe too slow for it), so a probe would tell us something — and one is allowed now.
        func wantsProbe(budgetMs: Double, now: ContinuousClock.Instant) -> Bool {
            guard probeStartedAt == nil else { return false }
            if let probe = lastProbe, ModelPace.ms(now - probe.at) < probeIntervalSeconds * 1_000 { return false }
            let lastWasSlow = lastProbe.map { $0.ms > Self.slowShare * budgetMs } ?? false
            return consecutiveTimeouts > 0 || lastWasSlow
        }

        mutating func recordAnswer() {
            consecutiveTimeouts = 0
            timeoutFloorMs = 0
            lastProbe = nil
        }

        mutating func recordTimeout(budgetMs: Double) {
            consecutiveTimeouts += 1
            timeoutFloorMs = max(timeoutFloorMs, budgetMs)
        }

        mutating func startProbe(at now: ContinuousClock.Instant, budgetMs: Double) {
            probeStartedAt = now
            probeBudgetMs = budgetMs
        }

        /// `ms` is the probe's latency, or its budget when it timed out (a lower bound). A probe
        /// fast enough for the budget it was sent for closes the breaker.
        mutating func finishProbe(ms: Double, at now: ContinuousClock.Instant) {
            probeStartedAt = nil
            lastProbe = (ms, now)
            if ms <= Self.slowShare * probeBudgetMs {
                consecutiveTimeouts = 0
                timeoutFloorMs = 0
            }
        }

        /// A probe that never got an answer. Whatever the call budget is, this is not "fast": the
        /// breaker stays as it was and the model counts as slow until a newer measurement.
        mutating func finishProbeTimedOut(at now: ContinuousClock.Instant) {
            probeStartedAt = nil
            lastProbe = (.infinity, now)
        }

        mutating func abandonProbe() {
            probeStartedAt = nil
        }
    }

    private struct Shared: Sendable {
        var tracker: Tracker
        var probe: Task<Void, Never>?
        /// Identifies the running probe, so a cancelled one finishing late can't clear a newer one.
        var probeID: UInt64 = 0
        /// Background calls (meeting summaries) on the same loaded model, running now and when the last one ended.
        var backgroundCalls = 0
        var backgroundEndedAt: ContinuousClock.Instant?

        func sharedWithBackground(since start: ContinuousClock.Instant) -> Bool {
            backgroundCalls > 0 || backgroundEndedAt.map { $0 > start } == true
        }
    }

    /// The app's one gate: the model is a process-wide resource, so what one call learns about it
    /// applies to the next. Tests make their own.
    public static let shared = ModelHealth()

    private let state: Mutex<Shared>
    private let probeIntervalSeconds: Double

    /// - Parameter probeIntervalSeconds: minimum gap between probes (tests shorten it).
    public init(probeIntervalSeconds: Double = 3) {
        self.probeIntervalSeconds = probeIntervalSeconds
        state = Mutex(Shared(tracker: Tracker(probeIntervalSeconds: probeIntervalSeconds)))
    }

    /// Whether to call the model for a call with this budget.
    public func verdict(budget: Duration) -> Verdict {
        state.withLock { $0.tracker.verdict(budgetMs: ModelPace.ms(budget), now: .now) }
    }

    /// A real call is starting: a probe still running would only queue in front of it, and the
    /// call itself is the better measurement.
    public func callStarting() {
        let probe = state.withLock { state -> Task<Void, Never>? in
            defer { state.probe = nil; state.tracker.abandonProbe() }
            return state.probe
        }
        probe?.cancel()
    }

    public func recordAnswer() {
        state.withLock { $0.tracker.recordAnswer() }
    }

    /// Only a real timeout counts (the budget race's `.timeout`); an error says nothing about speed. A call
    /// that shared the model with a summary measured the summary's stop, not the model's pace: not counted.
    public func recordTimeout(budget: Duration, elapsed: Duration) {
        guard elapsed >= budget * 0.95 else { return }
        let start = ContinuousClock.now - elapsed
        state.withLock { state in
            guard !state.sharedWithBackground(since: start) else { return }
            state.tracker.recordTimeout(budgetMs: ModelPace.ms(budget))
        }
    }

    /// Whether a call that ran for `elapsed` until now shared the model with background work (`backgroundCall`).
    public func sharedWithBackground(during elapsed: Duration) -> Bool {
        let start = ContinuousClock.now - elapsed
        return state.withLock { $0.sharedWithBackground(since: start) }
    }

    /// Runs `work`, a background call on the model dictation uses (a meeting summary on the shared 4B). While it
    /// runs and until it has stopped, a dictation's timeout or slow probe is the summary's cost, not the model's.
    public func backgroundCall<T>(_ work: () async throws -> T) async rethrows -> T {
        state.withLock { $0.backgroundCalls += 1 }
        defer {
            state.withLock { state in
                state.backgroundCalls -= 1
                state.backgroundEndedAt = .now
            }
        }
        return try await work()
    }

    /// Starts `measure` as a background probe when the model's health is in doubt for calls with
    /// `budget` and no probe is running or recently finished. `measure` returns the probe's
    /// latency in ms (its budget on a timeout), or nil when it was cancelled or could not run.
    public func probeIfNeeded(budget: Duration, _ measure: @escaping @Sendable () async -> Double?) {
        probeIfNeeded(budget: budget, result: { await measure().map { ProbeResult.answered(ms: $0) } })
    }

    /// What a probe found.
    public enum ProbeResult: Sendable {
        /// It answered, this many milliseconds after it started.
        case answered(ms: Double)
        /// It did not answer in its own budget. Never closes the breaker.
        case timedOut
    }

    /// The same, for a probe that can say it timed out. `nil` is a probe that was cancelled or could
    /// not run (nothing was measured).
    public func probeIfNeeded(budget: Duration, result measure: @escaping @Sendable () async -> ProbeResult?) {
        state.withLock { state in
            let now = ContinuousClock.now
            let budgetMs = ModelPace.ms(budget)
            guard state.tracker.wantsProbe(budgetMs: budgetMs, now: now) else { return }
            state.tracker.startProbe(at: now, budgetMs: budgetMs)
            state.probeID &+= 1
            let id = state.probeID
            state.probe = Task(priority: .userInitiated) {
                let result = await measure()
                self.finishProbe(id: id, result: Task.isCancelled ? nil : result)
            }
        }
    }

    private func finishProbe(id: UInt64, result: ProbeResult?) {
        state.withLock { state in
            guard state.probeID == id, state.probe != nil else { return }
            state.probe = nil
            // A slow or timed-out probe that shared the model with a summary measured nothing about the model.
            let contended = state.tracker.probeStartedAt.map(state.sharedWithBackground(since:)) == true
            switch result {
            case .answered(let ms)? where !contended || ms <= Tracker.slowShare * state.tracker.probeBudgetMs:
                state.tracker.finishProbe(ms: ms, at: .now)
            case .timedOut? where !contended: state.tracker.finishProbeTimedOut(at: .now)
            default: state.tracker.abandonProbe()
            }
        }
    }

    /// Whether a probe is running (tests wait on it).
    public var isProbing: Bool {
        state.withLock { $0.probe != nil }
    }

    /// Test hook: waits until the probe running now (if any) has finished and been recorded, so a
    /// test can check what it did without racing it.
    func probeFinished() async {
        let probe = state.withLock { $0.probe }
        await probe?.value
    }

    /// Test and eval hook: forget everything measured so far.
    public func reset() {
        let probe = state.withLock { state -> Task<Void, Never>? in
            defer {
                let id = state.probeID
                state = Shared(tracker: Tracker(probeIntervalSeconds: probeIntervalSeconds))
                state.probeID = id
            }
            return state.probe
        }
        probe?.cancel()
    }
}
