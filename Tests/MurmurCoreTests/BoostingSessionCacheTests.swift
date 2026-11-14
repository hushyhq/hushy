import Foundation
import Testing
@testable import MurmurCore

/// Counts loads and lets a test hold a load open until it chooses to release it.
private actor Probe {
    private(set) var modelLoads = 0
    private(set) var builds: [VocabularyContext] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var isOpen: Bool

    init(open: Bool = true) { isOpen = open }

    func loadModels(succeeding: Bool = true) async -> Int? {
        modelLoads += 1
        await waitForGate()
        return succeeding ? modelLoads : nil
    }

    func build(_ models: Int, _ vocabulary: VocabularyContext) async -> String? {
        builds.append(vocabulary)
        await waitForGate()
        return "session-\(builds.count)"
    }

    func hold() { isOpen = false }

    func release() {
        isOpen = true
        gate?.resume()
        gate = nil
    }

    private func waitForGate() async {
        guard !isOpen else { return }
        await withCheckedContinuation { gate = $0 }
    }
}

private func vocabulary(_ words: String...) -> VocabularyContext {
    VocabularyContext(terms: words.map { VocabularyTerm(text: $0) })
}

private func makeCache(_ probe: Probe) -> BoostingSessionCache<Int, String> {
    BoostingSessionCache(
        loadModels: { await probe.loadModels() },
        buildSession: { await probe.build($0, $1) })
}

// A stalled await must fail in a minute, not hold the shared heavy-job lock for a quarter hour.
@Suite("BoostingSessionCache", .timeLimit(.minutes(1)))
struct BoostingSessionCacheTests {
    @Test("a warmed cache answers with no wait and reports warm")
    func warmedCacheIsWarm() async {
        let probe = Probe()
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy"))
        await cache.waitUntilIdle()
        let answer = await cache.session(for: vocabulary("Hushy"), waitingUpTo: .zero)
        #expect(answer.session == "session-1")
        #expect(answer.readiness == .warm)
    }

    @Test("not ready and a zero bound skips immediately; the load carries on and the next call is warm")
    func coldIsSkippedAndLoadContinues() async {
        let probe = Probe(open: false)
        let cache = makeCache(probe)
        let first = await cache.session(for: vocabulary("Hushy"), waitingUpTo: .zero)
        #expect(first.session == nil)
        #expect(first.readiness == .coldSkipped)

        await probe.release()
        await cache.waitUntilIdle()
        let second = await cache.session(for: vocabulary("Hushy"), waitingUpTo: .zero)
        #expect(second.session == "session-1")
        #expect(second.readiness == .warm)
        #expect(await probe.modelLoads == 1)
    }

    @Test("a load that finishes inside the bound is used and reports how long it took")
    func loadFinishingInsideBoundIsUsed() async throws {
        let probe = Probe(open: false)
        let cache = makeCache(probe)
        let release = Task { try await Task.sleep(for: .milliseconds(40)); await probe.release() }
        let answer = await cache.session(for: vocabulary("Hushy"), waitingUpTo: .seconds(600))
        try await release.value
        #expect(answer.session == "session-1")
        guard case .loaded(let ms) = answer.readiness else {
            Issue.record("expected .loaded, got \(answer.readiness)")
            return
        }
        #expect(ms >= 30 && ms < 120_000)
    }

    @Test("a load that outlasts the bound is skipped, not waited for")
    func loadOutlastingBoundIsSkipped() async {
        let probe = Probe(open: false)
        let cache = makeCache(probe)
        let clock = SuspendingClock()
        let started = clock.now
        let answer = await cache.session(for: vocabulary("Hushy"), waitingUpTo: .milliseconds(50))
        let waited = clock.now - started
        #expect(answer.session == nil)
        #expect(answer.readiness == .coldSkipped)
        // The load stays held until the test releases it, so a call that waited for it would never come back;
        // the bound only has to be far from "never". A minute cannot be reached by a busy Mac, and
        // SuspendingClock does not count time the Mac spent asleep.
        #expect(waited < .seconds(60))
        await probe.release()
    }

    @Test("waitUntilIdle gives up at its bound when the load never finishes")
    func waitUntilIdleIsBounded() async {
        let probe = Probe(open: false)
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy"))
        let clock = SuspendingClock()
        let started = clock.now
        await cache.waitUntilIdle(upTo: .milliseconds(50))
        // Held until released, so waiting for it would never return; see `loadOutlastingBoundIsSkipped`.
        #expect(clock.now - started < .seconds(60))
        await probe.release()
    }

    @Test("a caller with a bound is never parked while a model load is held open")
    func heldLoadNeverParksACaller() async {
        let probe = Probe(open: false)
        let cache = makeCache(probe)
        for _ in 0..<3 {
            let clock = SuspendingClock()
            let started = clock.now
            let answer = await cache.session(for: vocabulary("Hushy"), waitingUpTo: .milliseconds(30))
            #expect(answer.readiness == .coldSkipped)
            // Held until released, so a parked caller would never return; see `loadOutlastingBoundIsSkipped`.
            #expect(clock.now - started < .seconds(60))
        }
        #expect(await probe.modelLoads == 1)
        await probe.release()
    }

    @Test("concurrent callers and a warm-up share one model load and one build")
    func concurrentCallersShareOneLoad() async {
        let probe = Probe(open: false)
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy"))
        async let one = cache.session(for: vocabulary("Hushy"), waitingUpTo: .seconds(5))
        async let two = cache.session(for: vocabulary("Hushy"), waitingUpTo: .seconds(5))
        try? await Task.sleep(for: .milliseconds(30))
        await probe.release()
        let (a, b) = await (one, two)
        #expect(a.session == "session-1" && b.session == "session-1")
        #expect(await probe.modelLoads == 1)
        #expect(await probe.builds.count == 1)
    }

    @Test("warming an already-warm vocabulary does no work")
    func warmIsIdempotent() async {
        let probe = Probe()
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy"))
        await cache.waitUntilIdle()
        await cache.warm(vocabulary("Hushy"))
        await cache.waitUntilIdle()
        #expect(await probe.modelLoads == 1)
        #expect(await probe.builds.count == 1)
    }

    @Test("a vocabulary change rebuilds the session but keeps the loaded models")
    func vocabularyChangeRebuildsOnlyTheSession() async {
        let probe = Probe()
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy"))
        await cache.waitUntilIdle()

        await cache.warm(vocabulary("Hushy", "Priya"))
        await cache.waitUntilIdle()
        let answer = await cache.session(for: vocabulary("Hushy", "Priya"), waitingUpTo: .zero)
        #expect(answer.session == "session-2")
        #expect(answer.readiness == .warm)
        #expect(await probe.modelLoads == 1)
        #expect(await probe.builds.count == 2)
    }

    // Key-down warm-up: the build for a dictation's own vocabulary starts while the person speaks.

    @Test("a session warmed at key-down is used at the release when the vocabulary matches")
    func keyDownWarmIsUsed() async {
        let probe = Probe()
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy", "Driftwatch"))
        await cache.waitUntilIdle()
        let release = await cache.session(for: vocabulary("Hushy", "Driftwatch"), waitingUpTo: .zero)
        #expect(release.session == "session-1")
        #expect(release.readiness == .warm)
        #expect(await probe.builds.count == 1)
    }

    @Test("a release before the warm-up has finished joins it and starts no second build")
    func earlyReleaseJoinsTheBuild() async throws {
        let probe = Probe(open: false)
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy", "Driftwatch"))
        let opens = Task { try await Task.sleep(for: .milliseconds(40)); await probe.release() }
        let release = await cache.session(for: vocabulary("Hushy", "Driftwatch"), waitingUpTo: .seconds(600))
        try await opens.value
        #expect(release.session == "session-1")
        #expect(await probe.builds.count == 1)
        #expect(await probe.modelLoads == 1)
    }

    @Test("a release before the warm-up has finished waits no longer than its bound")
    func earlyReleaseKeepsItsBound() async {
        let probe = Probe(open: false)
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy", "Driftwatch"))
        let release = await cache.session(for: vocabulary("Hushy", "Driftwatch"), waitingUpTo: .milliseconds(30))
        #expect(release.session == nil)
        #expect(release.readiness == .coldSkipped)
        await probe.release()
    }

    @Test("a warm-up for other terms is not used at the release, and the release's own vocabulary gets its build")
    func mismatchedWarmIsIgnored() async {
        let probe = Probe()
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy", "Driftwatch"))
        await cache.waitUntilIdle()
        await probe.hold()
        let release = await cache.session(for: vocabulary("Hushy", "Other"), waitingUpTo: .zero)
        #expect(release.session == nil)
        #expect(release.readiness == .coldSkipped)
        await probe.release()
        await cache.waitUntilIdle()
        let later = await cache.session(for: vocabulary("Hushy", "Other"), waitingUpTo: .zero)
        #expect(later.session == "session-2")
        #expect(await probe.builds.last == vocabulary("Hushy", "Other"))
    }

    @Test("after a change, the old session is never handed out for the new vocabulary")
    func staleSessionIsNeverUsed() async {
        let probe = Probe()
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy"))
        await cache.waitUntilIdle()
        await probe.hold()
        let answer = await cache.session(for: vocabulary("Hushy", "Priya"), waitingUpTo: .zero)
        #expect(answer.session == nil)
        #expect(answer.readiness == .coldSkipped)
        await probe.release()
    }

    @Test("a vocabulary changed mid-build: the latest one wins")
    func latestVocabularyWins() async {
        let probe = Probe(open: false)
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy"))
        await cache.warm(vocabulary("Hushy", "Priya"))
        await probe.release()
        await cache.waitUntilIdle()
        let answer = await cache.session(for: vocabulary("Hushy", "Priya"), waitingUpTo: .zero)
        #expect(answer.readiness == .warm)
        let stale = await cache.session(for: vocabulary("Hushy"), waitingUpTo: .zero)
        #expect(stale.session == nil)
    }

    @Test("a failed model load reports unavailable, and the next request tries again")
    func failedLoadRetries() async {
        let probe = Probe()
        let attempts = Counter()
        let cache = BoostingSessionCache<Int, String>(
            loadModels: { await attempts.next() == 1 ? nil : await probe.loadModels() },
            buildSession: { await probe.build($0, $1) })
        let first = await cache.session(for: vocabulary("Hushy"), waitingUpTo: .seconds(5))
        #expect(first.session == nil)
        #expect(first.readiness == .unavailable)

        let second = await cache.session(for: vocabulary("Hushy"), waitingUpTo: .seconds(5))
        #expect(second.session == "session-1")
    }

    @Test("the models are exposed only once their load has finished, and survive a vocabulary change")
    func loadedModelsAppearAfterTheLoad() async {
        let probe = Probe(open: false)
        let cache = makeCache(probe)
        await cache.warm(vocabulary("Hushy"))
        #expect(await cache.loadedModels == nil)
        await probe.release()
        await cache.waitUntilIdle()
        #expect(await cache.loadedModels == 1)
        await cache.warm(vocabulary("Hushy", "Priya"))
        #expect(await cache.loadedModels == 1)
    }

    @Test("log markers are content-free and name the state")
    func logMarkers() {
        #expect(BoostingReadiness.warm.logMarker == "boosting=warm")
        #expect(BoostingReadiness.coldSkipped.logMarker == "boosting=cold-skipped")
        #expect(BoostingReadiness.unavailable.logMarker == "boosting=unavailable")
        #expect(BoostingReadiness.loaded(ms: 812).logMarker == "boosting=loaded-in 812 ms")
    }

    @Test("asking for a ready session never starts a build, and finds only one built for the same terms")
    func readySessionOnlyReportsBuiltSessions() async {
        let probe = Probe()
        let cache = makeCache(probe)
        #expect(await cache.readySession(for: vocabulary("Hushy")) == nil)
        await cache.waitUntilIdle()
        #expect(await probe.builds.isEmpty)
        await cache.warm(vocabulary("Hushy"))
        await cache.waitUntilIdle()
        #expect(await cache.readySession(for: vocabulary("Hushy")) == "session-1")
        #expect(await cache.readySession(for: vocabulary("Hushy", "Quill")) == nil)
        #expect(await probe.builds.count == 1)
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}
