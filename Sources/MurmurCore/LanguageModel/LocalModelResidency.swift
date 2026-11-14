import Dispatch
import Foundation
import Synchronization

/// A backend that holds weights in memory and can let go of them (the MLX model). The next call
/// or prewarm loads it again.
public protocol UnloadableLanguageModel: LanguageModel {
    func unload() async
}

public enum MemoryPressureLevel: String, Sendable {
    case normal, warning, critical
}

/// When a local model may stay in memory (M6, MODEL-STRATEGY §3.3):
/// - loaded lazily by the first prewarm/call (off the main actor — the MLX engine runs on its own
///   queue);
/// - on ≤ 8 GB Macs, unloaded after `idleSeconds` (120 s) without a call; session-long otherwise;
/// - on `.critical` memory pressure, unloaded at once and kept out — calls fail fast with
///   `LanguageModelError.busy` (transient, not slow: `ModelHealth` ignores it and a
///   `FallbackLanguageModel` goes on to Apple FM / rules) — until the system reports `.normal`.
public final class LocalModelResidency: Sendable {
    public struct Stats: Equatable, Sendable {
        public var calls = 0
        public var idleUnloads = 0
        public var pressureUnloads = 0
        public var manualUnloads = 0
    }

    public enum UnloadReason: String, Sendable {
        case idle, memoryPressure = "memory-pressure", manual
    }

    private struct State {
        var stats = Stats()
        var inFlight = 0
        var generation = 0
        var suspendedForPressure = false
        var idleTask: Task<Void, Never>?
    }

    public let idleSeconds: TimeInterval?
    private let clock: any DownloadClock
    private let unloadAction: @Sendable () async -> Void
    private let onUnload: @Sendable (UnloadReason) -> Void
    private let state = Mutex(State())

    public init(
        idleSeconds: TimeInterval?, clock: any DownloadClock = SystemDownloadClock(),
        unload: @escaping @Sendable () async -> Void, onUnload: @escaping @Sendable (UnloadReason) -> Void = { _ in }
    ) {
        self.idleSeconds = idleSeconds
        self.clock = clock
        self.unloadAction = unload
        self.onUnload = onUnload
    }

    public var stats: Stats { state.withLock { $0.stats } }
    public var isSuspended: Bool { state.withLock { $0.suspendedForPressure } }

    /// A call is starting: no idle unload may fire until it ends.
    public func callStarted() {
        state.withLock {
            $0.stats.calls += 1
            $0.inFlight += 1
            $0.generation += 1
            $0.idleTask?.cancel()
            $0.idleTask = nil
        }
    }

    public func callEnded() {
        let schedule = state.withLock { state -> Bool in
            state.inFlight = max(0, state.inFlight - 1)
            return state.inFlight == 0
        }
        if schedule { scheduleIdleUnload() }
    }

    /// A prewarm (key-down) loaded or touched the model: restart the idle clock.
    public func touched() {
        let idle = state.withLock { $0.inFlight == 0 }
        if idle { scheduleIdleUnload() }
    }

    public func memoryPressure(_ level: MemoryPressureLevel) {
        switch level {
        case .critical:
            state.withLock {
                $0.suspendedForPressure = true
                $0.idleTask?.cancel()
                $0.idleTask = nil
                $0.generation += 1
            }
            Task { await self.unload(.memoryPressure) }
        case .normal:
            state.withLock { $0.suspendedForPressure = false }
        case .warning:
            break
        }
    }

    /// Unloads now (settings switch, delete, memory pressure, idle).
    public func unload(_ reason: UnloadReason) async {
        state.withLock {
            switch reason {
            case .idle: $0.stats.idleUnloads += 1
            case .memoryPressure: $0.stats.pressureUnloads += 1
            case .manual: $0.stats.manualUnloads += 1
            }
        }
        await unloadAction()
        onUnload(reason)
    }

    private func scheduleIdleUnload() {
        guard let idleSeconds else { return }
        state.withLock { state in
            state.generation += 1
            let generation = state.generation
            state.idleTask?.cancel()
            state.idleTask = Task { [clock] in
                do { try await clock.sleep(for: idleSeconds) } catch { return }
                guard !Task.isCancelled else { return }
                let stillIdle = self.state.withLock { $0.generation == generation && $0.inFlight == 0 }
                if stillIdle { await self.unload(.idle) }
            }
        }
    }
}

/// Wraps a local model with its residency policy: every call and prewarm is seen by
/// `LocalModelResidency`. Under critical memory pressure calls throw `.busy` at once (the same
/// class of failure as Apple FM refusing to run under memory pressure) and prewarms do nothing,
/// so the model is not reloaded until pressure is normal again.
public struct ManagedLocalModel: LanguageModel {
    public let base: any UnloadableLanguageModel
    public let residency: LocalModelResidency

    public init(base: any UnloadableLanguageModel, residency: LocalModelResidency) {
        self.base = base
        self.residency = residency
    }

    public var identifier: String { base.identifier }

    /// The base model's availability: memory pressure is transient (`busy` per call), not a
    /// reason to call the model unavailable.
    public var availability: LanguageModelAvailability { base.availability }
    public var contextTokens: Int { base.contextTokens }

    public func supportsLanguage(_ languageCode: String) -> Bool { base.supportsLanguage(languageCode) }

    public func prewarm(instructions: String) {
        guard isAvailable, !residency.isSuspended else { return }
        base.prewarm(instructions: instructions)
        residency.touched()
    }

    public func prefixCache(instructions: String) async {
        guard isAvailable, !residency.isSuspended else { return }
        residency.callStarted()
        defer { residency.callEnded() }
        await base.prefixCache(instructions: instructions)
    }

    public func warmForDictation(instructions: String) async {
        guard isAvailable, !residency.isSuspended else { return }
        residency.callStarted()
        defer { residency.callEnded() }
        await base.warmForDictation(instructions: instructions)
    }

    public func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        if residency.isSuspended { throw LanguageModelError.busy("local model unloaded under critical memory pressure") }
        if case .unavailable(let reason) = availability { throw LanguageModelError.unavailable(reason) }
        residency.callStarted()
        defer { residency.callEnded() }
        return try await base.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
    }
}

/// The system's memory-pressure notifications (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`).
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure

    public init(queue: DispatchQueue = .global(qos: .utility), handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [source] in
            let event = source.data
            if event.contains(.critical) {
                handler(.critical)
            } else if event.contains(.warning) {
                handler(.warning)
            } else if event.contains(.normal) {
                handler(.normal)
            }
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }
}
