import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// A scriptable local model: answers, fails or blocks; counts calls and unloads.
final class FakeLocalModel: UnloadableLanguageModel {
    enum Behavior: Sendable { case answer(String), fail, slow(Duration) }

    private let state: Mutex<(behavior: Behavior, calls: Int, prewarms: Int, unloads: Int, available: Bool)>
    let identifier: String

    init(_ behavior: Behavior = .answer(#"{"text":"local"}"#), identifier: String = "fake-local") {
        state = Mutex((behavior, 0, 0, 0, true))
        self.identifier = identifier
    }

    var calls: Int { state.withLock { $0.calls } }
    var prewarms: Int { state.withLock { $0.prewarms } }
    var unloads: Int { state.withLock { $0.unloads } }
    func setBehavior(_ behavior: Behavior) { state.withLock { $0.behavior = behavior } }
    func setAvailable(_ available: Bool) { state.withLock { $0.available = available } }

    var availability: LanguageModelAvailability {
        state.withLock { $0.available } ? .available : .unavailable(reason: "off")
    }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) { state.withLock { $0.prewarms += 1 } }
    func prefixCache(instructions: String) async {}
    func unload() async { state.withLock { $0.unloads += 1 } }

    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        let behavior = state.withLock { state -> Behavior in
            state.calls += 1
            return state.behavior
        }
        switch behavior {
        case .answer(let json): return json
        case .fail: throw LanguageModelError.unavailable("boom")
        case .slow(let duration):
            try await Task.sleep(for: duration)
            return #"{"text":"slow"}"#
        }
    }
}

/// Records the options each call arrived with.
final class OptionsSpy: UnloadableLanguageModel, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [LanguageModelOptions] = []
    private var prefixed: [String] = []
    private var prewarmed: [String] = []
    var options: [LanguageModelOptions] { lock.withLock { received } }
    var prefixCacheInstructions: [String] { lock.withLock { prefixed } }
    var prewarmInstructions: [String] { lock.withLock { prewarmed } }
    var identifier: String { "spy" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) { lock.withLock { prewarmed.append(instructions) } }
    func prefixCache(instructions: String) async { lock.withLock { prefixed.append(instructions) } }
    func unload() async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        lock.withLock { received.append(options) }
        return #"{"text":"ok"}"#
    }
}

/// A clock whose sleeps end only when the test says so.
final class ManualClock: DownloadClock, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func now() -> Date { Date() }

    func sleep(for seconds: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { waiters.append(continuation) }
            }
        } onCancel: {
            // Cancelled sleepers are released by `fire` with an error.
        }
    }

    var pending: Int { lock.withLock { waiters.count } }

    /// Ends every pending sleep.
    func fire() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            defer { waiters.removeAll() }
            return waiters
        }
        all.forEach { $0.resume() }
    }
}

private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

/// Polls (up to 5 s) for work a detached task does — deterministic under a loaded test run.
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

private func ask(_ model: any LanguageModel) async throws -> String {
    try await model.respond(instructions: "i", prompt: "p", schema: SmartCleaner.cleanedSchema, options: .greedy)
}

@Suite("Local model residency (M6)")
struct LocalModelResidencyTests {
    @Test("critical memory pressure unloads at once; calls fail fast as busy (not slow) until pressure is normal")
    func criticalPressure() async throws {
        let local = FakeLocalModel()
        let residency = LocalModelResidency(idleSeconds: nil, unload: { await local.unload() })
        let managed = ManagedLocalModel(base: local, residency: residency)
        #expect(try await ask(managed) == #"{"text":"local"}"#)

        residency.memoryPressure(.critical)
        await settle()
        #expect(local.unloads == 1)
        #expect(residency.stats.pressureUnloads == 1)
        #expect(residency.isSuspended)
        #expect(managed.isAvailable, "memory pressure is transient: busy per call, not unavailable")
        do {
            _ = try await ask(managed)
            Issue.record("a suspended model must not answer")
        } catch let error as LanguageModelError {
            guard case .busy = error else { Issue.record("expected busy, got \(error)"); return }
            #expect(ModelCallFailure(error) == .busy)
        }
        managed.prewarm(instructions: "i")
        #expect(local.calls == 1, "a suspended model is never called")
        #expect(local.prewarms == 0, "nor reloaded by a prewarm")

        // The chain in front of it goes on to Apple FM.
        let chain = FallbackLanguageModel(primary: managed, secondary: FakeLocalModel(.answer(#"{"text":"apple"}"#)))
        #expect(try await ask(chain) == #"{"text":"apple"}"#)

        residency.memoryPressure(.warning)
        #expect(residency.isSuspended)
        residency.memoryPressure(.normal)
        #expect(!residency.isSuspended)
        #expect(try await ask(chain) == #"{"text":"local"}"#)
    }

    @Test("busy with nothing to fall back to reaches the cleaner as model-busy, and ModelHealth ignores it")
    func busyWithoutFallback() async {
        let local = FakeLocalModel()
        let residency = LocalModelResidency(idleSeconds: nil, unload: { await local.unload() })
        residency.memoryPressure(.critical)
        let chain = FallbackLanguageModel(primary: ManagedLocalModel(base: local, residency: residency), secondary: NullLanguageModel())
        let health = ModelHealth()
        let output = await SmartCleaner(cleanGate: .always, model: chain, health: health)
            .clean("um so ship it friday", options: CleanupOptions(level: .polished))
        #expect(!output.usedModel)
        #expect(output.rejection == "model busy")
        #expect(health.verdict(budget: .milliseconds(2_400)) == .call, "busy is not slow")
    }

    @Test("on ≤ 8 GB the model unloads after the idle interval, and a call in between restarts the clock")
    func idleUnload() async throws {
        let local = FakeLocalModel()
        let clock = ManualClock()
        let residency = LocalModelResidency(idleSeconds: 120, clock: clock, unload: { await local.unload() })
        let managed = ManagedLocalModel(base: local, residency: residency)

        _ = try await ask(managed)
        await settle()
        #expect(clock.pending == 1)
        // Another call before the timer fires: the old timer is stale.
        _ = try await ask(managed)
        await settle()
        clock.fire()
        await settle()
        #expect(local.unloads == 1, "only the newest idle timer unloads")
        #expect(residency.stats.idleUnloads == 1)
        // It reloads on demand: the next call just works.
        #expect(try await ask(managed) == #"{"text":"local"}"#)
    }

    @Test("prewarm touches the idle clock; no idle unload without an idle interval")
    func prewarmAndSessionLong() async {
        let local = FakeLocalModel()
        let clock = ManualClock()
        let small = ManagedLocalModel(base: local, residency: LocalModelResidency(idleSeconds: 120, clock: clock, unload: { await local.unload() }))
        small.prewarm(instructions: "i")
        await settle()
        #expect(local.prewarms == 1)
        #expect(clock.pending == 1)

        let bigClock = ManualClock()
        let big = ManagedLocalModel(base: local, residency: LocalModelResidency(idleSeconds: nil, clock: bigClock, unload: { await local.unload() }))
        big.prewarm(instructions: "i")
        _ = try? await ask(big)
        await settle()
        #expect(bigClock.pending == 0, "≥ 16 GB keeps the model for the session")
    }

    @Test("no idle unload while a call is running")
    func noUnloadMidCall() async throws {
        let local = FakeLocalModel(.slow(.milliseconds(150)))
        let clock = ManualClock()
        let residency = LocalModelResidency(idleSeconds: 120, clock: clock, unload: { await local.unload() })
        let managed = ManagedLocalModel(base: local, residency: residency)
        residency.touched()
        await settle()
        async let answer = ask(managed)
        await settle()
        clock.fire()  // the prewarm-era timer fires mid-call
        await settle()
        #expect(local.unloads == 0)
        _ = try await answer
    }
}

@Suite("Cleanup backend switching")
struct CleanupBackendTests {
    @Test("choice × install → effective backend")
    func resolve() {
        let id = ModelRegistry.qwen2B6bit
        #expect(EffectiveCleanupBackend.resolve(choice: .apple, install: .ready, entryID: id) == .apple)
        #expect(EffectiveCleanupBackend.resolve(choice: .rules, install: .ready, entryID: id) == .rules)
        #expect(EffectiveCleanupBackend.resolve(choice: .local, install: .ready, entryID: id) == .local(id))
        // No local model ready: simple fixes, never Apple Intelligence (TRY-88).
        #expect(EffectiveCleanupBackend.resolve(choice: .local, install: .notInstalled, entryID: id) == .rules)
        #expect(EffectiveCleanupBackend.resolve(
            choice: .local, install: .downloading(received: 1, total: 2, secondsRemaining: nil), entryID: id) == .rules)
        #expect(EffectiveCleanupBackend.resolve(
            choice: .local, install: .paused(received: 1, total: 2, reason: .offline), entryID: id) == .rules)
        #expect(EffectiveCleanupBackend.resolve(choice: .local, install: .failed("x"), entryID: id) == .rules)
        // A Mac without the local runtime keeps Apple Intelligence.
        #expect(EffectiveCleanupBackend.resolve(choice: .local, install: .notInstalled, entryID: id, localAvailable: false) == .apple)
        #expect(EffectiveCleanupBackend.resolve(choice: .local, install: .ready, entryID: id, localAvailable: false) == .apple)
    }

    @Test("a switchable model swaps backends in place; a cleaner holding it follows")
    func switchable() async throws {
        let switchable = SwitchableLanguageModel(FakeLocalModel(.answer(#"{"text":"apple"}"#), identifier: "apple"))
        #expect(try await ask(switchable) == #"{"text":"apple"}"#)
        switchable.replace(with: FakeLocalModel(.answer(#"{"text":"local"}"#), identifier: "local"))
        #expect(switchable.identifier == "local")
        #expect(try await ask(switchable) == #"{"text":"local"}"#)
        switchable.replace(with: NullLanguageModel())
        #expect(!switchable.isAvailable)
        let output = await SmartCleaner(model: switchable).clean("um so ship it friday", options: CleanupOptions(level: .polished))
        #expect(!output.usedModel, "rules only")
    }

    @Test("text-transform options pass through every wrapper unchanged")
    func optionsPassThrough() async throws {
        let seen = OptionsSpy()
        let residency = LocalModelResidency(idleSeconds: nil, unload: {})
        let chain = SwitchableLanguageModel(FallbackLanguageModel(
            primary: RecordingLanguageModel(ManagedLocalModel(base: seen, residency: residency), label: "local", log: ModelCallLog()),
            secondary: NullLanguageModel()))
        _ = try await chain.respond(instructions: "i", prompt: "p", schema: SmartCleaner.cleanedSchema, options: .greedyTextTransform)
        #expect(seen.options == [.greedyTextTransform])
    }

    @Test("launch prewarm builds every prompt prefix the level needs; key-down prewarm builds none extra")
    func prewarmPrefixes() async {
        for (level, expected) in [(CleanupLevel?.none, 0), (.clean, 1), (.polished, 2), (.verbatim, 0)] {
            let spy = OptionsSpy()
            SmartCleaner(model: spy, health: ModelHealth()).prewarm(prefixesFor: level)
            await waitUntil { spy.prefixCacheInstructions.count >= expected }
            await settle()
            #expect(spy.prewarmInstructions == [SmartCleaner.cleanupInstructions(confidenceGuided: false)])
            #expect(spy.prefixCacheInstructions.count == expected, "\(String(describing: level))")
        }
        let spy = OptionsSpy()
        SmartCleaner(model: spy, health: ModelHealth()).prewarm(prefixesFor: .polished)
        await waitUntil { spy.prefixCacheInstructions.count >= 2 }
        #expect(Set(spy.prefixCacheInstructions) == [
            SmartCleaner.cleanupInstructions(confidenceGuided: true, grammarRepair: true),
            SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: true),
        ])
    }

    @Test("a model trained on register lines gets each register's prefix built at launch; any other model gets none")
    func prewarmRegisterPrefixes() async {
        let spy = OptionsSpy()
        SmartCleaner(model: spy, health: ModelHealth(), wholeTranscript: { true }, registerLines: { true })
            .prewarm(prefixesFor: .polished)
        await waitUntil { spy.prefixCacheInstructions.count >= 5 }
        let registered = spy.prefixCacheInstructions.compactMap(IntentRegister.detecting(in:))
        #expect(Set(registered) == Set(IntentRegister.allCases))
        // The exact instructions a register dictation sends (`SmartCleaner.ask`), so the prefix is the one it looks up.
        #expect(spy.prefixCacheInstructions.contains(
            SmartCleaner.cleanupInstructions(confidenceGuided: false) + "\n" + IntentRegister.prompt.line))

        for (whole, lines) in [(false, true), (true, false)] {
            let other = OptionsSpy()
            SmartCleaner(model: other, health: ModelHealth(), wholeTranscript: { whole }, registerLines: { lines })
                .prewarm(prefixesFor: .polished)
            await waitUntil { other.prefixCacheInstructions.count >= 2 }
            await settle()
            #expect(other.prefixCacheInstructions.compactMap(IntentRegister.detecting(in:)).isEmpty)
        }
    }

    @Test("the call log keeps backend, outcome and latency — never text")
    func callLog() async throws {
        let log = ModelCallLog(capacity: 3)
        let recorded = RecordingLanguageModel(FakeLocalModel(), label: "local", log: log)
        for _ in 0..<4 { _ = try await ask(recorded) }
        let failing = RecordingLanguageModel(FakeLocalModel(.fail), label: "apple", log: log)
        _ = try? await ask(failing)
        #expect(log.recent.count == 3)
        #expect(log.recent.last?.backend == "apple")
        #expect(log.recent.last?.outcome == .failed)
        let mirror = String(describing: log.recent)
        #expect(!mirror.contains("local\"}"), "answers are never stored")
    }
}

@Suite("Fallback chain with ModelHealth")
struct FallbackChainHealthTests {
    @Test("MLX → Apple → rules: a failing local model falls to Apple inside the same budget")
    func localFailsAppleAnswers() async {
        let local = FakeLocalModel(.fail)
        let apple = FakeLocalModel(.answer(#"{"text":"So ship it Friday."}"#))
        let chain = FallbackLanguageModel(primary: local, secondary: apple)
        let cleaner = SmartCleaner(cleanGate: .always, model: chain, health: ModelHealth())
        _ = await cleaner.clean("um so ship it friday", options: CleanupOptions(level: .polished))
        #expect(local.calls >= 1)
        #expect(apple.calls >= 1, "the local failure fell through to Apple FM")
    }

    @Test("both legs down → the rules path, without a timeout")
    func bothDown() async {
        let local = FakeLocalModel(.fail)
        local.setAvailable(false)
        let chain = FallbackLanguageModel(primary: local, secondary: NullLanguageModel())
        let start = ContinuousClock.now
        let output = await SmartCleaner(cleanGate: .always, model: chain, health: ModelHealth())
            .clean("um so ship it friday", options: CleanupOptions(level: .polished))
        #expect(!output.usedModel)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test("timeouts through the chain close the health gate; a backend switch resets it")
    func gateAcrossChain() async {
        let health = ModelHealth(probeIntervalSeconds: 3_600)
        let slow = FakeLocalModel(.slow(.seconds(5)))
        let chain = FallbackLanguageModel(primary: slow, secondary: NullLanguageModel())
        let cleaner = SmartCleaner(
            budget: .milliseconds(80), correctionBudget: .milliseconds(80), polishedBudget: .milliseconds(80),
            segmentBudget: .milliseconds(80), cleanGate: .always, model: chain, health: health)
        let options = CleanupOptions(level: .polished)
        for _ in 0..<2 { _ = await cleaner.clean("um so ship it friday", options: options) }
        #expect(health.verdict(budget: .milliseconds(80)) != .call, "a model that keeps missing its budget is skipped")
        let skipped = await cleaner.clean("um so ship it friday", options: options)
        #expect(!skipped.usedModel)
        // Switching backends (CleanupModelController.apply) resets the gate for the new backend.
        health.reset()
        #expect(health.verdict(budget: .milliseconds(80)) == .call)
    }
}
