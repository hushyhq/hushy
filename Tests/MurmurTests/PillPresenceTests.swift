import Foundation
import Testing
@testable import Murmur

@Suite("Pill presence")
@MainActor
struct PillPresenceTests {
    private func settings() throws -> (AppSettings, String) {
        let suite = "hushy-test-pill-presence-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppSettings(defaults: defaults, calendarAuthorization: .notDetermined), suite)
    }

    @Test("a new install is Mini: the resting pill shows, the live words do not")
    func defaultIsMini() throws {
        let (settings, suite) = try settings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(settings.pillPresence == .mini)
        #expect(settings.showIdlePill)
        #expect(!settings.pillShowsLiveWords)
    }

    @Test("a new install hides the idle pill during video or full screen by default")
    func defaultHideDuringVideo() throws {
        let (settings, suite) = try settings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(settings.hideIdlePillDuringVideoOrFullScreen)
    }

    @Test("Hidden keeps the last look, so the older hide switches bring it back as it was")
    func hiddenRemembers() throws {
        let (settings, suite) = try settings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settings.pillPresence = .large
        settings.pillPresence = .hidden
        #expect(!settings.showIdlePill)
        #expect(settings.pillShowsLiveWords, "the recording pill is still Large when the key is pressed")
        settings.showIdlePill = true   // the menu bar's "Show Pill When Idle"
        #expect(settings.pillPresence == .large)
    }

    @Test("Mini still runs the live draft that cleanup uses; only Large draws its words")
    func miniKeepsTheDraft() throws {
        let harness = try DictationRecoveryControllerTests.Harness()
        harness.settings.pillPresence = .mini
        let mini = harness.controller.liveDraft(recordingID: UUID())
        #expect(!harness.pill.liveWordsAllowed)
        #expect(mini != nil || ProcessInfo.processInfo.isLowPowerModeEnabled)
        harness.settings.pillPresence = .large
        _ = harness.controller.liveDraft(recordingID: UUID())
        #expect(harness.pill.liveWordsAllowed || ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
