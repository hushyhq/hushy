import Foundation
import Testing
@testable import MurmurCore

/// Covers `CallDetectionState`'s pure decision logic: when to show/dismiss the call-detected
/// prompt, when to start/cancel/fire the stop countdown, the never-list, and `MaxRecordingLength`'s
/// warning/stop boundaries. See the task's contract: prompt disappears after 20 s, stop countdown
/// starts after ~10 s of no mic use and runs 5 s, and "no prompt while already recording."
@Suite("Call detection state machine")
struct CallDetectionStateTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Prompt lifecycle

    @Test("mic use by a recognized app shows a prompt")
    func showsPromptOnMicUse() {
        var state = CallDetectionState()
        let effect = state.observeMicActivity(app: .zoom, isRecording: false, now: epoch)
        #expect(effect == .showPrompt(.zoom))
        #expect(state.pendingPrompt?.app == .zoom)
    }

    @Test("prompt does not re-fire while already pending")
    func promptDoesNotDuplicate() {
        var state = CallDetectionState()
        _ = state.observeMicActivity(app: .zoom, isRecording: false, now: epoch)
        let second = state.observeMicActivity(app: .zoom, isRecording: false, now: epoch.addingTimeInterval(1))
        #expect(second == .none)
    }

    @Test("never prompts while a note is already recording")
    func noPromptWhileRecording() {
        var state = CallDetectionState()
        let effect = state.observeMicActivity(app: .teams, isRecording: true, now: epoch)
        #expect(effect == .none)
        #expect(state.pendingPrompt == nil)
    }

    @Test("prompt auto-dismisses after 20 s via tick")
    func promptExpiresAfter20Seconds() {
        var state = CallDetectionState()
        _ = state.observeMicActivity(app: .webex, isRecording: false, now: epoch)
        let notYet = state.tick(now: epoch.addingTimeInterval(19.9))
        #expect(notYet == .none)
        #expect(state.pendingPrompt != nil)
        let expired = state.tick(now: epoch.addingTimeInterval(20))
        #expect(expired == .dismissPrompt)
        #expect(state.pendingPrompt == nil)
    }

    @Test("accepting the prompt clears it and returns the app")
    func acceptPromptReturnsApp() {
        var state = CallDetectionState()
        _ = state.observeMicActivity(app: .faceTime, isRecording: false, now: epoch)
        let accepted = state.acceptPrompt()
        #expect(accepted == .faceTime)
        #expect(state.pendingPrompt == nil)
        #expect(state.activeApp == .faceTime)
    }

    @Test("dismissing the prompt clears it without setting an active app")
    func dismissPromptClears() {
        var state = CallDetectionState()
        _ = state.observeMicActivity(app: .discord, isRecording: false, now: epoch)
        state.dismissPrompt()
        #expect(state.pendingPrompt == nil)
        #expect(state.activeApp == nil)
    }

    // MARK: - Never-list

    @Test("never-list suppresses future prompts for that app only")
    func neverListSuppressesOnlyThatApp() {
        var state = CallDetectionState()
        state.addToNeverList(.zoom)
        let zoomEffect = state.observeMicActivity(app: .zoom, isRecording: false, now: epoch)
        #expect(zoomEffect == .none)
        let teamsEffect = state.observeMicActivity(app: .teams, isRecording: false, now: epoch)
        #expect(teamsEffect == .showPrompt(.teams))
    }

    @Test("adding to the never-list dismisses a currently-pending prompt for that app")
    func neverListDismissesPendingPrompt() {
        var state = CallDetectionState()
        _ = state.observeMicActivity(app: .slackHuddle, isRecording: false, now: epoch)
        #expect(state.pendingPrompt != nil)
        state.addToNeverList(.slackHuddle)
        #expect(state.pendingPrompt == nil)
    }

    @Test("removing from the never-list allows prompting again")
    func removeFromNeverListReallows() {
        var state = CallDetectionState(neverList: [.zoom])
        state.removeFromNeverList(.zoom)
        let effect = state.observeMicActivity(app: .zoom, isRecording: false, now: epoch)
        #expect(effect == .showPrompt(.zoom))
    }

    @Test("never-list is seeded from init and persists across calls")
    func neverListSeededFromInit() {
        let state = CallDetectionState(neverList: [.zoom, .discord])
        #expect(state.neverList == [.zoom, .discord])
    }

    // MARK: - Stop countdown (call ends while recording)

    @Test("mic use stopping for 10s while recording starts a stop countdown")
    func stopCountdownStartsAfterDebounce() {
        var state = CallDetectionState()
        _ = state.observeMicActivity(app: .zoom, isRecording: false, now: epoch)
        _ = state.acceptPrompt()
        // Mic still active for a while, then silence.
        _ = state.observeMicActivity(app: .zoom, isRecording: true, now: epoch.addingTimeInterval(5))
        let tooSoon = state.observeMicActivity(app: nil, isRecording: true, now: epoch.addingTimeInterval(5 + 9.9))
        #expect(tooSoon == .none)
        #expect(state.stopCountdown == nil)
        let countdownStarts = state.observeMicActivity(app: nil, isRecording: true, now: epoch.addingTimeInterval(5 + 10))
        #expect(countdownStarts == .startStopCountdown)
        #expect(state.stopCountdown != nil)
    }

    @Test("mic activity resuming during the countdown cancels it")
    func stopCountdownCancelledByResumedActivity() {
        var state = CallDetectionState()
        _ = state.observeMicActivity(app: .zoom, isRecording: false, now: epoch)
        _ = state.acceptPrompt()
        _ = state.observeMicActivity(app: nil, isRecording: true, now: epoch.addingTimeInterval(10))
        #expect(state.stopCountdown != nil)
        let resumed = state.observeMicActivity(app: .zoom, isRecording: true, now: epoch.addingTimeInterval(12))
        #expect(resumed == .cancelStopCountdown)
        #expect(state.stopCountdown == nil)
    }

    @Test("the 5 s countdown fires stopRecording via tick and clears active state")
    func stopCountdownFiresAfter5Seconds() {
        var state = CallDetectionState()
        _ = state.observeMicActivity(app: .zoom, isRecording: false, now: epoch)
        _ = state.acceptPrompt()
        _ = state.observeMicActivity(app: nil, isRecording: true, now: epoch.addingTimeInterval(10))
        let notYet = state.tick(now: epoch.addingTimeInterval(10 + 4.9))
        #expect(notYet == .none)
        let fired = state.tick(now: epoch.addingTimeInterval(10 + 5))
        #expect(fired == .stopRecording)
        #expect(state.stopCountdown == nil)
        #expect(state.activeApp == nil)
    }

    @Test("user-tapped cancel keeps recording and resets the mic-active clock")
    func cancelStopCountdownKeepsRecording() {
        var state = CallDetectionState()
        _ = state.observeMicActivity(app: .zoom, isRecording: false, now: epoch)
        _ = state.acceptPrompt()
        _ = state.observeMicActivity(app: nil, isRecording: true, now: epoch.addingTimeInterval(10))
        #expect(state.stopCountdown != nil)
        state.cancelStopCountdown()
        #expect(state.stopCountdown == nil)
        #expect(state.activeApp == .zoom)
    }

    @Test("reset clears every piece of in-progress state")
    func resetClearsEverything() {
        var state = CallDetectionState()
        _ = state.observeMicActivity(app: .zoom, isRecording: false, now: epoch)
        _ = state.acceptPrompt()
        _ = state.observeMicActivity(app: nil, isRecording: true, now: epoch.addingTimeInterval(10))
        state.reset()
        #expect(state.pendingPrompt == nil)
        #expect(state.stopCountdown == nil)
        #expect(state.activeApp == nil)
    }

    @Test("beginTrackingActiveCall lets a manually-started recording still auto-stop")
    func beginTrackingActiveCallEnablesAutoStop() {
        var state = CallDetectionState()
        state.beginTrackingActiveCall(app: .teams)
        #expect(state.activeApp == .teams)
        _ = state.observeMicActivity(app: .teams, isRecording: true, now: epoch)
        let countdownStarts = state.observeMicActivity(app: nil, isRecording: true, now: epoch.addingTimeInterval(10))
        #expect(countdownStarts == .startStopCountdown)
    }
}

/// Covers `MaxRecordingLength`'s pure warning/stop boundary logic.
@Suite("Maximum recording length")
struct MaxRecordingLengthTests {
    @Test("default is 2 hours per the task's contract")
    func defaultIsTwoHours() {
        #expect(MaxRecordingLength.default == .twoHours)
    }

    @Test("every option maps to the expected number of seconds")
    func durations() {
        #expect(MaxRecordingLength.thirtyMinutes.seconds == 30 * 60)
        #expect(MaxRecordingLength.oneHour.seconds == 60 * 60)
        #expect(MaxRecordingLength.twoHours.seconds == 2 * 60 * 60)
        #expect(MaxRecordingLength.fourHours.seconds == 4 * 60 * 60)
    }

    @Test("no effect well before the limit")
    func noEffectEarly() {
        let effect = MaxRecordingLength.thirtyMinutes.effect(elapsedSeconds: 60, warningAlreadyShown: false)
        #expect(effect == .none)
    }

    @Test("warning fires exactly 2 minutes before the limit, once")
    func warningFiresTwoMinutesBefore() {
        let length = MaxRecordingLength.thirtyMinutes
        let warningAt = length.seconds - CallDetectionState.maxLengthWarning
        let effect = length.effect(elapsedSeconds: warningAt, warningAlreadyShown: false)
        #expect(effect == .showMaxLengthWarning)
        let alreadyShown = length.effect(elapsedSeconds: warningAt + 1, warningAlreadyShown: true)
        #expect(alreadyShown == .none)
    }

    @Test("stop fires exactly at the limit")
    func stopFiresAtLimit() {
        let length = MaxRecordingLength.oneHour
        let effect = length.effect(elapsedSeconds: length.seconds, warningAlreadyShown: true)
        #expect(effect == .stopForMaxLength)
    }

    @Test("stop takes priority over warning once both thresholds are passed")
    func stopTakesPriorityOverWarning() {
        let length = MaxRecordingLength.thirtyMinutes
        let effect = length.effect(elapsedSeconds: length.seconds + 5, warningAlreadyShown: false)
        #expect(effect == .stopForMaxLength)
    }
}

/// Covers `MeetingApp.matching(bundleID:)` — the one piece of logic mapping raw bundle ids
/// (Core Audio's `kAudioProcessPropertyBundleID`) to a recognized app.
@Suite("Meeting app bundle id matching")
struct MeetingAppTests {
    @Test("Browser meeting titles identify the service without treating ordinary tabs as calls")
    func browserMeetingTitles() {
        #expect(MeetingApp.browserMeeting(windowTitle: "Team sync - Google Meet") == .browserMeeting)
        #expect(MeetingApp.browserMeeting(windowTitle: "Meet - Project kickoff - Google Chrome") == .browserMeeting)
        #expect(MeetingApp.browserMeeting(windowTitle: "Planning | Microsoft Teams") == .teams)
        #expect(MeetingApp.browserMeeting(windowTitle: "Join Zoom Meeting - Google Chrome") == .zoom)
        #expect(MeetingApp.browserMeeting(windowTitle: "Project board - Google Chrome") == nil)
        #expect(MeetingApp.browserMeeting(windowTitle: "Zoom pricing - Google Chrome") == nil)
    }
    @Test("known bundle ids map to their app")
    func knownBundleIDs() {
        #expect(MeetingApp.matching(bundleID: "us.zoom.xos") == .zoom)
        #expect(MeetingApp.matching(bundleID: "com.microsoft.teams2") == .teams)
        #expect(MeetingApp.matching(bundleID: "com.apple.FaceTime") == .faceTime)
        #expect(MeetingApp.matching(bundleID: "com.tinyspeck.slackmacgap") == .slackHuddle)
        #expect(MeetingApp.matching(bundleID: "com.hnc.Discord") == .discord)
    }

    @Test("common desktop browsers map to browserMeeting")
    func browsersMapToBrowserMeeting() {
        #expect(MeetingApp.matching(bundleID: "com.google.Chrome") == .browserMeeting)
        #expect(MeetingApp.matching(bundleID: "com.apple.Safari") == .browserMeeting)
        #expect(MeetingApp.matching(bundleID: "org.mozilla.firefox") == .browserMeeting)
    }

    @Test("unknown bundle ids match nothing")
    func unknownBundleIDsMatchNothing() {
        #expect(MeetingApp.matching(bundleID: "com.example.NotACallApp") == nil)
    }

    @Test("bundle id matching is case-insensitive")
    func caseInsensitiveMatching() {
        #expect(MeetingApp.matching(bundleID: "US.ZOOM.XOS") == .zoom)
    }

    @Test("every app has a non-empty display name")
    func everyAppHasDisplayName() {
        for app in MeetingApp.allCases {
            #expect(!app.displayName.isEmpty)
        }
    }
}

@Suite("FeatureFlags.meetingAppIntegration", .serialized)
struct MeetingAppIntegrationFlagTests {
    @Test("Browser-title integration defaults on and a stored false turns it off")
    func defaultsOnWithKillSwitch() {
        let suite = "meeting-app-flags-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = FeatureFlags.source
        FeatureFlags.source = defaults
        defer {
            FeatureFlags.source = previous
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(FeatureFlags.meetingAppIntegration)
        defaults.set(false, forKey: FeatureFlags.meetingAppIntegrationKey)
        #expect(!FeatureFlags.meetingAppIntegration)
    }
}
