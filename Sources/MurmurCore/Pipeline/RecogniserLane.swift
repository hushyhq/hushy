import Foundation

/// One lane onto the speech recogniser, so the pill's live draft (`LiveDraftSession`) never runs at the same time
/// as the recognition that matters: the early-cleaning passes and the pass after the key release.
///
/// The draft only ever takes the lane when it is free and nobody is waiting for it (`claimDraft`); it never waits.
/// Other work (`exclusive`) never waits for other work, only for a draft already running, and from the moment it
/// asks no new draft can start. A draft pass reads a few seconds of audio, so that wait is one short pass at most;
/// `exclusive` reports how long it was, so the release can log it.
///
/// Work nobody is waiting for (`whenIdle`: the re-read of a cancelled take) goes the other way. It starts only when no
/// draft, no other pass and no other idle work is running or waiting, and every pass that asks while it runs waits for
/// it, as for a draft. It never makes a pass wait that was already running or waiting when it asked. Idle work that is
/// cancelled while it waits leaves the queue at once and throws `CancellationError`, so a waiting re-read cannot take
/// the gap between two drafts of a take that began after it asked.
public actor RecogniserLane {
    private var draftRunning = false
    private var idleWorkRunning = false
    private var others = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var idleWaiting: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var nextIdleWaiter: UInt64 = 0
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    /// True while a draft holds the lane (tests read this).
    public var isDraftRunning: Bool { draftRunning }

    /// Takes the lane for one draft pass, or returns false when anything else is running or waiting.
    public func claimDraft() -> Bool {
        guard !draftRunning, !idleWorkRunning, others == 0 else { return false }
        draftRunning = true
        return true
    }

    /// The draft pass has ended; whoever was waiting for it goes on at once.
    public func releaseDraft() {
        draftRunning = false
        wakeEveryone()
    }

    /// Passes that waited for a draft or for idle work go on, and idle work that waited for the lane to be free
    /// looks again.
    private func wakeEveryone() {
        let resumed = waiting
        let idleResumed = Array(idleWaiting.values)
        waiting = []
        idleWaiting = [:]
        for continuation in resumed { continuation.resume() }
        for continuation in idleResumed { continuation.resume() }
    }

    /// Runs `body` on the recogniser once no draft is running; `onWait` is told how long that took (zero when none
    /// was). Several of these may run together, exactly as they did before there was a draft.
    public nonisolated func exclusive<T: Sendable>(
        onWait: @Sendable (Duration) -> Void = { _ in }, _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let waited = await enter()
        onWait(waited)
        do {
            let value = try await body()
            await leave()
            return value
        } catch {
            await leave()
            throw error
        }
    }

    /// Runs `body` once nothing else wants the recogniser: no draft, no `exclusive` pass running or waiting, no other
    /// idle work. Use it for work that can wait as long as it needs to. Cancelling it while it waits gives up its
    /// place; the caller asks again when it is time.
    public nonisolated func whenIdle<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await beginIdleWork()
        do {
            let value = try await body()
            await endIdleWork()
            return value
        } catch {
            await endIdleWork()
            throw error
        }
    }

    private func beginIdleWork() async throws {
        while draftRunning || idleWorkRunning || others > 0 {
            try Task.checkCancellation()
            let id = nextIdleWaiter
            nextIdleWaiter += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    idleWaiting[id] = continuation
                }
            } onCancel: {
                Task { await self.abandonIdleWait(id) }
            }
        }
        try Task.checkCancellation()
        idleWorkRunning = true
    }

    private func abandonIdleWait(_ id: UInt64) {
        idleWaiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func endIdleWork() {
        idleWorkRunning = false
        wakeEveryone()
    }

    private func enter() async -> Duration {
        others += 1
        let start = now()
        while draftRunning || idleWorkRunning { await withCheckedContinuation { waiting.append($0) } }
        return now() - start
    }

    private func leave() {
        others -= 1
        if others == 0 { wakeEveryone() }
    }
}
