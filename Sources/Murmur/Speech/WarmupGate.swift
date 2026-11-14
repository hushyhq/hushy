import Foundation

/// Lets a background warm-up yield to real work: at most one warm-up runs, never while real work is running,
/// and real work starting cancels it. Plain state for an actor to hold (`SpeechEngine`); it does no locking.
struct WarmupGate {
    private var warmup: Task<Void, Never>?
    private var realWork = 0

    /// Real work is starting: any warm-up in progress is cancelled.
    mutating func workStarted() {
        realWork += 1
        warmup?.cancel()
        warmup = nil
    }

    mutating func workFinished() { realWork -= 1 }

    /// Starts `body` as the warm-up, or returns nil when real work is running or a warm-up already is.
    mutating func startWarmup(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        guard realWork == 0, warmup == nil else { return nil }
        let task = Task(priority: .utility, operation: body)
        warmup = task
        return task
    }

    /// The warm-up has ended; a newer one is not affected.
    mutating func warmupEnded(_ task: Task<Void, Never>) {
        if warmup == task { warmup = nil }
    }
}
