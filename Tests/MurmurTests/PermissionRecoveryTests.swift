import Testing
@testable import Murmur

@Suite("Permission recovery")
@MainActor
struct PermissionRecoveryTests {
    @Test("only an onboarded person with a missing permission gets one automatic window")
    func windowOncePerLaunch() {
        var recovery = PermissionRecoveryDecision()
        let notOnboarded = recovery.shouldOpen(onboardingComplete: false, microphone: .denied, accessibility: .denied)
        let allGranted = recovery.shouldOpen(onboardingComplete: true, microphone: .granted, accessibility: .granted)
        let firstMissing = recovery.shouldOpen(onboardingComplete: true, microphone: .granted, accessibility: .denied)
        let secondMissing = recovery.shouldOpen(onboardingComplete: true, microphone: .denied, accessibility: .denied)
        #expect(!notOnboarded)
        #expect(!allGranted)
        #expect(firstMissing)
        #expect(!secondMissing)

        var anotherLaunch = PermissionRecoveryDecision()
        let nextLaunch = anotherLaunch.shouldOpen(onboardingComplete: true, microphone: .denied, accessibility: .granted)
        #expect(nextLaunch)
    }

    @Test("a trusted transition installs a missing tap without touching an installed one")
    func recreateTap() {
        #expect(!HotkeyMonitor.shouldRecreateTap(accessibility: .denied, isInstalled: false))
        #expect(HotkeyMonitor.shouldRecreateTap(accessibility: .granted, isInstalled: false))
        #expect(!HotkeyMonitor.shouldRecreateTap(accessibility: .granted, isInstalled: true))
    }

    @Test("the stale TCC entry instruction appears whenever Accessibility is untrusted after onboarding")
    func staleEntryCopy() {
        let status = DictationReadinessStatus.compute(
            modelState: .ready, microphone: .granted, accessibility: .denied,
            triggerKey: .fn, fnCaptureActive: false, globeKeyConflicts: false,
            macDictationClashes: false)
        let after = DictationHeroCopy.make(status: status, triggerGlyph: "fn", modelState: .ready,
                                          download: nil, afterOnboarding: true)
        let firstRun = DictationHeroCopy.make(status: status, triggerGlyph: "fn", modelState: .ready,
                                             download: nil)
        #expect(after.detail.contains("remove it with −, then add it again"))
        #expect(after.detail.contains("macOS asks again after an update"))
        #expect(!firstRun.detail.contains("remove it with −"))
    }
}
