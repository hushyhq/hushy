import Foundation
import Synchronization
import os

/// A loaded model whose memory can be read as raw ranges (the MLX backend). nil: nothing loaded.
public protocol ResidentModelMemory: Sendable {
    func memoryRegions() async -> ModelMemoryRegions?
}

/// Signals that usually come shortly before a dictation, or that say the person is at the Mac.
public enum WarmSignal: String, Sendable, CaseIterable {
    case wake
    case screenUnlock = "screen-unlock"
    case sessionActive = "session-active"
    case backFromIdle = "back-from-idle"
    case appActivated = "app-activated"
    /// Every `IdleWatcher.tickInterval` while the person is using the Mac.
    case activeTick = "active-tick"

    /// Strong signals may load a model that is not in memory (on 8 GB Macs it is unloaded after idle).
    /// Wake is left out: `WakeRewarmer` already loads the model and its prefixes then.
    var mayLoad: Bool { self == .screenUnlock || self == .backFromIdle || self == .sessionActive }
}

/// What the Mac is doing right now, read when a signal arrives.
public struct WarmConditions: Equatable, Sendable {
    public var onBattery = false
    public var lowPowerMode = false
    public var thermal: ProcessInfo.ThermalState = .nominal
    public var memoryPressure: MemoryPressureLevel = .normal
    /// The 1-minute load average is at least 3/4 of the active cores (builds, evals, training).
    public var busyCPU = false

    public init(onBattery: Bool = false, lowPowerMode: Bool = false, thermal: ProcessInfo.ThermalState = .nominal,
                memoryPressure: MemoryPressureLevel = .normal, busyCPU: Bool = false) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.memoryPressure = memoryPressure
        self.busyCPU = busyCPU
    }
}

/// When a signal may touch the model's pages, and how.
public struct WarmPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case skip(String)
        /// Read the pages that are still in RAM (marks them used; pages nothing in).
        case refresh
        /// Read every page, paging back in what macOS compressed or swapped out.
        case restore
    }

    /// Below this share of pages in RAM a restore pages the rest back in.
    public static let residentEnough = 0.98
    /// Threads for a predictive restore: measured 2026-10-28 (residency-probe), see DECISIONS.
    public static let restoreThreads = 4
    /// Threads at key-down, when the person is waiting.
    public static let keyDownThreads = 8
    /// One background thread is enough to mark resident pages used.
    public static let refreshThreads = 1

    /// Signals other than the active tick closer together than this are dropped.
    public var minimumGap: Duration = .seconds(20)

    public init(minimumGap: Duration = .seconds(20)) {
        self.minimumGap = minimumGap
    }

    public func decide(_ signal: WarmSignal, _ conditions: WarmConditions, sinceLast: Duration?) -> Decision {
        if conditions.lowPowerMode { return .skip("low-power") }
        if conditions.thermal == .serious || conditions.thermal == .critical { return .skip("thermal") }
        // Taking 3 GB back under pressure only pushes someone else out, and macOS would take it again.
        if conditions.memoryPressure != .normal { return .skip("memory-pressure") }
        // No standing cost on battery: only the signals that mean the person just came back.
        if conditions.onBattery, signal == .activeTick || signal == .appActivated { return .skip("battery") }
        if signal != .activeTick, let sinceLast, sinceLast < minimumGap { return .skip("recent") }
        // The founder's own heavy jobs: never page anything in, only keep what is already there.
        if conditions.busyCPU { return .refresh }
        return .restore
    }
}

/// Keeps the local model's pages in RAM between dictations, so the first one after idle does not wait while the
/// GPU faults 3 GB back in one page at a time. Signals come from `PredictiveWarmer` (app); every action runs off
/// the caller on a GCD queue at utility or background QoS, one at a time.
public final class ModelWarmthKeeper: Sendable {
    public enum Outcome: Equatable, Sendable {
        case skipped(String)
        case notLoaded(loading: Bool)
        case touched(before: Double, after: Double, pages: Int, threads: Int, milliseconds: Double, refresh: Bool)
    }

    private struct State {
        var running = false
        var lastCheck: ContinuousClock.Instant?
    }

    private let memory: @Sendable () async -> (any ResidentModelMemory)?
    private let conditions: @Sendable () -> WarmConditions
    private let load: @Sendable () -> Void
    private let policy: WarmPolicy
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = Mutex(State())
    private let log = Logger(subsystem: "app.hushy", category: "residency")

    public init(
        policy: WarmPolicy = WarmPolicy(),
        memory: @escaping @Sendable () async -> (any ResidentModelMemory)?,
        conditions: @escaping @Sendable () -> WarmConditions,
        load: @escaping @Sendable () -> Void = {},
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.policy = policy
        self.memory = memory
        self.conditions = conditions
        self.load = load
        self.now = now
    }

    @discardableResult
    public func handle(_ signal: WarmSignal) async -> Outcome {
        let instant = now()
        let current = conditions()
        let decision = state.withLock { state -> WarmPolicy.Decision in
            if state.running { return .skip("running") }
            let decision = policy.decide(signal, current, sinceLast: state.lastCheck.map { instant - $0 })
            if case .skip = decision { return decision }
            state.running = true
            state.lastCheck = instant
            return decision
        }
        if case .skip(let reason) = decision {
            if signal != .activeTick { log.info("model pages signal=\(signal.rawValue, privacy: .public) skipped=\(reason, privacy: .public)") }
            return .skipped(reason)
        }
        defer { state.withLock { $0.running = false } }
        guard let memory = await memory(), let regions = await memory.memoryRegions() else {
            let loading = decision == .restore && signal.mayLoad
            if loading { load() }
            log.notice("model pages signal=\(signal.rawValue, privacy: .public) loaded=0 load=\(loading ? 1 : 0)")
            return .notLoaded(loading: loading)
        }
        let outcome = await Self.run(decision, on: regions)
        if case .touched(let before, let after, let pages, let threads, let ms, let refresh) = outcome {
            let line = "model pages signal=\(signal.rawValue) mode=\(refresh ? "refresh" : "restore") before=\(String(format: "%.3f", before)) after=\(String(format: "%.3f", after)) pages=\(pages) threads=\(threads) ms=\(Int(ms))"
            if before < WarmPolicy.residentEnough { log.notice("\(line, privacy: .public)") } else { log.info("\(line, privacy: .public)") }
        }
        return outcome
    }

    /// The restore itself. Nearly all in RAM: one thread reads every page (about 2 ms for the resident 4B; the
    /// odd missing page comes back). Missing pages and allowed to page in: `restoreThreads` threads. Missing
    /// pages on a busy Mac: only the resident ones are read (a `mincore` per chunk, about 0.2 s), none paged in.
    static func run(_ decision: WarmPolicy.Decision, on regions: ModelMemoryRegions) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: decision == .refresh ? .background : .utility).async {
                let before = PageResidency.sample(regions, stride: PageResidency.sampleStride(regions))
                let resident = before.fraction >= WarmPolicy.residentEnough
                let restore = decision == .restore && !resident
                let report = PageResidency.touch(
                    regions, threads: restore ? WarmPolicy.restoreThreads : WarmPolicy.refreshThreads,
                    residentOnly: !resident && !restore)
                let after = resident ? before.fraction : PageResidency.sample(regions, stride: PageResidency.sampleStride(regions)).fraction
                continuation.resume(returning: .touched(
                    before: before.fraction, after: after, pages: report.pages, threads: report.threads,
                    milliseconds: report.milliseconds + before.milliseconds, refresh: !restore))
            }
        }
    }
}
