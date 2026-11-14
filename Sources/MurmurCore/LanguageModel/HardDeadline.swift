import Foundation
import Synchronization

/// Runs async work and gives control back at a deadline, even when the work never looks at
/// cancellation. A structured task group cannot do this: it waits for every child before it returns,
/// so a backend that ignores `Task.cancel()` would hold the caller (and the person's pasted text)
/// hostage. Here the work and the timer are separate tasks; whichever finishes first resumes the
/// caller exactly once, and the other is cancelled. A work task that keeps running after being
/// cancelled is abandoned, not awaited.
enum HardDeadline {
    private final class Gate<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T?, Never>?
            var finished = false
            var value: T?
            var tasks: [Task<Void, Never>] = []
        }

        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<T?, Never>) {
            let early: (value: T?, resumeNow: Bool) = state.withLock { state in
                if state.finished { return (state.value, true) }
                state.continuation = continuation
                return (nil, false)
            }
            if early.resumeNow { continuation.resume(returning: early.value) }
        }

        func add(_ task: Task<Void, Never>) {
            let finished = state.withLock { state -> Bool in
                if state.finished { return true }
                state.tasks.append(task)
                return false
            }
            if finished { task.cancel() }
        }

        /// Decides the winner. The winner's `whenWon` runs before the waiting caller is resumed, so nobody who
        /// waits on the result can observe state from before the call finished.
        @discardableResult
        func finish(_ value: T?, whenWon: () -> Void = {}) -> Bool {
            let taken = state.withLock { state -> (CheckedContinuation<T?, Never>?, [Task<Void, Never>])? in
                guard !state.finished else { return nil }
                state.finished = true
                state.value = value
                defer { state.continuation = nil; state.tasks = [] }
                return (state.continuation, state.tasks)
            }
            guard let (continuation, tasks) = taken else { return false }
            whenWon()
            for task in tasks { task.cancel() }
            continuation?.resume(returning: value)
            return true
        }
    }

    /// `operation`'s result, or nil when `deadline` passes first or the calling task is cancelled.
    ///
    /// `tracking` is a slot the caller reserved (`AbandonedCalls.tryBegin`). It is released when the call
    /// finishes in time, and moved to "left behind" only at the moment the operation is abandoned, and
    /// released for good when the abandoned operation finally returns. A call that finishes in time is
    /// therefore never counted as left behind, not even for an instant.
    static func run<T: Sendable>(
        until deadline: ContinuousClock.Instant, tracking: AbandonedCalls? = nil,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let gate = Gate<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                gate.install(continuation)
                gate.add(Task {
                    let value = await operation()
                    if !gate.finish(value, whenWon: { tracking?.finishedInTime() }) { tracking?.abandonedReturned() }
                })
                gate.add(Task {
                    // A sleep that throws was cancelled because the work (or the caller) already won.
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    gate.finish(nil, whenWon: { tracking?.abandoned() })
                })
            }
        } onCancel: {
            gate.finish(nil, whenWon: { tracking?.abandoned() })
        }
    }

    /// `task`'s value, or nil at `deadline` (the task is cancelled then, and not waited for).
    static func value<T: Sendable>(of task: Task<T, Never>, until deadline: ContinuousClock.Instant) async -> T? {
        let result = await run(until: deadline) { await task.value }
        if result == nil { task.cancel() }
        return result
    }
}

/// Model calls in flight, and calls left behind at their deadline that have not returned yet. A backend
/// that honours cancellation gives a left-behind call back within milliseconds; one that ignores it keeps a
/// task (and whatever it captured) alive per abandoned call, so with `limit` slots taken, in flight or left
/// behind, no further call is started and the caller takes the rules text at once.
///
/// One shared instance (`shared`) serves the cleanup backend of the app. Reserving a slot and checking the
/// limit is one atomic step (`tryBegin`), so overlapping calls cannot all slip past the check.
public final class AbandonedCalls: Sendable {
    public static let limit = 2
    public static let shared = AbandonedCalls()

    private struct State {
        var inFlight = 0
        var leftBehind = 0
    }

    private let state = Mutex(State())
    public init() {}

    /// Calls left behind at their deadline and not yet returned.
    public var outstanding: Int { state.withLock { $0.leftBehind } }
    /// Calls started and neither finished nor left behind.
    public var inFlight: Int { state.withLock { $0.inFlight } }

    /// Takes a slot for a call about to start, or refuses when the limit is already reached.
    func tryBegin() -> Bool {
        state.withLock { state in
            guard state.inFlight + state.leftBehind < Self.limit else { return false }
            state.inFlight += 1
            return true
        }
    }

    func finishedInTime() { state.withLock { $0.inFlight = max(0, $0.inFlight - 1) } }

    func abandoned() {
        state.withLock { state in
            state.inFlight = max(0, state.inFlight - 1)
            state.leftBehind += 1
        }
    }

    func abandonedReturned() { state.withLock { $0.leftBehind = max(0, $0.leftBehind - 1) } }
}
