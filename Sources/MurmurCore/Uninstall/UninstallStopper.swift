import Foundation

/// One thing that has to stop before anything is removed, named the way the person would name it.
public struct UninstallStopStep: Sendable {
    /// True until the step has run out of time.
    public typealias StillWanted = @Sendable () -> Bool

    public let name: String
    public let work: @Sendable (_ isStillWanted: @escaping StillWanted) async -> Void

    public init(_ name: String, _ work: @escaping @Sendable () async -> Void) {
        self.init(name, checking: { _ in await work() })
    }

    /// For a step that waits and then discards, deletes or closes something for good. A step
    /// that runs out of time is left to finish by itself, and by then the uninstall has been
    /// abandoned: such work asks `isStillWanted` after its wait, in the same turn as the act,
    /// and does nothing that cannot be undone once the answer is false.
    public init(
        _ name: String, checking work: @escaping @Sendable (_ isStillWanted: @escaping StillWanted) async -> Void
    ) {
        self.name = name
        self.work = work
    }
}

/// Something did not stop in time. Nothing has been removed, but the steps before it have run
/// and are not undone.
public struct UninstallStopFailure: Error, LocalizedError, Equatable, Sendable {
    public let notStopped: String

    public init(notStopped: String) {
        self.notStopped = notStopped
    }

    public var errorDescription: String? {
        "Hushy could not stop \(notStopped) in time."
    }
}

/// Runs the stop steps in order and gives each a time limit, so an uninstall can never wait
/// for ever on something that will not stop.
public enum UninstallStopper {
    /// How long one step may take.
    public static let stepLimit: Duration = .seconds(15)

    /// Throws `UninstallStopFailure` naming the first step that did not finish within `limit`.
    /// The steps after it are not run.
    public static func stop(
        _ steps: [UninstallStopStep], limit: Duration = stepLimit,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async throws {
        for step in steps {
            guard await finishes(step.work, within: limit, sleep: sleep) else {
                throw UninstallStopFailure(notStopped: step.name)
            }
        }
    }

    /// True when `work` returned before the limit. Past the limit the answer is false and
    /// `work` is left to finish, or not, by itself: nothing waits for it, and from that moment
    /// what it was handed answers that the step is no longer wanted.
    static func finishes(
        _ work: @escaping @Sendable (_ isStillWanted: @escaping UninstallStopStep.StillWanted) async -> Void,
        within limit: Duration, sleep: @escaping @Sendable (Duration) async -> Void
    ) async -> Bool {
        let first = FirstToFinish()
        return await withCheckedContinuation { continuation in
            let timer = Task {
                await sleep(limit)
                if first.claim(asTimeout: true) { continuation.resume(returning: false) }
            }
            Task {
                await work { !first.hasTimedOut }
                if first.claim() {
                    timer.cancel()
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// Lets exactly one of the two racers answer, and remembers when it was the timer.
    private final class FirstToFinish: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        private var timedOut = false

        func claim(asTimeout: Bool = false) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            timedOut = asTimeout
            return true
        }

        var hasTimedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }
    }
}
