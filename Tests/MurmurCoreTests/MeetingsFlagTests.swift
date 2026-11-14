import Foundation
import Testing
@testable import MurmurCore

/// `FeatureFlags.meetings` keeps meetings and notes private in release builds (TRY-98). Tests run
/// in a DEBUG build, so they check the DEBUG rule through its pure function and that the default
/// there is on; the release `false` is a compile-time branch no test build can run.
@Suite("FeatureFlags.meetings")
struct MeetingsFlagTests {
    @Test("on by default in a debug build, and so in every test")
    func onByDefault() {
        #expect(FeatureFlags.meetingsCanBeTurnedOn)
        #expect(FeatureFlags.meetingsEnabled(environment: [:], stored: nil))
        #expect(FeatureFlags.meetings, "tests need meetings on so every meetings test keeps running")
    }

    @Test("a stored false switches it off, a stored true keeps it on")
    func storedValue() {
        #expect(!FeatureFlags.meetingsEnabled(environment: [:], stored: false))
        #expect(FeatureFlags.meetingsEnabled(environment: [:], stored: true))
        #expect(FeatureFlags.meetingsEnabled(environment: [:], stored: "nonsense"), "an odd stored value is not an off switch")
    }

    @Test("HUSHY_MEETINGS=off renders the release layout, whatever was stored", arguments: ["off", "OFF", "0", "false", "no"])
    func environmentOff(value: String) {
        #expect(!FeatureFlags.meetingsEnabled(environment: ["HUSHY_MEETINGS": value], stored: nil))
        #expect(!FeatureFlags.meetingsEnabled(environment: ["HUSHY_MEETINGS": value], stored: true))
    }

    @Test("other values of the variable leave it on")
    func environmentOther() {
        #expect(FeatureFlags.meetingsEnabled(environment: ["HUSHY_MEETINGS": "on"], stored: nil))
        #expect(FeatureFlags.meetingsEnabled(environment: ["HUSHY_MEETINGS": ""], stored: nil))
    }

    @Test("the key and variable names are the documented ones")
    func names() {
        #expect(FeatureFlags.meetingsKey == "feature.meetings")
        #expect(FeatureFlags.meetingsEnvironmentKey == "HUSHY_MEETINGS")
    }
}
