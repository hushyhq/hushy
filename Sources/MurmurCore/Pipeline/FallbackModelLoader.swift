import Foundation

/// Background loading is reserved for Macs above the existing 8 GB small-memory tier.
public enum FallbackWarmupPolicy {
    public static func shouldWarm(guardEnabled: Bool, primaryReady: Bool, physicalMemoryGB: Int) -> Bool {
        guardEnabled && primaryReady && physicalMemoryGB > ModelTierPolicy.smallTierMaximumGB
    }
}

/// How long a dictation whose result was flagged waits for the fallback recogniser's load.
///
/// The load is one of two kinds, and they differ by a factor of fifty. With Core ML's compiled
/// model already cached it takes about half a second. On the first launch of a build Core ML
/// compiles the model again, which took 14 to 29 s on a 24 GB Mac (2026-10-13: a dictation held
/// for that was pasted 26 s after the key was released).
///
/// So the wait is counted from when the load began, not from when the dictation asked: a load
/// still inside `quickLoad` could be the quick kind and is worth waiting out; one that has run
/// past it is the long kind, and the dictation gives it only `floor` more. Past the bound the
/// first recogniser's text goes out as it is and the load carries on for the next dictation.
public enum FallbackWaitPolicy {
    /// Eight times the half second a cached load takes, for slower Macs and a busy launch.
    public static let quickLoad: Duration = .seconds(4)
    /// What a load already known to be the long kind still gets: enough to catch one that is
    /// just finishing, and no more than a person notices as a pause.
    public static let floor: Duration = .seconds(1)

    /// `elapsed` is how long the load has been running; nil when none is (it starts now).
    public static func bound(loadRunningFor elapsed: Duration?) -> Duration {
        guard let elapsed else { return quickLoad }
        return max(floor, quickLoad - elapsed)
    }
}

/// The order of a fallback model's load, so a cancel can stop it only where stopping saves work.
public enum FallbackLoadSteps {
    /// Runs `slow` (the download and compile) unless the task is already cancelled, then `finish`
    /// whatever has happened since: a cancel that arrives once the slow step is done no longer
    /// throws its result away.
    public static func run<Parts, Model>(
        slow: () async throws -> Parts, finish: (Parts) async throws -> Model
    ) async throws -> Model {
        try Task.checkCancellation()
        let parts = try await slow()
        return try await finish(parts)
    }
}

/// A single-flight cache for a fallback model.
///
/// The load is started ahead of need at background priority (`warm`) when no dictation is
/// running, and is then left alone: a dictation that starts while it runs does not cancel it, so
/// dictating right after launch cannot keep it from ever finishing. Only turning the guard off
/// (`stopWarmup`) cancels a load nobody has asked for yet, and a load that returns a model is
/// kept even when that cancel had already arrived.
///
/// A dictation that needs the model asks `get(waitingUpTo:)`, which waits at most the bound and
/// otherwise answers nil while the load carries on for the next dictation.
public actor FallbackModelLoader<Model: Sendable> {
    public enum WarmupEvent: Sendable {
        case started
        case finished(milliseconds: Double)
    }

    public typealias Sleep = @Sendable (Duration) async -> Void

    private let load: @Sendable () async throws -> Model
    private let onWarmupEvent: @Sendable (WarmupEvent) -> Void
    private let sleep: Sleep
    private let now: @Sendable () -> ContinuousClock.Instant
    private var model: Model?
    private var task: Task<Model, Error>?
    /// When the load in `task` began.
    private var loadStartedAt: ContinuousClock.Instant?
    /// Nobody has needed the in-flight load yet: turning the guard off may cancel it.
    private var speculative = false
    private var wantsWarmup = false
    private var activeWork = 0

    /// `sleep` is how a bounded wait counts its bound, and `now` how a load's age is read; tests
    /// pass a clock they move by hand.
    public init(load: @escaping @Sendable () async throws -> Model,
                onWarmupEvent: @escaping @Sendable (WarmupEvent) -> Void = { _ in },
                sleep: @escaping Sleep = { try? await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.load = load
        self.onWarmupEvent = onWarmupEvent
        self.sleep = sleep
        self.now = now
    }

    /// Starts at most one low-priority load. Never waits for it.
    public func warm() {
        wantsWarmup = true
        startWarmupIfIdle()
    }

    /// The guard was turned off: a load nobody has needed is cancelled. If it has already got
    /// past its slow step it still finishes, and its model is kept.
    public func stopWarmup() {
        wantsWarmup = false
        if speculative { task?.cancel() }
    }

    /// A dictation started. A load already running is left to run (it is at background
    /// priority); only a load that has not started yet waits for the dictation to finish.
    public func workStarted() {
        activeWork += 1
    }

    public func workFinished() {
        activeWork -= 1
        startWarmupIfIdle()
    }

    /// The loaded model, if the load has finished.
    public var loaded: Model? { model }

    /// How long the load in flight has been running; nil when none is (loaded, or not started).
    public var loadRunningFor: Duration? {
        guard model == nil, task != nil, let loadStartedAt else { return nil }
        return now() - loadStartedAt
    }

    /// The model, however long its load takes. For callers that must have it; a dictation uses
    /// `get(waitingUpTo:)`.
    public func get() async throws -> Model {
        if let model { return model }
        while true {
            if task == nil {
                task = Task(priority: .userInitiated) { try await load() }
                loadStartedAt = now()
                speculative = false
            }
            guard let current = task else { continue }
            // Once a fallback needs this load, turning the guard off must not cancel it.
            speculative = false
            do {
                let loaded = try await current.value
                model = loaded
                if task == current { task = nil; speculative = false }
                return loaded
            } catch is CancellationError where current.isCancelled {
                if task == current { task = nil; speculative = false }
                // The load had been cancelled before it was needed. The needed fallback retries.
            } catch {
                if task == current { task = nil; speculative = false }
                throw error
            }
        }
    }

    /// The model if it is ready within `bound`, otherwise nil. Leaving on the bound never
    /// cancels the load: it carries on, and its model is there for the next caller. Throws only
    /// when the load failed inside the bound.
    public func get(waitingUpTo bound: Duration) async throws -> Model? {
        if let model { return model }
        // The unbounded wait does the work (adopts or starts the load, retries a cancelled one
        // and stores the model); this caller only decides how long to stay for it.
        let waiter = Task { try await self.get() }
        let sleep = self.sleep
        let outcome: Result<Model, Error>? = await withCheckedContinuation { continuation in
            let once = RaceResume(continuation)
            Task { once.resume(.some(await waiter.result)) }
            Task {
                await sleep(bound)
                once.resume(nil)
            }
        }
        return try outcome?.get()
    }

    private func startWarmupIfIdle() {
        guard wantsWarmup, activeWork == 0, model == nil, task == nil else { return }
        let started = Date()
        onWarmupEvent(.started)
        let current = Task(priority: .background) { try await load() }
        task = current
        loadStartedAt = now()
        speculative = true
        Task { await finishWarmup(current, started: started) }
    }

    private func finishWarmup(_ current: Task<Model, Error>, started: Date) async {
        let loaded = try? await current.value
        onWarmupEvent(.finished(milliseconds: Date().timeIntervalSince(started) * 1_000))
        // A model is kept whoever is tracking the load by now, and whether or not a cancel arrived.
        if let loaded, model == nil { model = loaded }
        guard task == current else { return }
        task = nil
        speculative = false
        if loaded == nil {
            // Retried only when it was cancelled and the guard has been turned back on since;
            // an ordinary error stays lazy (the first dictation that needs the model loads it).
            wantsWarmup = wantsWarmup && current.isCancelled
            startWarmupIfIdle()
        }
    }
}
