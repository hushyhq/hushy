import Foundation
import os

extension AppModel {
    /// Keep observing after a grant so a later revocation is surfaced on this launch too.
    func startPermissionRecovery() {
        permissionRecoveryStarted = true
        permissions.onChange = { [weak self] microphone, accessibility in
            guard let self else { return }
            self.log.notice("permissions changed: microphone=\(String(describing: microphone), privacy: .public) accessibility=\(String(describing: accessibility), privacy: .public)")
            if HotkeyMonitor.shouldRecreateTap(accessibility: accessibility, isInstalled: self.hotkeys.isInstalled) {
                self.installHotkeys()
            } else if accessibility != .granted {
                self.hotkeys.stop()
                self.hotkeyRetry?.invalidate()
                self.hotkeyRetry = nil
            }
            self.showPermissionRecoveryIfNeeded()
        }
        permissions.refresh()
        permissions.startPolling()
        showPermissionRecoveryIfNeeded()
    }

    /// The action chord rides on the dictation tap. A failed tap retries only while Accessibility
    /// reports trusted; the next trust transition also installs it immediately.
    func installHotkeys() {
        guard permissions.accessibility == .granted, !isCaptureClosed else { return }
        hotkeys.chord = actionHotkeys
        if hotkeys.start() {
            hotkeyRetry?.invalidate()
            hotkeyRetry = nil
            return
        }
        guard hotkeyRetry == nil else { return }
        hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installHotkeys() }
        }
    }

    func showPermissionRecoveryIfNeeded() {
        guard permissionRecoveryStarted, openWindowHandler != nil,
              permissionRecovery.shouldOpen(onboardingComplete: settings.hasCompletedOnboarding,
                                            microphone: permissions.microphone,
                                            accessibility: permissions.accessibility) else { return }
        section = .home
        openMainWindow()
    }
}
