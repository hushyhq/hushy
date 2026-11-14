import Foundation

/// When the local model is paused after it failed, and when it is asked again.
///
/// A failed load, or `maxConsecutiveFailures` failed calls in a row, pause the model: it reports unavailable and the
/// chain answers from its fallback. The pause ends on its own and the next call tries the model again. A failure on
/// that call pauses it at once, for twice as long (`firstPause` doubling up to `longestPause`); a success ends the
/// backoff. A transient GPU or memory error so costs a few dictations on the fallback, never the rest of the session.
///
/// A call that began before the current pause was asked of the model before its trouble was known, so its result says
/// nothing new: its failure does not lengthen the pause and its success does not end it.
struct MLXHealth: Sendable {
    let maxConsecutiveFailures: Int
    let firstPause: Duration
    let longestPause: Duration

    init(maxConsecutiveFailures: Int = 3, firstPause: Duration = .seconds(30), longestPause: Duration = .seconds(600)) {
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.firstPause = firstPause
        self.longestPause = longestPause
    }

    private var consecutiveFailures = 0
    /// Pauses since the last success. While above zero the model is on trial: one failure pauses it again.
    private var pauses = 0
    private var pausedAt: ContinuousClock.Instant?
    private var pausedUntil: ContinuousClock.Instant?
    private var reason: String?

    /// Why the model is paused at `now`, or nil when it may be asked.
    func pauseReason(at now: ContinuousClock.Instant) -> String? {
        guard let pausedUntil, now < pausedUntil else { return nil }
        return reason
    }

    private func predatesPause(_ callStarted: ContinuousClock.Instant) -> Bool {
        pausedAt.map { callStarted < $0 } ?? false
    }

    mutating func recordSuccess(callStarted: ContinuousClock.Instant) {
        guard !predatesPause(callStarted) else { return }
        consecutiveFailures = 0
        pauses = 0
        pausedAt = nil
        pausedUntil = nil
        reason = nil
    }

    /// Counts a failure that says something about the model's health. Returns the pause it starts, if it starts one.
    mutating func recordFailure(
        _ why: String, loadFailed: Bool, callStarted: ContinuousClock.Instant, at now: ContinuousClock.Instant
    ) -> Duration? {
        guard !predatesPause(callStarted) else { return nil }
        consecutiveFailures += 1
        guard loadFailed || pauses > 0 || consecutiveFailures >= maxConsecutiveFailures else { return nil }
        let pause = min(longestPause, firstPause * (1 << min(pauses, 16)))
        reason = "MLX paused for \(pause.components.seconds) s after \(consecutiveFailures) failure(s): \(why)"
        pauses += 1
        consecutiveFailures = 0
        pausedAt = now
        pausedUntil = now + pause
        return pause
    }
}
