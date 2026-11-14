import Foundation
import Testing
@testable import MurmurCore

@Suite("Fallback model loader", .timeLimit(.minutes(1)))
struct FallbackModelLoaderTests {
    @Test("warm-up requires the guard, a ready primary, and memory above the small tier")
    func eligibility() {
        #expect(!FallbackWarmupPolicy.shouldWarm(guardEnabled: false, primaryReady: true, physicalMemoryGB: 16))
        #expect(!FallbackWarmupPolicy.shouldWarm(guardEnabled: true, primaryReady: false, physicalMemoryGB: 16))
        #expect(!FallbackWarmupPolicy.shouldWarm(guardEnabled: true, primaryReady: true, physicalMemoryGB: 8))
        #expect(FallbackWarmupPolicy.shouldWarm(guardEnabled: true, primaryReady: true, physicalMemoryGB: 16))
    }

    @Test("background and demanding callers share one load")
    func singleFlight() async throws {
        let fake = FakeFallback()
        let loader = FallbackModelLoader(load: { try await fake.load() })
        await loader.warm()
        await fake.waitUntilStarted()
        await loader.warm()
        let requested = Task { try await loader.get() }
        await fake.release()
        #expect(try await requested.value == 1)
        #expect(try await loader.get() == 1)
        #expect(await fake.loads == 1)
    }

    @Test("dictation starts without waiting for the background load")
    func workDoesNotWait() async {
        let fake = FakeFallback()
        let loader = FallbackModelLoader(load: { try await fake.load() })
        await loader.warm()
        await fake.waitUntilStarted()
        let start = ContinuousClock.now
        await loader.workStarted()
        #expect(ContinuousClock.now - start < .seconds(1))
        await fake.release()
        await loader.workFinished()
    }

    @Test("warm-up waits until an active dictation finishes")
    func warmupWaitsForIdle() async throws {
        let fake = FakeFallback()
        let loader = FallbackModelLoader(load: { try await fake.load() })
        await loader.workStarted()
        await loader.warm()
        #expect(await fake.loads == 0)
        await loader.workFinished()
        await fake.waitUntilStarted()
        await fake.release()
        #expect(try await loader.get() == 1)
    }

    // MARK: Dictations leave the load alone

    @Test("back-to-back dictations right after launch neither cancel nor restart the load")
    func dictationsDoNotRestartTheLoad() async throws {
        let fake = FakeFallback()
        let loader = FallbackModelLoader(load: { try await fake.load() })
        await loader.warm()
        await fake.waitUntilStarted()
        for _ in 0..<5 {
            await loader.workStarted()
            await loader.workFinished()
        }
        // Two at once, as when a dictation overlaps a note chunk.
        await loader.workStarted()
        await loader.workStarted()
        await loader.workFinished()
        await loader.workFinished()
        await fake.release()
        #expect(try await loader.get() == 1, "the load that started at launch is the one that finishes")
        #expect(await fake.loads == 1)
        #expect(await !fake.sawCancel, "no dictation cancelled it")
    }

    @Test("a dictation that needs the fallback while it warms waits for that same load")
    func neededDuringWarmup() async throws {
        let fake = FakeFallback()
        let loader = FallbackModelLoader(load: { try await fake.load() })
        await loader.warm()
        await fake.waitUntilStarted()
        await loader.workStarted()
        let requested = Task { try await loader.get() }
        await fake.release()
        #expect(try await requested.value == 1)
        #expect(await fake.loads == 1)
        await loader.workFinished()
    }

    // MARK: A cancel (the guard turned off)

    @Test("a load that has finished its slow step is kept when a cancel arrives")
    func finishedLoadSurvivesCancel() async throws {
        let fake = FakeFallback(stopsWhenCancelled: false)
        let loader = FallbackModelLoader(load: { try await fake.load() })
        await loader.warm()
        await fake.waitUntilStarted()
        await loader.stopWarmup()
        await fake.release()
        #expect(try await loader.get() == 1, "the cancelled load's model is the one handed out")
        #expect(await fake.sawCancel)
        #expect(await fake.loads == 1, "nothing was loaded twice")
        #expect(await loader.loaded == 1)
    }

    @Test("a load cancelled inside its slow step is loaded again when a dictation needs it")
    func cancelledLoadRetries() async throws {
        let fake = FakeFallback()
        let loader = FallbackModelLoader(load: { try await fake.load() })
        await loader.warm()
        await fake.waitUntilStarted()
        await loader.stopWarmup()
        let requested = Task { try await loader.get() }
        await fake.release()
        #expect(try await requested.value == 2)
        #expect(await fake.loads == 2)
    }

    @Test("the guard turned off and on again while loading: the warm-up starts again")
    func guardToggledWhileLoading() async throws {
        let fake = FakeFallback()
        let loader = FallbackModelLoader(load: { try await fake.load() })
        await loader.warm()
        await fake.waitUntilStarted()
        await loader.stopWarmup()
        await loader.warm()
        await fake.release()
        #expect(try await loader.get() == 2)
        #expect(await fake.loads == 2)
    }

    // MARK: How long a flagged dictation waits

    @Test("a load that has just begun could be the quick kind: the dictation waits out the rest of a quick load's time")
    func waitCountsFromTheLoadsStart() {
        #expect(FallbackWaitPolicy.bound(loadRunningFor: nil) == .seconds(4), "nothing loading: the load starts now")
        #expect(FallbackWaitPolicy.bound(loadRunningFor: .zero) == .seconds(4))
        #expect(FallbackWaitPolicy.bound(loadRunningFor: .milliseconds(500)) == .milliseconds(3_500))
    }

    @Test("a load that has outrun a quick one is the long kind: one second, never the rest of its compile")
    func longLoadGetsOnlyTheFloor() {
        #expect(FallbackWaitPolicy.bound(loadRunningFor: .milliseconds(3_500)) == .seconds(1))
        #expect(FallbackWaitPolicy.bound(loadRunningFor: .seconds(4)) == .seconds(1), "the founder's 26 s wait began here")
        #expect(FallbackWaitPolicy.bound(loadRunningFor: .seconds(20)) == .seconds(1))
    }

    @Test("the loader says how long its load has been running, and nothing once it has a model")
    func loadAgeIsReadFromTheLoader() async throws {
        let fake = FakeFallback()
        let time = HandTime()
        let loader = FallbackModelLoader(load: { try await fake.load() }, now: { time.now })
        #expect(await loader.loadRunningFor == nil, "no load yet")
        await loader.warm()
        await fake.waitUntilStarted()
        time.advance(.milliseconds(2_500))
        #expect(await loader.loadRunningFor == .milliseconds(2_500))
        #expect(FallbackWaitPolicy.bound(loadRunningFor: await loader.loadRunningFor) == .milliseconds(1_500))
        await fake.release()
        #expect(try await loader.get() == 1)
        #expect(await loader.loadRunningFor == nil, "loaded: there is nothing to wait for")
    }

    @Test("a load a dictation starts itself (a small-memory Mac) is timed from that moment")
    func onDemandLoadIsTimedToo() async throws {
        let fake = FakeFallback()
        let time = HandTime()
        let clock = HandClock()
        let loader = FallbackModelLoader(load: { try await fake.load() }, sleep: { await clock.sleep($0) }, now: { time.now })
        let first = Task { try await loader.get(waitingUpTo: FallbackWaitPolicy.bound(loadRunningFor: nil)) }
        await clock.waitForSleeper()
        await fake.waitUntilStarted()
        time.advance(.seconds(6))
        await clock.fire()
        #expect(try await first.value == nil)
        #expect(await loader.loadRunningFor == .seconds(6))
        await fake.release()
        #expect(try await loader.get() == 1)
    }

    // MARK: The bounded wait

    @Test("a slow load: the wait ends on the bound with nothing, and the load carries on for the next dictation")
    func boundedWaitGivesUp() async throws {
        let fake = FakeFallback()
        let clock = HandClock()
        let loader = FallbackModelLoader.fake(fake, clock: clock)
        await loader.warm()
        await fake.waitUntilStarted()

        let first = Task { try await loader.get(waitingUpTo: .seconds(2)) }
        await clock.waitForSleeper()
        await clock.fire()
        #expect(try await first.value == nil, "not ready inside the bound")
        #expect(await clock.requested == [.seconds(2)], "the wait is the bound it was given")
        #expect(await !fake.sawCancel)

        await fake.release()
        #expect(try await loader.get(waitingUpTo: .seconds(2)) == 1, "the same load, finished, serves the next dictation")
        #expect(await fake.loads == 1)
        #expect(await !fake.sawCancel, "leaving on the bound did not cancel the load")
        await clock.fire()
    }

    @Test("a loaded model answers at once: the clock is never asked")
    func boundedWaitWhenReady() async throws {
        let fake = FakeFallback()
        let clock = HandClock()
        let loader = FallbackModelLoader.fake(fake, clock: clock)
        await fake.release()
        #expect(try await loader.get() == 1)
        #expect(try await loader.get(waitingUpTo: .seconds(2)) == 1)
        #expect(try await loader.get(waitingUpTo: .zero) == 1)
        #expect(await clock.requested.isEmpty)
    }

    @Test("nothing warming (a small-memory Mac): the first need starts the load and does not wait past the bound")
    func boundedWaitStartsTheLoad() async throws {
        let fake = FakeFallback()
        let clock = HandClock()
        let loader = FallbackModelLoader.fake(fake, clock: clock)
        let first = Task { try await loader.get(waitingUpTo: .seconds(2)) }
        await clock.waitForSleeper()
        await fake.waitUntilStarted()
        await clock.fire()
        #expect(try await first.value == nil)
        // Turning the guard off must not cancel a load a dictation asked for.
        await loader.stopWarmup()
        await fake.release()
        #expect(try await loader.get() == 1)
        #expect(await fake.loads == 1)
        #expect(await !fake.sawCancel)
    }

    @Test("a load that fails inside the bound is reported, not swallowed")
    func boundedWaitReportsFailure() async {
        let fake = FakeFallback(failure: CocoaError(.fileNoSuchFile))
        let clock = HandClock()
        let loader = FallbackModelLoader.fake(fake, clock: clock)
        await fake.release()
        await #expect(throws: CocoaError.self) { _ = try await loader.get(waitingUpTo: .seconds(2)) }
        await clock.fire()
    }

    // MARK: The order of a load

    @Test("a cancel after the slow step: the load still finishes and returns its model")
    func stepsFinishAfterLateCancel() async throws {
        let gate = FakeFallback(stopsWhenCancelled: false)
        let load = Task {
            try await FallbackLoadSteps.run(slow: { try await gate.load() }, finish: { parts in parts + 100 })
        }
        await gate.waitUntilStarted()
        load.cancel()
        await gate.release()
        #expect(try await load.value == 101)
        #expect(await gate.sawCancel)
    }

    @Test("cancelled before it starts: the slow step is never run")
    func stepsStopBeforeTheSlowStep() async {
        let gate = FakeFallback()
        await gate.release()
        let hold = FakeFallback()
        let load = Task {
            _ = try? await hold.load()
            return try await FallbackLoadSteps.run(slow: { try await gate.load() }, finish: { parts in parts + 100 })
        }
        await hold.waitUntilStarted()
        load.cancel()
        await hold.release()
        await #expect(throws: CancellationError.self) { _ = try await load.value }
        #expect(await gate.loads == 0)
    }
}
