import Foundation
import Synchronization

/// The names in the user's Shortcuts library, fetched alongside the model call and waited for
/// only when the model proposes a Shortcut. The wait is a race with no waiter task: the listing
/// reports its own result, a timer (cancelled the moment anything settles) ends the wait at the
/// deadline, and cancelling the caller (Esc) ends it at once. Whatever loses is cancelled.
final class ShortcutListing: Sendable {
    private enum Outcome { case listing([String]), gaveUp }

    private struct State {
        var outcome: Outcome?
        var continuation: CheckedContinuation<[String]?, Never>?
        var timer: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let work = Mutex<Task<Void, Never>?>(nil)

    init(_ library: @escaping @Sendable () async -> [String]) {
        let task = Task { [self] in settle(.listing(await library())) }
        work.withLock { $0 = task }
    }

    /// Stops the listing (when it honours cancellation) and answers any waiter with nil.
    func cancel() {
        work.withLock { $0 }?.cancel()
        settle(.gaveUp)
    }

    /// The names, or nil when `limit` passes first, the caller is cancelled, or the listing was
    /// cancelled. A `limit` of zero or less is already past: nil at once, ready or not. A nil
    /// `limit` waits for the listing.
    func value(within limit: Duration?) async -> [String]? {
        if let limit, limit <= .zero {
            cancel()
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
                let ready: Outcome? = state.withLock { state in
                    if let outcome = state.outcome { return outcome }
                    state.continuation = continuation
                    if let limit {
                        state.timer = Task { [self] in
                            try? await Task.sleep(for: limit)
                            if !Task.isCancelled { settle(.gaveUp) }
                        }
                    }
                    return nil
                }
                if let ready { continuation.resume(returning: Self.names(in: ready)) }
            }
        } onCancel: {
            cancel()
        }
    }

    private func settle(_ outcome: Outcome) {
        let (continuation, timer) = state.withLock { state -> (CheckedContinuation<[String]?, Never>?, Task<Void, Never>?) in
            guard state.outcome == nil else { return (nil, nil) }
            state.outcome = outcome
            defer { state.continuation = nil; state.timer = nil }
            return (state.continuation, state.timer)
        }
        timer?.cancel()
        continuation?.resume(returning: Self.names(in: outcome))
    }

    private static func names(in outcome: Outcome) -> [String]? {
        if case .listing(let names) = outcome { names } else { nil }
    }
}
