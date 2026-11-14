import Foundation
import Testing
@testable import MurmurCore

/// Covers `FeatureFlags.streamingLongDictation`'s new contract (task: "make streaming the
/// default for all dictations; keep FeatureFlags only as a DEBUG kill switch"):
/// - Defaults to `true` (streaming is now the production default), not `false`.
/// - In a release build the flag can never be turned off — the setter is a no-op and the
///   getter always returns `true`, so this can no longer regress into an accidental
///   "everyone's streaming is silently off" state the way a plain `UserDefaults.bool` read
///   (defaulting to `false`) would if the key were ever cleared.
/// - In a DEBUG build only, it remains a real, settable kill switch (round-trips through
///   `UserDefaults`), so a developer can still isolate a regression to the streaming path.
///
/// Serialized (like `FeatureFlagsSpeakerLabelsTests`) because every test in this suite reads
/// and writes the same `UserDefaults` key.
@Suite("FeatureFlags.streamingLongDictation", .serialized)
struct StreamingFeatureFlagTests {
    private let key = "streamingLongDictation"

    private func withRestoredDefault(_ body: () -> Void) {
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        body()
    }

    @Test("an unset value defaults to true — streaming is on for every dictation by default")
    func unsetValueDefaultsToTrue() {
        withRestoredDefault {
            UserDefaults.standard.removeObject(forKey: key)
            #expect(FeatureFlags.streamingLongDictation == true)
        }
    }

    #if DEBUG
    @Test("in DEBUG, an explicitly-set false value round-trips — the flag is a real kill switch")
    func debugExplicitFalseRoundTrips() {
        withRestoredDefault {
            FeatureFlags.streamingLongDictation = false
            #expect(FeatureFlags.streamingLongDictation == false)
            FeatureFlags.streamingLongDictation = true
            #expect(FeatureFlags.streamingLongDictation == true)
        }
    }
    #else
    @Test("in a release build, the flag cannot be turned off — setter is a no-op, getter always true")
    func releaseFlagCannotBeDisabled() {
        withRestoredDefault {
            FeatureFlags.streamingLongDictation = false
            #expect(FeatureFlags.streamingLongDictation == true)
        }
    }
    #endif
}
