import Foundation
import Synchronization

/// What a bounded wait throws when its limit passes first.
public struct DeadlineExpired: Error, Equatable, Sendable, LocalizedError {
    public init() {}
    public var errorDescription: String? { "the step did not answer in time" }
}

/// A wait with a limit, for work that may never answer (a recogniser stalled on the Neural Engine after a sleep).
///
/// Structured concurrency cannot do this: a task group waits for every child on the way out, and a stalled child
/// ignores cancellation, so the group would wait as long as the child. This resumes the caller at the limit and leaves
/// the stalled work behind, cancelled, to finish or never finish on its own.
public enum Deadline {
    /// The value of `body`, or `DeadlineExpired` once `limit` has passed. Cancelling the caller cancels `body`.
    public static func race<T: Sendable>(
        _ limit: Duration, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, limit: limit, body: body)
            }
        } onCancel: {
            race.cancelWork()
        }
    }
}

private final class Race<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var finished = false
        var cancelled = false
    }

    private let state = Mutex(State())

    func start(
        _ continuation: CheckedContinuation<T, any Error>, limit: Duration,
        body: @escaping @Sendable () async throws -> T
    ) {
        state.withLock { $0.continuation = continuation }
        let work = Task {
            do { finish(.success(try await body())) } catch { finish(.failure(error)) }
        }
        let timer = Task {
            do { try await Task.sleep(for: limit) } catch { return }
            finish(.failure(DeadlineExpired()))
        }
        let (over, cancelled) = state.withLock { state -> (Bool, Bool) in
            state.work = work
            state.timer = timer
            return (state.finished, state.cancelled)
        }
        if over { work.cancel(); timer.cancel() } else if cancelled { work.cancel() }
    }

    func cancelWork() {
        let work = state.withLock { state -> Task<Void, Never>? in
            state.cancelled = true
            return state.work
        }
        work?.cancel()
    }

    private func finish(_ result: Result<T, any Error>) {
        let taken = state.withLock { state -> (CheckedContinuation<T, any Error>, Task<Void, Never>?, Task<Void, Never>?)? in
            guard !state.finished, let continuation = state.continuation else { return nil }
            state.finished = true
            state.continuation = nil
            return (continuation, state.work, state.timer)
        }
        guard let (continuation, work, timer) = taken else { return }
        work?.cancel()
        timer?.cancel()
        continuation.resume(with: result)
    }
}
