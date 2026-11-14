import Foundation
import Testing
@testable import MurmurCore

@Suite("Deadline: a wait that cannot be stuck", .timeLimit(.minutes(1)))
struct DeadlineTests {
    @Test("work that finishes in time returns its value")
    func returnsTheValue() async throws {
        let value = try await Deadline.race(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test("work that throws throws the same error")
    func propagatesTheError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await Deadline.race(.seconds(5)) { throw Boom() } as Int }
    }

    @Test("work that never answers and ignores cancellation is left behind at the limit")
    func stalledWorkExpires() async {
        let started = ContinuousClock.now
        await #expect(throws: DeadlineExpired.self) {
            try await Deadline.race(.milliseconds(150)) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("cancelling the caller cancels the work, which then decides how it ends")
    func cancellationReachesTheWork() async {
        let caller = Task { try await Deadline.race(.seconds(30)) { try await Task.sleep(for: .seconds(30)); return 1 } }
        try? await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        let result = await caller.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
