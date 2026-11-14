import Darwin
import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// When the predictive warm may touch the model's pages, and what it does with them.
@Suite("Model warmth keeper")
struct ModelWarmthKeeperTests {
    typealias Mapping = PageResidencyTests.Mapping

    struct FakeMemory: ResidentModelMemory {
        let mapping: Mapping?
        func memoryRegions() async -> ModelMemoryRegions? { mapping?.regions() }
    }

    final class Clock: Sendable {
        private let instant = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { instant.withLock { $0 } }
        func advance(_ by: Duration) { instant.withLock { $0 += by } }
    }

    final class Counter: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    private let policy = WarmPolicy()

    @Test("Low Power Mode, a hot Mac and memory pressure skip every signal")
    func hardGates() {
        for signal in WarmSignal.allCases {
            #expect(policy.decide(signal, .init(lowPowerMode: true), sinceLast: nil) == .skip("low-power"))
            #expect(policy.decide(signal, .init(thermal: .serious), sinceLast: nil) == .skip("thermal"))
            #expect(policy.decide(signal, .init(thermal: .critical), sinceLast: nil) == .skip("thermal"))
            #expect(policy.decide(signal, .init(memoryPressure: .warning), sinceLast: nil) == .skip("memory-pressure"))
        }
        #expect(policy.decide(.backFromIdle, .init(thermal: .fair), sinceLast: nil) == .restore)
    }

    @Test("on battery only the signals that mean the person came back may restore")
    func battery() {
        let battery = WarmConditions(onBattery: true)
        #expect(policy.decide(.activeTick, battery, sinceLast: nil) == .skip("battery"))
        #expect(policy.decide(.appActivated, battery, sinceLast: nil) == .skip("battery"))
        for signal in [WarmSignal.wake, .screenUnlock, .sessionActive, .backFromIdle] {
            #expect(policy.decide(signal, battery, sinceLast: nil) == .restore)
        }
    }

    @Test("a busy Mac only refreshes what is already in RAM")
    func busy() {
        #expect(policy.decide(.backFromIdle, .init(busyCPU: true), sinceLast: nil) == .refresh)
        #expect(policy.decide(.activeTick, .init(busyCPU: true), sinceLast: nil) == .refresh)
    }

    @Test("signals closer than the gap are dropped, except the active tick")
    func gap() {
        #expect(policy.decide(.appActivated, .init(), sinceLast: .seconds(5)) == .skip("recent"))
        #expect(policy.decide(.appActivated, .init(), sinceLast: .seconds(25)) == .restore)
        #expect(policy.decide(.activeTick, .init(), sinceLast: .seconds(1)) == .restore)
    }

    @Test("a restore pages the whole model back in")
    func restores() async {
        let mapping = Mapping(pages: 128)
        mapping.write(pages: 0..<32)
        let keeper = ModelWarmthKeeper(memory: { FakeMemory(mapping: mapping) }, conditions: { .init() })
        let outcome = await keeper.handle(.backFromIdle)
        guard case .touched(let before, let after, let pages, let threads, _, let refresh) = outcome else {
            Issue.record("expected a touch, got \(outcome)")
            return
        }
        #expect(abs(before - 0.25) < 0.001)
        #expect(after == 1)
        #expect(pages == 128)
        #expect(threads >= 1 && threads <= WarmPolicy.restoreThreads)
        #expect(!refresh)
    }

    @Test("a resident model is refreshed on one thread")
    func residentRefresh() async {
        let mapping = Mapping(pages: 64)
        mapping.write(pages: 0..<64)
        let keeper = ModelWarmthKeeper(memory: { FakeMemory(mapping: mapping) }, conditions: { .init() })
        let outcome = await keeper.handle(.activeTick)
        #expect(outcome == .touched(before: 1, after: 1, pages: 64, threads: 1, milliseconds: outcomeMilliseconds(outcome), refresh: true))
    }

    @Test("busy: missing pages stay out")
    func busyLeavesPagesOut() async {
        let mapping = Mapping(pages: 64)
        mapping.write(pages: 0..<16)
        let keeper = ModelWarmthKeeper(memory: { FakeMemory(mapping: mapping) }, conditions: { .init(busyCPU: true) })
        guard case .touched(_, let after, let pages, _, _, let refresh) = await keeper.handle(.backFromIdle) else {
            Issue.record("expected a refresh")
            return
        }
        #expect(refresh)
        #expect(pages == 16)
        #expect(abs(after - 0.25) < 0.001)
        #expect(PageResidency.sample(mapping.regions()).resident == 16)
    }

    @Test("a second signal inside the gap is dropped; after it, it runs")
    func throttle() async {
        let mapping = Mapping(pages: 8)
        mapping.write(pages: 0..<8)
        let clock = Clock()
        let keeper = ModelWarmthKeeper(
            memory: { FakeMemory(mapping: mapping) }, conditions: { .init() }, now: { clock.now })
        #expect(await keeper.handle(.screenUnlock) != .skipped("recent"))
        clock.advance(.seconds(3))
        #expect(await keeper.handle(.appActivated) == .skipped("recent"))
        clock.advance(.seconds(30))
        #expect(await keeper.handle(.appActivated) != .skipped("recent"))
    }

    @Test("no model in memory: strong signals load it, the others do not")
    func notLoaded() async {
        let loads = Counter()
        let keeper = ModelWarmthKeeper(
            policy: WarmPolicy(minimumGap: .zero), memory: { FakeMemory(mapping: nil) }, conditions: { .init() },
            load: { loads.add() })
        #expect(await keeper.handle(.appActivated) == .notLoaded(loading: false))
        #expect(await keeper.handle(.wake) == .notLoaded(loading: false))
        #expect(await keeper.handle(.backFromIdle) == .notLoaded(loading: true))
        #expect(await keeper.handle(.screenUnlock) == .notLoaded(loading: true))
        #expect(loads.value == 2)
    }

    @Test("a busy Mac never loads the model")
    func busyNeverLoads() async {
        let loads = Counter()
        let keeper = ModelWarmthKeeper(
            memory: { nil }, conditions: { .init(busyCPU: true) }, load: { loads.add() })
        #expect(await keeper.handle(.backFromIdle) == .notLoaded(loading: false))
        #expect(loads.value == 0)
    }

    private func outcomeMilliseconds(_ outcome: ModelWarmthKeeper.Outcome) -> Double {
        if case .touched(_, _, _, _, let ms, _) = outcome { return ms }
        return -1
    }
}

@Suite("Activity tracker")
struct ActivityTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("input within the active window ticks; a quiet minute does not")
    func ticks() {
        var tracker = ActivityTracker(idleThreshold: 180, activeWindow: 60)
        #expect(tracker.tick(idleSeconds: 5, now: start) == .activeTick)
        #expect(tracker.tick(idleSeconds: 90, now: start) == nil)
        #expect(!tracker.isIdle)
    }

    @Test("idle past the threshold, then the first input says how long it was")
    func idleAndBack() {
        var tracker = ActivityTracker(idleThreshold: 180, activeWindow: 60)
        #expect(tracker.tick(idleSeconds: 200, now: start) == .wentIdle)
        #expect(tracker.isIdle)
        #expect(tracker.tick(idleSeconds: 900, now: start) == nil)
        #expect(tracker.input(now: start.addingTimeInterval(600)) == .back(idleSeconds: 800))
        #expect(!tracker.isIdle)
        #expect(tracker.input(now: start) == nil)
    }
}
