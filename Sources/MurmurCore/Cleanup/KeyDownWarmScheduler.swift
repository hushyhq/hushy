import Foundation
import Synchronization
import os

/// One warm call per recent recording. Scheduling is synchronous and only takes a lock; work runs off the caller.
public final class KeyDownWarmScheduler: Sendable {
    private struct State {
        var lastStart: ContinuousClock.Instant?
        var running: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let warm: @Sendable () async -> Void
    private let log = Logger(subsystem: "app.hushy", category: "pipeline")
    private let interval: Duration

    public init(interval: Duration = .seconds(60), warm: @escaping @Sendable () async -> Void) {
        self.interval = interval
        self.warm = warm
    }

    @discardableResult
    public func schedule() -> Bool {
        let now = ContinuousClock.now
        let task = state.withLock { state -> Task<Void, Never>? in
            guard state.running == nil,
                  state.lastStart.map({ now - $0 >= interval }) ?? true else { return nil }
            state.lastStart = now
            let task = Task.detached(priority: .userInitiated) { [self] in
                let start = ContinuousClock.now
                await warm()
                let ms = Int(ModelPace.ms(ContinuousClock.now - start))
                log.notice("warm on key-down: model ms=\(ms) cancelled=\(Task.isCancelled ? 1 : 0)")
                self.state.withLock { $0.running = nil }
            }
            state.running = task
            return task
        }
        if task == nil { log.notice("warm on key-down: skipped, warm=1") }
        return task != nil
    }

    /// Release cancels unfinished work and waits for its GPU pass before cleanup can use the model.
    public func beforeRealCall() async {
        let running = state.withLock { $0.running }
        running?.cancel()
        await running?.value
    }
}
