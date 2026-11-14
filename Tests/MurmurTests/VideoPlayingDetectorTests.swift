import AppKit
import Testing
@testable import Murmur

@Suite("Video playing — display-sleep assertions")
struct VideoPlayingDetectorTests {
    private let hushy: Int32 = 4242

    @Test("a display-sleep assertion from another app means video is playing")
    func otherAppAssertion() {
        let assertions = [PowerAssertion(pid: 100, type: "PreventUserIdleDisplaySleep")]
        #expect(VideoPlayingGeometry.isVideoPlaying(assertions: assertions, excludingPID: hushy))
    }

    @Test("Hushy's own assertion is ignored")
    func ownAssertionIgnored() {
        let assertions = [PowerAssertion(pid: hushy, type: "PreventUserIdleDisplaySleep")]
        #expect(!VideoPlayingGeometry.isVideoPlaying(assertions: assertions, excludingPID: hushy))
    }

    @Test("unrelated assertion types do not count")
    func unrelatedType() {
        let assertions = [PowerAssertion(pid: 100, type: "PreventUserIdleSystemSleep")]
        #expect(!VideoPlayingGeometry.isVideoPlaying(assertions: assertions, excludingPID: hushy))
    }

    @Test("what a real idle Mac holds does not count: powerd's internal assertion, a generic Electron one, caffeinate")
    func idleMacAssertions() {
        let assertions = [
            PowerAssertion(pid: 356, type: "InternalPreventDisplaySleep", name: "com.apple.powermanagement.delayDisplaySleep"),
            PowerAssertion(pid: 752, type: "NoDisplaySleepAssertion", name: "Electron"),
            PowerAssertion(pid: 900, type: "PreventUserIdleDisplaySleep", name: "caffeinate command-line tool"),
        ]
        #expect(!VideoPlayingGeometry.isVideoPlaying(assertions: assertions, excludingPID: hushy))
    }

    @Test("a named playback assertion from another app counts")
    func namedPlayback() {
        let assertions = [PowerAssertion(pid: 100, type: "NoDisplaySleepAssertion", name: "Video Wake Lock")]
        #expect(VideoPlayingGeometry.isVideoPlaying(assertions: assertions, excludingPID: hushy))
    }

    @Test("the not-playback name filter ignores case")
    func nameFilterIgnoresCase() {
        let assertions = [PowerAssertion(pid: 100, type: "NoDisplaySleepAssertion", name: "ELECTRON")]
        #expect(!VideoPlayingGeometry.isVideoPlaying(assertions: assertions, excludingPID: hushy))
    }

    @Test("one real playback assertion counts even beside ignored keep-awake holders")
    func playbackAmongNoise() {
        let assertions = [
            PowerAssertion(pid: 752, type: "NoDisplaySleepAssertion", name: "Electron"),
            PowerAssertion(pid: 900, type: "PreventUserIdleDisplaySleep", name: "caffeinate command-line tool"),
            PowerAssertion(pid: 310, type: "PreventUserIdleDisplaySleep", name: "Video Wake Lock"),
        ]
        #expect(VideoPlayingGeometry.isVideoPlaying(assertions: assertions, excludingPID: hushy))
    }

    @Test("no assertions means no video")
    func empty() {
        #expect(!VideoPlayingGeometry.isVideoPlaying(assertions: [], excludingPID: hushy))
    }
}

@Suite("Pill — idle hides during video")
@MainActor
struct PillVideoDistractionTests {
    @Test("the idle pill hides while video plays and returns when it stops")
    func modelVideo() {
        let pill = PillModel()
        pill.showWhenIdle = true
        #expect(pill.isVisible)
        pill.videoPlaying = true
        #expect(!pill.isVisible)
        pill.videoPlaying = false
        #expect(pill.isVisible)
    }

    @Test("fn still shows the listening pill while video plays")
    func modelShowsActiveDuringVideo() {
        let pill = PillModel()
        pill.videoPlaying = true
        pill.state = .listening
        #expect(pill.isVisible)
        pill.state = .idle
        #expect(!pill.isVisible)
    }

    @Test("the hide-during-video setting off keeps the idle pill visible")
    func settingOff() {
        let pill = PillModel()
        pill.hideIdleDuringVideoOrFullScreen = false
        pill.videoPlaying = true
        pill.fullScreenDisplayIDs = [1]
        pill.displayID = 1
        #expect(pill.isVisible)
    }

    private final class Fake {
        var snapshot = PillDistraction()
        var calls = 0
    }

    @Test("the watcher forwards video and full-screen fields together")
    func watcherCombined() {
        let fake = Fake()
        fake.snapshot = PillDistraction(fullScreenDisplayIDs: [1], videoPlaying: true)
        let pill = PillModel()
        let watcher = PillDistractionWatcher(
            detector: PillDistractionDetector {
                fake.calls += 1
                return fake.snapshot
            },
            notifications: NotificationCenter(),
            settleDelay: nil,
            pollInterval: nil
        ) { snapshot in
            pill.fullScreenDisplayIDs = snapshot.fullScreenDisplayIDs
            pill.videoPlaying = snapshot.videoPlaying
        }
        watcher.start()
        #expect(pill.fullScreenDisplayIDs == [1])
        #expect(pill.videoPlaying)
        #expect(fake.calls == 1)
    }

    @Test("every active state shows over a video, and the idle pill hides again afterwards")
    func activeStatesOverVideo() {
        let pill = PillModel()
        pill.videoPlaying = true
        for state: PillState in [.listening, .handsFree(startedAt: Date()), .processing(),
                                 .done(words: 3, usedContext: false), .error("x")] {
            pill.state = state
            #expect(pill.isVisible, "\(state) must show while a video plays")
        }
        pill.state = .idle
        #expect(!pill.isVisible)
    }

    @Test("a call banner shows over a video even while idle")
    func bannerOverVideo() {
        let pill = PillModel()
        pill.videoPlaying = true
        pill.banner = .stopCountdown(fireAt: Date().addingTimeInterval(5))
        #expect(pill.isVisible)
    }

    @Test("turning the setting off brings an idle pill back at once, turning it on hides it again")
    func settingTogglesLive() {
        let pill = PillModel()
        pill.videoPlaying = true
        #expect(!pill.isVisible)
        pill.hideIdleDuringVideoOrFullScreen = false
        #expect(pill.isVisible)
        pill.hideIdleDuringVideoOrFullScreen = true
        #expect(!pill.isVisible)
    }

    @Test("show-when-idle off keeps the idle pill hidden whatever the video does")
    func hiddenPresenceStaysHidden() {
        let pill = PillModel()
        pill.showWhenIdle = false
        pill.hideIdleDuringVideoOrFullScreen = false
        #expect(!pill.isVisible)
    }

    @Test("the watcher re-reads when a power assertion is created or released")
    func watcherFollowsAssertions() {
        let fake = Fake()
        let center = NotificationCenter()
        let pill = PillModel()
        let watcher = PillDistractionWatcher(
            detector: PillDistractionDetector { fake.snapshot },
            notifications: center, settleDelay: nil, pollInterval: nil
        ) { pill.videoPlaying = $0.videoPlaying }
        watcher.start()
        #expect(!pill.videoPlaying)
        fake.snapshot = PillDistraction(videoPlaying: true)
        center.post(name: .powerAssertionsChanged, object: nil)
        #expect(pill.videoPlaying && !pill.isVisible)
        fake.snapshot = PillDistraction()
        center.post(name: .powerAssertionsChanged, object: nil)
        #expect(!pill.videoPlaying && pill.isVisible)
    }

    @Test("a stopped watcher no longer follows power assertions")
    func stoppedWatcherIgnoresAssertions() {
        let fake = Fake()
        let center = NotificationCenter()
        var changes = 0
        let watcher = PillDistractionWatcher(
            detector: PillDistractionDetector { fake.snapshot },
            notifications: center, settleDelay: nil, pollInterval: nil
        ) { _ in changes += 1 }
        watcher.start()
        watcher.stop()
        fake.snapshot = PillDistraction(videoPlaying: true)
        center.post(name: .powerAssertionsChanged, object: nil)
        #expect(changes == 1)
    }

    @Test("the polling loop only runs while the idle pill could show")
    func pollingPolicy() async throws {
        let fake = Fake()
        var active = false
        let watcher = PillDistractionWatcher(
            detector: PillDistractionDetector { fake.calls += 1; return fake.snapshot },
            notifications: NotificationCenter(), settleDelay: nil, pollInterval: .milliseconds(20),
            shouldPoll: { active }
        ) { _ in }
        watcher.start()
        try await Task.sleep(for: .milliseconds(120))
        #expect(fake.calls == 1, "no timer while the pill cannot show")
        active = true
        watcher.refreshPollingPolicy()
        fake.snapshot = PillDistraction(videoPlaying: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.calls > 1, "the timer starts once the pill could show")
        watcher.stop()
    }
}
