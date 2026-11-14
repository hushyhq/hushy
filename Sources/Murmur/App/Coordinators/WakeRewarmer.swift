import AppKit
import MurmurCore

/// Warms the cleanup model and the speech engine when the Mac wakes from sleep, the way the app does at launch,
/// so the first dictation after a wake does not pay for it. The wake signal is a notification center and name
/// the caller passes in (a test posts its own). macOS sends several notifications around one wake, so those
/// within `coalesceWindow` of the one that started a warm-up are dropped. Both warm-ups run in a detached task at
/// utility priority and this returns at once, so a dictation that begins right after the wake is never held up.
@MainActor
final class WakeRewarmer {
    private var observer: NSObjectProtocol?
    private let center: NotificationCenter
    private let coalesceWindow: Duration
    private let now: () -> ContinuousClock.Instant
    private let cleanupLevel: () -> CleanupLevel
    private let warmCleanup: @Sendable (CleanupLevel) -> Void
    private let warmSpeech: @Sendable () async -> Void
    private var lastWarm: ContinuousClock.Instant?

    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        name: Notification.Name = NSWorkspace.didWakeNotification,
        coalesceWindow: Duration = .seconds(15),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        cleanupLevel: @escaping () -> CleanupLevel,
        warmCleanup: @escaping @Sendable (CleanupLevel) -> Void,
        warmSpeech: @escaping @Sendable () async -> Void
    ) {
        self.center = center
        self.coalesceWindow = coalesceWindow
        self.now = now
        self.cleanupLevel = cleanupLevel
        self.warmCleanup = warmCleanup
        self.warmSpeech = warmSpeech
        observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rewarm() }
        }
    }

    /// Stops listening. The app keeps one for its whole life, so only a test needs this (a deinit runs
    /// nonisolated in Swift 6 and cannot reach the observer).
    func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
    }

    /// Verbatim has no cleanup model to warm; the speech engine is warmed whatever the level.
    private func rewarm() {
        let instant = now()
        if let lastWarm, instant - lastWarm < coalesceWindow { return }
        lastWarm = instant
        let level = cleanupLevel()
        let cleanup = warmCleanup
        let speech = warmSpeech
        Task.detached(priority: .utility) {
            if level != .verbatim { cleanup(level) }
            await speech()
        }
    }
}
