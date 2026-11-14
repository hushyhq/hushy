import Foundation
import Testing
@testable import MurmurCore

/// `FeatureFlags.meetingAsk` keeps cross-meeting Ask, People pages and prep briefs hidden for launch.
@Suite("FeatureFlags.meetingAsk")
struct MeetingAskFlagTests {
    @Test("off with no test features, in a debug build and so in every test")
    func offByDefault() {
        #expect(!FeatureFlags.meetingAskEnabled(testFeatures: nil))
        #expect(!FeatureFlags.meetingAskEnabled(testFeatures: ""))
        #expect(!FeatureFlags.meetingAsk)
    }

    @Test("other test features do not turn it on")
    func otherFeatures() {
        #expect(!FeatureFlags.meetingAskEnabled(testFeatures: "voice-edit"))
        #expect(!FeatureFlags.meetingAskEnabled(testFeatures: "meeting-asking"))
    }

    @Test("a test build naming meeting-ask turns it on, alone or in a list")
    func namedTurnsOn() {
        #expect(FeatureFlags.meetingAskEnabled(testFeatures: "meeting-ask"))
        #expect(FeatureFlags.meetingAskEnabled(testFeatures: "voice-edit, meeting-ask"))
    }
}
