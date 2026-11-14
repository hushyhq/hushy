import Foundation
import Testing
@testable import MurmurCore

/// Covers `Entitlements.has(_:)` and its DEBUG-only `UserDefaults` override, plus
/// `FeatureFlags.speakerLabels`'s "unset defaults to build-config default" behavior.
@Suite("Entitlements", .serialized)
struct EntitlementsTests {
    @Test("debugUnlocked toggle round-trips through UserDefaults")
    func debugUnlockedRoundTrips() {
        let original = Entitlements.debugUnlocked
        defer { Entitlements.debugUnlocked = original }

        Entitlements.debugUnlocked = true
        #expect(Entitlements.debugUnlocked == true)
        Entitlements.debugUnlocked = false
        #expect(Entitlements.debugUnlocked == false)
    }

    #if DEBUG
    @Test("has(_:) reflects the debug override in DEBUG builds")
    func hasReflectsDebugOverrideInDebug() {
        let original = Entitlements.debugUnlocked
        defer { Entitlements.debugUnlocked = original }

        Entitlements.debugUnlocked = true
        #expect(Entitlements.has(.speakerLabels) == true)
        #expect(Entitlements.has(.voiceSignatures) == true)

        Entitlements.debugUnlocked = false
        #expect(Entitlements.has(.voiceActions), "voice actions are free with the override off")
    }
    #endif

    @Test("free features are unlocked for everyone, regardless of the debug override")
    func freeFeaturesAlwaysUnlocked() {
        let original = Entitlements.debugUnlocked
        defer { Entitlements.debugUnlocked = original }
        Entitlements.debugUnlocked = false
        #expect(Entitlements.has(.speakerLabels))
        #expect(Entitlements.has(.systemAudio))
        #expect(Entitlements.has(.voiceSignatures))
    }

    @Test("every ProFeature case is distinct")
    func everyFeatureIsDistinct() {
        #expect(Set(ProFeature.allCases.map(\.rawValue)).count == ProFeature.allCases.count)
    }

    @Test("Pro removed (founder, 2026-11-11): every feature is free, voice actions included")
    func packaging() {
        #expect(ProFeature.voiceActions.isFree)
        #expect(ProFeature.allCases.allSatisfy { $0.isFree })
        #expect(Entitlements.has(.voiceActions, defaults: UserDefaults(suiteName: "entitlements-free-\(UUID().uuidString)")!),
                "free with no account, invite or override")
    }

    @Test("systemAudio is unlocked for everyone while the pricing-decision flag is on, even in release-like state")
    func systemAudioFreeForAllUsersWhileFlagIsOn() {
        // This asserts against the *current* documented product state (task: "keep it ENABLED
        // for all users for now"), not the debug override — resetting `debugUnlocked` to false
        // proves `.systemAudio` doesn't depend on it while the flag is on.
        let original = Entitlements.debugUnlocked
        defer { Entitlements.debugUnlocked = original }
        Entitlements.debugUnlocked = false

        #expect(Entitlements.has(.systemAudio) == true)
    }
}

@Suite("FeatureFlags.speakerLabels", .serialized)
struct FeatureFlagsSpeakerLabelsTests {
    @Test("an explicitly-set value is read back exactly, overriding the build-config default")
    func explicitValueOverridesDefault() {
        let key = "feature.speakerLabels"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        FeatureFlags.speakerLabels = false
        #expect(FeatureFlags.speakerLabels == false)
        FeatureFlags.speakerLabels = true
        #expect(FeatureFlags.speakerLabels == true)
    }

    @Test("an unset value defaults on in DEBUG and release builds")
    func unsetValueFallsBackToBuildDefault() {
        let key = "feature.speakerLabels"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)

        #expect(FeatureFlags.speakerLabels == true)
    }
}
