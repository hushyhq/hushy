import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The warm-up after the Mac wakes: one cleanup warm-up and one speech warm-up per wake, no cleanup warm-up in
/// Verbatim, and nothing for a notification that is not the wake.
@MainActor
@Suite("Wake re-warm", .timeLimit(.minutes(1)))
struct WakeRewarmerTests {
    private static let wake = Notification.Name("test.didWake")

    /// Collects what the rewarmer asked for; each call also yields to `events` so a test can wait for it.
    private final class Calls: @unchecked Sendable {
        let events: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation
        init() {
            let made = AsyncStream<String>.makeStream()
            events = made.stream
            continuation = made.continuation
        }
        func record(_ name: String) { continuation.yield(name) }
        func finish() { continuation.finish() }
    }

    /// A clock the test moves by hand.
    private final class Clock {
        var instant = ContinuousClock.now
        func advance(_ by: Duration) { instant += by }
    }

    private func makeRewarmer(
        center: NotificationCenter, level: CleanupLevel, calls: Calls, clock: Clock = Clock()
    ) -> WakeRewarmer {
        WakeRewarmer(
            center: center, name: Self.wake, coalesceWindow: .seconds(15), now: { clock.instant },
            cleanupLevel: { level },
            warmCleanup: { _ in calls.record("cleanup") },
            warmSpeech: { calls.record("speech") })
    }

    private func collect(_ calls: Calls, count: Int) async -> [String] {
        var seen: [String] = []
        for await event in calls.events {
            seen.append(event)
            if seen.count == count { break }
        }
        return seen
    }

    @Test("a wake warms the cleanup model once and the speech engine once")
    func wakeWarmsBoth() async {
        let center = NotificationCenter()
        let calls = Calls()
        let rewarmer = makeRewarmer(center: center, level: .clean, calls: calls)
        center.post(name: Self.wake, object: nil)
        let seen = await collect(calls, count: 2)
        #expect(seen.sorted() == ["cleanup", "speech"])
        withExtendedLifetime(rewarmer) {}
    }

    @Test("Verbatim has no cleanup model to warm; the speech engine is still warmed")
    func verbatimWarmsNoCleanup() async {
        let center = NotificationCenter()
        let calls = Calls()
        let rewarmer = makeRewarmer(center: center, level: .verbatim, calls: calls)
        center.post(name: Self.wake, object: nil)
        #expect(await collect(calls, count: 1) == ["speech"])
        // No cleanup warm-up follows.
        try? await Task.sleep(for: .milliseconds(200))
        calls.finish()
        #expect(await collect(calls, count: 1).isEmpty)
        withExtendedLifetime(rewarmer) {}
    }

    @Test("another notification warms nothing, and a stopped rewarmer stops listening")
    func otherSignalsAndRelease() async {
        let center = NotificationCenter()
        let calls = Calls()
        let rewarmer = makeRewarmer(center: center, level: .clean, calls: calls)
        center.post(name: Notification.Name("test.somethingElse"), object: nil)
        rewarmer.stop()
        center.post(name: Self.wake, object: nil)
        // Let anything wrongly queued on the main queue run before looking.
        try? await Task.sleep(for: .milliseconds(200))
        calls.finish()
        #expect(await collect(calls, count: 1).isEmpty)
    }

    @Test("several notifications around one wake give one warm-up of each; a later wake gives another")
    func severalNotificationsOneWarmup() async {
        let center = NotificationCenter()
        let calls = Calls()
        let clock = Clock()
        let rewarmer = makeRewarmer(center: center, level: .clean, calls: calls, clock: clock)
        for _ in 0..<3 {
            center.post(name: Self.wake, object: nil)
            clock.advance(.milliseconds(400))
        }
        #expect(await collect(calls, count: 2).sorted() == ["cleanup", "speech"])
        // Nothing more arrives for the two dropped notifications.
        try? await Task.sleep(for: .milliseconds(200))
        clock.advance(.seconds(3_600))
        center.post(name: Self.wake, object: nil)
        #expect(await collect(calls, count: 2).sorted() == ["cleanup", "speech"])
        calls.finish()
        #expect(await collect(calls, count: 1).isEmpty)
        withExtendedLifetime(rewarmer) {}
    }
}
