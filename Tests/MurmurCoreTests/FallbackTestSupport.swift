import Foundation
import os
@testable import MurmurCore

/// A moment a test moves by hand, for code that reads how long something has been running.
final class HandTime: Sendable {
    private let instant = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ duration: Duration) { instant.withLock { $0 += duration } }
}

/// A fallback "model" load a test holds and releases by hand. The model is the load's number.
actor FakeFallback {
    /// Whether the load notices a cancel when it is released: true for a load still inside its
    /// slow step, false for one that has already got past it.
    private let stopsWhenCancelled: Bool
    private let failure: (any Error)?
    private(set) var loads = 0
    private(set) var sawCancel = false
    private var releaseLoad: [CheckedContinuation<Void, Never>] = []
    private var loadStarted: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(stopsWhenCancelled: Bool = true, failure: (any Error)? = nil) {
        self.stopsWhenCancelled = stopsWhenCancelled
        self.failure = failure
    }

    func load() async throws -> Int {
        loads += 1
        let number = loads
        loadStarted.forEach { $0.resume() }
        loadStarted = []
        if !isReleased { await withCheckedContinuation { releaseLoad.append($0) } }
        if Task.isCancelled { sawCancel = true }
        if stopsWhenCancelled { try Task.checkCancellation() }
        if let failure { throw failure }
        return number
    }

    func release() {
        isReleased = true
        releaseLoad.forEach { $0.resume() }
        releaseLoad = []
    }

    func waitUntilStarted() async {
        if loads > 0 { return }
        await withCheckedContinuation { loadStarted.append($0) }
    }
}

/// A clock a test moves by hand: `sleep` returns only when `fire` is called, so a bounded wait
/// ends exactly when the test says the bound has passed, never on real time.
actor HandClock {
    private(set) var requested: [Duration] = []
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { continuation in
            sleepers.append(continuation)
            watchers.forEach { $0.resume() }
            watchers = []
        }
    }

    /// The bound passes for everyone waiting now.
    func fire() {
        sleepers.forEach { $0.resume() }
        sleepers = []
    }

    /// Resolves once somebody is waiting on the clock.
    func waitForSleeper() async {
        if !sleepers.isEmpty { return }
        await withCheckedContinuation { watchers.append($0) }
    }
}

extension FallbackModelLoader where Model == Int {
    /// A loader on a fake load and a hand-moved clock.
    static func fake(_ fake: FakeFallback, clock: HandClock) -> FallbackModelLoader<Int> {
        FallbackModelLoader(load: { try await fake.load() }, sleep: { await clock.sleep($0) })
    }
}
