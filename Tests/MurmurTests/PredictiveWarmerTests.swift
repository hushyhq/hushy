import AppKit
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The signals the predictive warm listens for, and the idle watch: a slow tick while the person is active, no
/// timer while idle, and one "back from idle" on the first input.
@MainActor
@Suite("Predictive warmer", .timeLimit(.minutes(1)))
struct PredictiveWarmerTests {
    private final class Monitors {
        var installed = 0
        var removed = 0
        var handler: (() -> Void)?
    }

    private final class Idle {
        var seconds: TimeInterval = 0
    }

    private func makeWarmer(center: NotificationCenter, idle: Idle, monitors: Monitors) -> PredictiveWarmer {
        let keeper = ModelWarmthKeeper(memory: { nil }, conditions: { .init(lowPowerMode: true) })
        return PredictiveWarmer(
            keeper: keeper, center: center, distributed: DistributedNotificationCenter.default(),
            tracker: ActivityTracker(idleThreshold: 180, activeWindow: 60), tickInterval: 3_600,
            idleSeconds: { idle.seconds },
            installInputMonitor: { handler in
                monitors.installed += 1
                monitors.handler = handler
                return "monitor"
            },
            removeInputMonitor: { _ in monitors.removed += 1 })
    }

    @Test("wake, screen wake, session and app activation reach the keeper")
    func workspaceSignals() {
        let center = NotificationCenter()
        let warmer = makeWarmer(center: center, idle: Idle(), monitors: Monitors())
        warmer.start()
        defer { warmer.stop() }
        let cases: [(Notification.Name, WarmSignal)] = [
            (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.screensDidWakeNotification, .wake),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive),
            (NSWorkspace.didActivateApplicationNotification, .appActivated),
        ]
        for (name, signal) in cases {
            center.post(name: name, object: nil)
            #expect(warmer.lastSignal == signal)
        }
    }

    @Test("active input ticks; idle installs one input monitor; the first input is back-from-idle")
    func idleCycle() {
        let idle = Idle()
        let monitors = Monitors()
        let warmer = makeWarmer(center: NotificationCenter(), idle: idle, monitors: monitors)
        warmer.start()
        defer { warmer.stop() }

        idle.seconds = 10
        warmer.tick()
        #expect(warmer.lastSignal == .activeTick)

        idle.seconds = 400
        warmer.tick()
        #expect(monitors.installed == 1)
        warmer.tick()
        #expect(monitors.installed == 1)

        monitors.handler?()
        #expect(warmer.lastSignal == .backFromIdle)
        #expect(monitors.removed == 1)

        warmer.inputArrived()
        #expect(monitors.removed == 1)
    }

    @Test("a quiet minute that is not yet idle sends nothing")
    func quietMinute() {
        let idle = Idle()
        idle.seconds = 90
        let warmer = makeWarmer(center: NotificationCenter(), idle: idle, monitors: Monitors())
        warmer.tick()
        #expect(warmer.lastSignal == nil)
    }

    @Test("system readings are sane")
    func systemReadings() {
        #expect(PredictiveWarmer.systemIdleSeconds() >= 0)
        let conditions = SystemWarmConditions()
        conditions.memoryPressure(.warning)
        #expect(conditions.read().memoryPressure == .warning)
    }
}
