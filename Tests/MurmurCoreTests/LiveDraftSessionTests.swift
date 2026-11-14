import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// The pill's live draft (`LiveDraftSession`): its cadence, its fixed window, and how it yields the recogniser to
/// the passes that matter (`RecogniserLane`). Driven with a scripted recogniser; nothing here touches a model.
@Suite("Live draft: the pill's words while speaking", .timeLimit(.minutes(1)), .serialized)
struct LiveDraftSessionTests {
    private let second = [Float](repeating: 0.01, count: 16_000)

    private func session(_ recogniser: DraftRecogniser, lane: RecogniserLane = RecogniserLane(),
                         drafts: Locked<[String]>) -> LiveDraftSession {
        LiveDraftSession(lane: lane, recognise: { try await recogniser.transcribe($0) },
                         onDraft: { text in drafts.withLock { $0.append(text) } })
    }

    @Test("the schedule starts within the first second and then comes once a second")
    func cadence() {
        var schedule = LiveDraftSchedule()
        #expect(!schedule.isDue(at: 0.5))
        #expect(schedule.isDue(at: 1))
        schedule.started(at: 1)
        #expect(!schedule.isDue(at: 1.5))
        #expect(schedule.isDue(at: 1.95))
        #expect(schedule.isDue(at: 2))
        #expect(schedule.windowSamples(sampleRate: 16_000) == 80_000)
    }

    @Test("one draft a second, each reading at most the last five seconds, however long the dictation")
    func flatWindow() async {
        let recogniser = DraftRecogniser()
        let drafts = Locked<[String]>([])
        let draft = session(recogniser, drafts: drafts)
        for _ in 0..<120 {
            await draft.add(second)
            await draft.settle()
        }
        #expect(recogniser.calls == 120)
        #expect(recogniser.longestInput == 80_000)
        #expect(drafts.withLock { $0.count } == 120)
        let stats = await draft.finish()
        #expect(stats.passes == 120 && stats.skippedBusy == 0)
    }

    @Test("a draft is skipped while an early-cleaning pass or the release pass has the recogniser")
    func yieldsToOtherPasses() async throws {
        let recogniser = DraftRecogniser()
        let lane = RecogniserLane()
        let drafts = Locked<[String]>([])
        let draft = session(recogniser, lane: lane, drafts: drafts)
        let gate = DraftGate()
        let early = Task { try await lane.exclusive { await gate.wait(); return "early" } }
        await gate.waitUntilWaiting()
        await draft.add(second)
        await draft.settle()
        #expect(recogniser.calls == 0)
        #expect(await draft.stats.skippedBusy == 1)
        await gate.open()
        _ = try await early.value
        await draft.add(second)
        await draft.settle()
        #expect(recogniser.calls == 1)
    }

    @Test("the release waits only for a draft already running, and no draft starts after the key is up")
    func neverDelaysRelease() async throws {
        let gate = DraftGate()
        let recogniser = DraftRecogniser(gate: gate)
        let lane = RecogniserLane()
        let drafts = Locked<[String]>([])
        let draft = session(recogniser, lane: lane, drafts: drafts)
        await draft.add(second)
        await gate.waitUntilWaiting()
        draft.close()
        let waited = Locked<Duration?>(nil)
        let release = Task {
            try await lane.exclusive(onWait: { value in waited.withLock { $0 = value } }) { "release" }
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(waited.withLock { $0 } == nil)
        await gate.open()
        #expect(try await release.value == "release")
        let wait = try #require(waited.withLock { $0 })
        #expect(wait >= .milliseconds(25))
        await draft.add(second + second)
        await draft.settle()
        #expect(recogniser.calls == 1)
        #expect(drafts.withLock { $0.isEmpty })
        // With no draft running, the release does not wait at all.
        let idle = Locked<Duration?>(nil)
        _ = try await lane.exclusive(onWait: { value in idle.withLock { $0 = value } }) { 1 }
        #expect(try #require(idle.withLock { $0 }) < .milliseconds(5))
    }

    @Test("a draft and the passes that matter never run on the recogniser at once")
    func neverTwoAtOnce() async throws {
        let recogniser = DraftRecogniser(delay: .milliseconds(3))
        let lane = RecogniserLane()
        let drafts = Locked<[String]>([])
        let draft = session(recogniser, lane: lane, drafts: drafts)
        let early = Task {
            for _ in 0..<15 {
                _ = try await lane.exclusive { try await recogniser.transcribe([0.1]) }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        for _ in 0..<30 {
            await draft.add(second)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await early.value
        await draft.settle()
        #expect(recogniser.mostAtOnce == 1)
        #expect(recogniser.calls > 15)
    }

    @Test("a draft that ends after cancel, idle or an error shows nothing, and an error frees the recogniser")
    func closedOrFailedShowsNothing() async throws {
        let gate = DraftGate()
        let recogniser = DraftRecogniser(gate: gate)
        let drafts = Locked<[String]>([])
        let draft = session(recogniser, drafts: drafts)
        await draft.add(second)
        await gate.waitUntilWaiting()
        draft.close()
        await gate.open()
        _ = await draft.finish()
        #expect(drafts.withLock { $0.isEmpty })

        let lane = RecogniserLane()
        let failing = LiveDraftSession(lane: lane, recognise: { _ in throw CancellationError() },
                                       onDraft: { text in drafts.withLock { $0.append(text) } })
        await failing.add(second)
        await failing.settle()
        #expect(await failing.stats.failures == 1)
        #expect(await !lane.isDraftRunning)
        #expect(drafts.withLock { $0.isEmpty })
    }

    @Test("digital silence costs no pass, and a word cut by the window's start is never shown")
    func silenceAndClippedWords() async {
        let recogniser = DraftRecogniser()
        let drafts = Locked<[String]>([])
        let draft = session(recogniser, drafts: drafts)
        await draft.add([Float](repeating: 0, count: 16_000))
        await draft.settle()
        #expect(recogniser.calls == 0)
        #expect(await draft.stats.skippedSilent == 1)
        #expect(LiveDraftText.usable("ing the report", windowClipped: true) == "the report")
        #expect(LiveDraftText.usable("Send the report", windowClipped: false) == "Send the report")
        #expect(LiveDraftText.usable("ing", windowClipped: true) == nil)
        #expect(LiveDraftText.usable("  ", windowClipped: false) == nil)
    }

    @Test("feeding a four-minute dictation stays flat: the draft keeps five seconds, not the recording")
    func feedingCostIsFlat() async {
        let recogniser = DraftRecogniser()
        let drafts = Locked<[String]>([])
        let draft = session(recogniser, drafts: drafts)
        let clock = ContinuousClock()
        var early: Duration = .zero
        var late: Duration = .zero
        for index in 0..<240 {
            let took = await clock.measure { await draft.add(second) }
            await draft.settle()
            if index < 60 { early += took } else if index >= 180 { late += took }
        }
        print("live draft feed: first minute \(early), fourth minute \(late), for 60 one-second adds")
        #expect(recogniser.longestInput == 80_000)
        #expect(late < early * 5 + .milliseconds(20))
    }
}

/// A recogniser that says how many samples it was given and how many calls overlapped. With a gate, each call waits
/// for it to open.
private final class DraftRecogniser: Sendable {
    private let gate: DraftGate?
    private let delay: Duration
    private let state = Mutex((calls: 0, running: 0, most: 0, longest: 0))

    init(gate: DraftGate? = nil, delay: Duration = .zero) {
        self.gate = gate
        self.delay = delay
    }

    var calls: Int { state.withLock { $0.calls } }
    var mostAtOnce: Int { state.withLock { $0.most } }
    var longestInput: Int { state.withLock { $0.longest } }

    func transcribe(_ samples: [Float]) async throws -> String {
        state.withLock {
            $0.calls += 1
            $0.running += 1
            $0.most = max($0.most, $0.running)
            $0.longest = max($0.longest, samples.count)
        }
        defer { state.withLock { $0.running -= 1 } }
        if let gate { await gate.wait() }
        if delay > .zero { try await Task.sleep(for: delay) }
        return "please send the revised proposal"
    }
}

/// A value several tasks share.
private final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout sending Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

/// Holds whoever waits on it until it is opened.
private actor DraftGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func waitUntilWaiting() async {
        while waiters.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

@Suite("Live draft: a stalled pass cannot hold the recogniser", .timeLimit(.minutes(1)), .serialized)
struct LiveDraftDeadlineTests {
    private let second = [Float](repeating: 0.01, count: 16_000)

    @Test("a draft pass that never answers gives the lane back, so the release pass is not held behind it")
    func hungDraftFreesTheLane() async throws {
        let lane = RecogniserLane()
        let draft = LiveDraftSession(
            lane: lane, passDeadline: .milliseconds(200),
            recognise: { _ in await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }; return "" },
            onDraft: { _ in })
        await draft.add(second)
        for _ in 0..<200 where !(await lane.isDraftRunning) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await lane.isDraftRunning, "the draft pass is in flight and stuck")

        let released = Locked(false)
        Task { _ = try await lane.exclusive { 1 }; released.withLock { $0 = true } }
        for _ in 0..<300 where !released.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(released.withLock { $0 }, "the release pass ran once the stuck draft pass passed its deadline")
        #expect(!(await lane.isDraftRunning))
    }

    @Test("after a draft pass times out no further draft starts for that recording")
    func noMoreDraftsAfterATimeout() async throws {
        let calls = Locked(0)
        let lane = RecogniserLane()
        let draft = LiveDraftSession(
            lane: lane, passDeadline: .milliseconds(100),
            recognise: { _ in calls.withLock { $0 += 1 }; await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }; return "" },
            onDraft: { _ in })
        await draft.add(second)
        await draft.settle()
        for _ in 0..<5 { await draft.add(second); await draft.settle() }
        #expect(calls.withLock { $0 } == 1, "stuck passes do not pile up in the recogniser")
        #expect(await draft.stats.failures == 1)
    }
}
