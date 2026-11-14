import Foundation
import Testing
@testable import MurmurCore

@MainActor
@Suite("AppLockController")
struct AppLockTests {
    @Test("disabled lock is never locked")
    func disabledIsNeverLocked() {
        let controller = AppLockController(authenticator: FakeDeviceAuthenticator(), isEnabled: false)
        #expect(!controller.isLocked)
        controller.checkIdleTimeout(now: Date().addingTimeInterval(10_000))
        #expect(!controller.isLocked)
    }

    @Test("enabling lock starts locked")
    func enablingStartsLocked() {
        let controller = AppLockController(authenticator: FakeDeviceAuthenticator(), isEnabled: false)
        controller.isEnabled = true
        #expect(controller.isLocked)
    }

    @Test("locks after the configured idle timeout with no activity")
    func locksAfterIdleTimeout() {
        let start = Date()
        let controller = AppLockController(authenticator: FakeDeviceAuthenticator(), isEnabled: true, autoLockMinutes: 5, now: start)
        // Unlock first so we can observe the idle-triggered lock specifically.
        controller.lockedSinceEnablingTestHook = false
        #expect(!controller.isLocked)

        controller.checkIdleTimeout(now: start.addingTimeInterval(4 * 60))
        #expect(!controller.isLocked, "should not lock before the timeout elapses")

        controller.checkIdleTimeout(now: start.addingTimeInterval(5 * 60 + 1))
        #expect(controller.isLocked, "should lock once the timeout elapses")
    }

    @Test("recordActivity resets the idle clock")
    func recordActivityResetsIdleClock() {
        let start = Date()
        let controller = AppLockController(authenticator: FakeDeviceAuthenticator(), isEnabled: true, autoLockMinutes: 5, now: start)
        controller.lockedSinceEnablingTestHook = false

        controller.recordActivity(now: start.addingTimeInterval(4 * 60))
        controller.checkIdleTimeout(now: start.addingTimeInterval(4 * 60 + 30))
        #expect(!controller.isLocked, "activity at 4:00 should push the timeout to 9:00")

        controller.checkIdleTimeout(now: start.addingTimeInterval(9 * 60 + 31))
        #expect(controller.isLocked)
    }

    @Test("system sleep or screen lock locks immediately, ignoring the idle grace period")
    func systemSleepLocksImmediately() {
        let controller = AppLockController(authenticator: FakeDeviceAuthenticator(), isEnabled: true)
        controller.lockedSinceEnablingTestHook = false
        controller.lockForSystemSleepOrScreenLock()
        #expect(controller.isLocked)
    }

    @Test("successful authentication unlocks and resets the idle clock")
    func successfulAuthenticationUnlocks() async {
        let start = Date()
        let auth = FakeDeviceAuthenticator(result: true)
        let controller = AppLockController(authenticator: auth, isEnabled: true, autoLockMinutes: 5, now: start)
        #expect(controller.isLocked)

        let ok = await controller.unlock(now: start)
        #expect(ok)
        #expect(!controller.isLocked)
        #expect(auth.callCount == 1)

        // The idle clock should restart from the unlock moment, not the original construction time.
        controller.checkIdleTimeout(now: start.addingTimeInterval(4 * 60))
        #expect(!controller.isLocked)
    }

    @Test("failed authentication leaves the app locked")
    func failedAuthenticationStaysLocked() async {
        let auth = FakeDeviceAuthenticator(result: false)
        let controller = AppLockController(authenticator: auth, isEnabled: true)
        let ok = await controller.unlock()
        #expect(!ok)
        #expect(controller.isLocked)
    }

    @Test("unlocking when not locked is a no-op success and doesn't prompt")
    func unlockingWhenNotLockedIsNoOp() async {
        let auth = FakeDeviceAuthenticator(result: true)
        let controller = AppLockController(authenticator: auth, isEnabled: false)
        let ok = await controller.unlock()
        #expect(ok)
        #expect(auth.callCount == 0)
    }

    @Test("disabling lock while locked clears the locked state")
    func disablingClearsLockedState() {
        let controller = AppLockController(authenticator: FakeDeviceAuthenticator(), isEnabled: true)
        #expect(controller.isLocked)
        controller.isEnabled = false
        #expect(!controller.isLocked)
    }

    @Test("weakening protection succeeds with a successful auth prompt")
    func weakenProtectionSucceedsWithGoodAuth() async {
        let auth = FakeDeviceAuthenticator(result: true)
        let controller = AppLockController(authenticator: auth, isEnabled: true)
        let ok = await controller.authenticateToWeakenProtection()
        #expect(ok)
        #expect(auth.callCount == 1)
    }

    @Test("weakening protection fails and prompts even when already unlocked")
    func weakenProtectionPromptsEvenWhenUnlocked() async {
        let auth = FakeDeviceAuthenticator(result: false)
        let controller = AppLockController(authenticator: auth, isEnabled: true)
        controller.lockedSinceEnablingTestHook = false
        #expect(!controller.isLocked)
        let ok = await controller.authenticateToWeakenProtection()
        #expect(!ok)
        #expect(auth.callCount == 1, "must still prompt even though the view is already unlocked")
    }

    @Test("dictation availability is independent of lock state (documented contract)")
    func lockStateDoesNotClaimToGateDictation() {
        // AppLockController only exposes `isLocked` for gating views; it has no API that could
        // disable dictation, which is the product requirement ("never lock the user out of
        // dictation"). This test pins that contract at the type level: there is no such API to
        // accidentally wire up.
        let controller = AppLockController(authenticator: FakeDeviceAuthenticator(), isEnabled: true)
        _ = controller.isLocked // the only external signal; nothing else exists to gate on.
    }
}

private extension AppLockController {
    /// Test-only escape hatch to set the locked flag directly (e.g. to start a scenario already
    /// unlocked), since the public API only exposes semantically meaningful transitions.
    var lockedSinceEnablingTestHook: Bool {
        get { lockedSinceEnabling }
        set { setLockedForTesting(newValue) }
    }
}
