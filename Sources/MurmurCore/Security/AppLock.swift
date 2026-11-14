import Foundation

/// Abstraction over "ask the user to prove they're allowed in" (Touch ID / password), so
/// `AppLockController` can be tested with a fake instead of driving real LocalAuthentication
/// prompts. The real implementation lives in the app target (it needs `LocalAuthentication`,
/// which isn't available to a plain Swift package target in the same way); this protocol is
/// what the controller depends on.
public protocol DeviceAuthenticating: Sendable {
    /// Prompts for Touch ID / password (`.deviceOwnerAuthentication`) and returns whether it
    /// succeeded. Never throws: a cancelled or failed prompt is simply `false`.
    func authenticate(reason: String) async -> Bool
}

/// Whether the app's History/Notes/Insights views require unlocking, and the idle/sleep timer
/// that locks them again. Dictation itself (the pill) never locks — only this state matters for
/// gating the main window's content, and `AppModel` is expected to keep dictation working
/// regardless of `isLocked`.
///
/// This is a plain, testable state machine: no timers of its own beyond what's injected, so
/// tests can drive time deterministically instead of racing real `Timer`/`DispatchQueue` delays.
@MainActor
@Observable
public final class AppLockController {
    /// Whether locking is turned on at all (Settings → "Require Touch ID to open History & Notes").
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                lockedSinceEnabling = true
            } else {
                lockedSinceEnabling = false
            }
        }
    }
    /// Minutes of inactivity before auto-lock. Default 5, per the product spec.
    public var autoLockMinutes: Int

    /// The only externally-visible gate: true means History/Notes/Insights should show the
    /// lock screen instead of their content.
    public private(set) var lockedSinceEnabling: Bool

    private let authenticator: any DeviceAuthenticating
    private var lastActivity: Date

    public init(
        authenticator: any DeviceAuthenticating, isEnabled: Bool = false, autoLockMinutes: Int = 5,
        now: Date = Date()
    ) {
        self.authenticator = authenticator
        self.isEnabled = isEnabled
        self.autoLockMinutes = autoLockMinutes
        self.lastActivity = now
        self.lockedSinceEnabling = isEnabled
    }

    /// True while locking is on and the view should be gated. Named separately from
    /// `lockedSinceEnabling` so call sites read naturally (`if lock.isLocked { LockView() }`).
    public var isLocked: Bool { isEnabled && lockedSinceEnabling }

    /// Call whenever the user does something that counts as "still here" (keystroke, click,
    /// switching into a gated section) so the idle timer resets.
    public func recordActivity(now: Date = Date()) {
        lastActivity = now
    }

    /// Call periodically (e.g. once a second from a `TimelineView` or `Timer`) with the current
    /// time; locks automatically once `autoLockMinutes` have passed with no `recordActivity`.
    public func checkIdleTimeout(now: Date = Date()) {
        guard isEnabled, !lockedSinceEnabling else { return }
        let idleSeconds = now.timeIntervalSince(lastActivity)
        if idleSeconds >= Double(autoLockMinutes) * 60 {
            lockedSinceEnabling = true
        }
    }

    /// Call when the screen locks or the Mac sleeps (`NSWorkspace` notifications in the app
    /// target). Locks immediately, no idle grace period.
    public func lockForSystemSleepOrScreenLock() {
        guard isEnabled else { return }
        lockedSinceEnabling = true
    }

    /// Attempts to unlock via Touch ID / password. On success, resets the idle clock too, so the
    /// user doesn't immediately get re-locked by a timeout that elapsed while the prompt was up.
    @discardableResult
    public func unlock(now: Date = Date()) async -> Bool {
        guard isEnabled, lockedSinceEnabling else { return true }
        let ok = await authenticator.authenticate(reason: "Unlock Hushy to view your history and notes")
        if ok {
            lockedSinceEnabling = false
            lastActivity = now
        }
        return ok
    }

    /// Gate for any Settings change that *weakens* protection: turning the lock off, or
    /// lengthening the auto-lock delay. Requires a fresh successful Touch ID / password prompt
    /// regardless of the current `isLocked` state (someone could be sitting at an already-unlocked
    /// window and still shouldn't be able to silently disable the lock). Turning the lock ON, or
    /// shortening the auto-lock delay, never calls this — those changes only strengthen
    /// protection and enrolling itself is the only gate needed.
    @discardableResult
    public func authenticateToWeakenProtection(
        reason: String = "Confirm it's you to change Hushy's lock settings"
    ) async -> Bool {
        await authenticator.authenticate(reason: reason)
    }

    /// Test-only: sets the locked flag directly, to start a scenario already unlocked without
    /// going through a real (or fake) authentication round trip.
    package func setLockedForTesting(_ locked: Bool) {
        lockedSinceEnabling = locked
    }
}

/// A fake authenticator for tests and previews: returns a fixed, settable result instead of
/// showing a real Touch ID / password prompt.
public final class FakeDeviceAuthenticator: DeviceAuthenticating, @unchecked Sendable {
    public var result: Bool
    public private(set) var callCount = 0

    public init(result: Bool = true) {
        self.result = result
    }

    public func authenticate(reason: String) async -> Bool {
        callCount += 1
        return result
    }
}
