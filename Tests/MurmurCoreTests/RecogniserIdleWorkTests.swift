import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// Work that nobody is waiting for (the re-read of a take cancelled with Esc) must not make the next take wait.
/// It starts only when the recogniser lane is free, and a pass that asks while it runs waits for that pass alone.
@Suite("Recogniser lane: idle work", .timeLimit(.minutes(1)), .serialized)
struct RecogniserIdleWorkTests {
    private actor Gate {
        private var isOpen = false
        private var entered = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered += 1
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let resumed = waiters
            waiters = []
            for waiter in resumed { waiter.resume() }
        }

        func waitUntilEntered(_ count: Int = 1) async {
            while entered < count { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }

    private final class Log: Sendable {
        private let lines = Mutex<[String]>([])
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(40)) }

    @Test("idle work on a free lane runs at once")
    func runsWhenFree() async throws {
        let lane = RecogniserLane()
        #expect(try await lane.whenIdle { "read" } == "read")
    }

    @Test("idle work waits for a pass that is running, and runs when it ends")
    func waitsForARunningPass() async throws {
        let lane = RecogniserLane()
        let gate = Gate()
        let log = Log()
        let pass = Task { try await lane.exclusive { await gate.wait(); log.add("pass") } }
        await gate.waitUntilEntered()
        let idle = Task { try await lane.whenIdle { log.add("idle") } }
        await settle()
        #expect(log.all.isEmpty, "the re-read has not started")
        await gate.open()
        try await pass.value
        try await idle.value
        #expect(log.all == ["pass", "idle"])
    }

    @Test("idle work that is waiting lets a pass that arrives later go first")
    func aLaterPassGoesFirst() async throws {
        let lane = RecogniserLane()
        let first = Gate()
        let second = Gate()
        let log = Log()
        let running = Task { try await lane.exclusive { await first.wait(); log.add("first") } }
        await first.waitUntilEntered()
        let idle = Task { try await lane.whenIdle { log.add("idle") } }
        await settle()
        let next = Task { try await lane.exclusive { await second.wait(); log.add("next") } }
        await second.waitUntilEntered()
        await first.open()
        try await running.value
        await settle()
        #expect(log.all == ["first"], "the next take is still running, so the re-read keeps waiting")
        await second.open()
        try await next.value
        try await idle.value
        #expect(log.all == ["first", "next", "idle"])
    }

    @Test("a pass that asks while idle work runs waits for that work alone")
    func aPassWaitsForRunningIdleWork() async throws {
        let lane = RecogniserLane()
        let gate = Gate()
        let log = Log()
        let idle = Task { try await lane.whenIdle { await gate.wait(); log.add("idle") } }
        await gate.waitUntilEntered()
        let pass = Task { try await lane.exclusive { log.add("pass") } }
        await settle()
        #expect(log.all.isEmpty)
        await gate.open()
        try await idle.value
        try await pass.value
        #expect(log.all == ["idle", "pass"])
    }

    @Test("no draft starts while idle work runs, and idle work waits for a draft")
    func draftsAndIdleWork() async throws {
        let lane = RecogniserLane()
        let gate = Gate()
        let idle = Task { try await lane.whenIdle { await gate.wait() } }
        await gate.waitUntilEntered()
        #expect(await lane.claimDraft() == false)
        await gate.open()
        try await idle.value

        #expect(await lane.claimDraft())
        let log = Log()
        let waiting = Task { try await lane.whenIdle { log.add("idle") } }
        await settle()
        #expect(log.all.isEmpty, "a draft pass is running")
        await lane.releaseDraft()
        try await waiting.value
        #expect(log.all == ["idle"])
    }

    @Test("two pieces of idle work never run together")
    func oneAtATime() async throws {
        let lane = RecogniserLane()
        let gate = Gate()
        let log = Log()
        let one = Task { try await lane.whenIdle { await gate.wait(); log.add("one") } }
        await gate.waitUntilEntered()
        let two = Task { try await lane.whenIdle { log.add("two") } }
        await settle()
        #expect(log.all.isEmpty)
        await gate.open()
        try await one.value
        try await two.value
        #expect(log.all == ["one", "two"])
    }

    @Test("idle work that throws gives the lane back")
    func throwingGivesTheLaneBack() async throws {
        struct Failure: Error {}
        let lane = RecogniserLane()
        await #expect(throws: Failure.self) { try await lane.whenIdle { throw Failure() } }
        #expect(try await lane.whenIdle { 1 } == 1)
    }

    @Test("idle work cancelled while it waits never runs and no longer holds the lane back from drafts")
    func cancelledWhileWaiting() async throws {
        let lane = RecogniserLane()
        let gate = Gate()
        let log = Log()
        let running = Task { try await lane.exclusive { await gate.wait() } }
        await gate.waitUntilEntered()
        let idle = Task { try await lane.whenIdle { log.add("idle") } }
        await settle()
        idle.cancel()
        await #expect(throws: CancellationError.self) { try await idle.value }
        await gate.open()
        try await running.value
        await settle()
        #expect(log.all.isEmpty, "the re-read gave up its place")
        #expect(await lane.claimDraft())
        await lane.releaseDraft()
        await settle()
        #expect(await lane.claimDraft(), "and no waiting work takes the gap between two drafts")
        await lane.releaseDraft()
    }

    @Test("idle work that is already cancelled does not start")
    func alreadyCancelled() async {
        let lane = RecogniserLane()
        let log = Log()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await lane.whenIdle { log.add("idle") }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(log.all.isEmpty)
    }
}
