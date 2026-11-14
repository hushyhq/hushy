import Foundation
import Testing
@testable import Murmur

/// The wake warm-up yields to a real transcription: it never starts while one runs, and one that starts cancels it.
@Suite("Warm-up gate", .timeLimit(.minutes(1)))
struct WarmupGateTests {
    /// A warm-up that does nothing until it is cancelled, then says so.
    private final class Probe: @unchecked Sendable {
        let ended: AsyncStream<Bool>
        private let continuation: AsyncStream<Bool>.Continuation
        init() {
            let made = AsyncStream<Bool>.makeStream()
            ended = made.stream
            continuation = made.continuation
        }
        func body() async {
            try? await Task.sleep(for: .seconds(30))
            continuation.yield(Task.isCancelled)
        }
    }

    @Test("a transcription that starts during a warm-up cancels it")
    func transcriptionCancelsWarmup() async throws {
        var gate = WarmupGate()
        let probe = Probe()
        let warmup = try #require(gate.startWarmup { await probe.body() })
        gate.workStarted()
        var results: [Bool] = []
        for await wasCancelled in probe.ended { results.append(wasCancelled); break }
        #expect(results == [true])
        await warmup.value
        gate.workFinished()
    }

    @Test("no warm-up starts while a transcription runs, or while another warm-up does")
    func oneAtATimeAndNotDuringWork() async throws {
        var gate = WarmupGate()
        gate.workStarted()
        let duringWork = gate.startWarmup { }
        #expect(duringWork == nil)
        gate.workFinished()
        let first = try #require(gate.startWarmup { try? await Task.sleep(for: .seconds(30)) })
        let second = gate.startWarmup { }
        #expect(second == nil)
        gate.workStarted()   // cancels the first
        gate.workFinished()
        await first.value
        let again = gate.startWarmup { }
        #expect(again != nil)
        if let again { gate.warmupEnded(again) }
    }

    @Test("a finished warm-up lets the next one start, and an old warm-up ending does not clear a newer one")
    func endedWarmups() async throws {
        var gate = WarmupGate()
        let first = try #require(gate.startWarmup { })
        await first.value
        gate.warmupEnded(first)
        let second = try #require(gate.startWarmup { try? await Task.sleep(for: .seconds(30)) })
        gate.warmupEnded(first)   // stale: must not free the slot
        let blocked = gate.startWarmup { }
        #expect(blocked == nil)
        gate.workStarted()
        await second.value
    }
}
