import Foundation
import Testing
@testable import MurmurCore

/// Background model work stops the moment a dictation starts: `ForegroundActivity.untilBusy` is woken by the key
/// press itself, with no poll interval in between.
@Suite("Foreground activity wakes background work", .timeLimit(.minutes(1)))
struct ForegroundActivityWakeTests {
    @Test("a waiter returns as soon as busy is set, and at once when a dictation is already in progress")
    func wakesOnBusy() async throws {
        let activity = ForegroundActivity()
        let waiter = Task { () -> ContinuousClock.Instant in
            await activity.untilBusy()
            return .now
        }
        try await Task.sleep(for: .milliseconds(100))
        let pressed = ContinuousClock.now
        activity.set(busy: true)
        let woke = await waiter.value
        #expect(woke - pressed < .milliseconds(20), "woken by the press, not a poll")
        let began = ContinuousClock.now
        await activity.untilBusy()
        #expect(ContinuousClock.now - began < .milliseconds(20))
    }

    @Test("a cancelled waiter returns without a dictation, and setting idle wakes no one")
    func cancelReturns() async throws {
        let activity = ForegroundActivity()
        let waiter = Task { await activity.untilBusy(); return activity.isBusy }
        try await Task.sleep(for: .milliseconds(50))
        activity.set(busy: false)
        waiter.cancel()
        #expect(await waiter.value == false)
    }
}
