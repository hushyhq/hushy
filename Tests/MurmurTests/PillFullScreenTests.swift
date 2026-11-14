import AppKit
import Testing
@testable import Murmur

/// The idle pill steps aside while the frontmost app is full screen (founder decision 2026-10-04).
/// The geometry rule is pure and tested on window samples; the watcher and the model are tested
/// with a fake detector — nothing here reads the real window list.
@Suite("Pill — idle hides in full screen")
@MainActor
struct PillFullScreenTests {
    private static let display = FullScreenDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
    private static let menuBar = FullScreenWindow(
        pid: 408, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33))

    private func window(_ pid: Int32, _ bounds: CGRect, layer: Int = 0) -> FullScreenWindow {
        FullScreenWindow(pid: pid, layer: layer, bounds: bounds)
    }

    private func fullScreen(_ windows: [FullScreenWindow], front pid: Int32 = 100) -> Set<UInt32> {
        FullScreenGeometry.fullScreenDisplays(frontPID: pid, windows: windows, displays: [Self.display])
    }

    // MARK: Geometry

    @Test("a window covering the whole display is full screen")
    func coversDisplay() {
        let all = window(100, CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(fullScreen([all]) == [1])
    }

    @Test("a notch Mac's full-screen window starts under the notch and has no menu bar")
    func belowNotchNoMenuBar() {
        let below = window(100, CGRect(x: 0, y: 33, width: 1512, height: 949))
        #expect(fullScreen([below]) == [1])
    }

    @Test("a maximised window under a visible menu bar is not full screen")
    func zoomedWithMenuBar() {
        let zoomed = window(100, CGRect(x: 0, y: 33, width: 1512, height: 949))
        #expect(fullScreen([Self.menuBar, zoomed]).isEmpty)
    }

    @Test("an ordinary window is not full screen")
    func ordinaryWindow() {
        #expect(fullScreen([Self.menuBar, window(100, CGRect(x: 96, y: 53, width: 1320, height: 847))]).isEmpty)
    }

    @Test("only the frontmost app's windows count")
    func otherAppsIgnored() {
        let theirs = window(200, CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(fullScreen([theirs], front: 100).isEmpty)
    }

    @Test("floating windows (menu bar, status items, overlays) are never the full-screen window")
    func nonStandardLayersIgnored() {
        let overlay = window(100, CGRect(x: 0, y: 0, width: 1512, height: 982), layer: 25)
        #expect(fullScreen([overlay]).isEmpty)
    }

    @Test("full screen is reported per display, so the other display keeps its pill")
    func perDisplay() {
        let second = FullScreenDisplay(id: 2, bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        let video = window(100, CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        let result = FullScreenGeometry.fullScreenDisplays(
            frontPID: 100, windows: [Self.menuBar, video], displays: [Self.display, second])
        #expect(result == [2])
    }

    // MARK: Model

    @Test("the idle pill is hidden on a full-screen display and shown elsewhere")
    func modelHidesIdle() {
        let pill = PillModel()
        pill.showWhenIdle = true
        pill.displayID = 1
        #expect(pill.isVisible)
        pill.fullScreenDisplayIDs = [1]
        #expect(!pill.isVisible)
        pill.fullScreenDisplayIDs = [2]
        #expect(pill.isVisible)
    }

    @Test("any non-idle state shows as normal over a full-screen app")
    func modelShowsActiveStates() {
        let pill = PillModel()
        pill.displayID = 1
        pill.fullScreenDisplayIDs = [1]
        for state: PillState in [.listening, .handsFree(startedAt: Date()), .processing(), .done(words: 3, usedContext: false),
                                 .error("x")] {
            pill.state = state
            #expect(pill.isVisible, "\(state) must show in full screen")
        }
        pill.state = .idle
        #expect(!pill.isVisible, "and the idle pill goes again afterwards")
    }

    @Test("the pill returns when full screen ends")
    func modelReturns() {
        let pill = PillModel()
        pill.displayID = 1
        pill.fullScreenDisplayIDs = [1]
        pill.fullScreenDisplayIDs = []
        #expect(pill.isVisible)
    }

    @Test("the show-when-idle setting still hides the idle pill when off")
    func settingRespected() {
        let pill = PillModel()
        pill.showWhenIdle = false
        #expect(!pill.isVisible)
        pill.state = .listening
        #expect(pill.isVisible)
    }

    // MARK: Watcher

    private final class Fake {
        var result: Set<UInt32> = []
        var calls = 0
    }

    private func makeWatcher(_ fake: Fake, center: NotificationCenter, into pill: PillModel) -> FullScreenWatcher {
        FullScreenWatcher(
            detector: FullScreenDetector { fake.calls += 1; return fake.result },
            notifications: center, settleDelay: nil,
            onChange: { pill.fullScreenDisplayIDs = $0 })
    }

    @Test("starting the watcher reads the current state once")
    func watcherReadsAtStart() {
        let fake = Fake(); fake.result = [1]
        let pill = PillModel()
        let watcher = makeWatcher(fake, center: NotificationCenter(), into: pill)
        watcher.start()
        #expect(pill.fullScreenDisplayIDs == [1])
        #expect(fake.calls == 1)
    }

    @Test("a space change or a frontmost-app change re-reads the detector")
    func watcherFollowsTriggers() {
        let fake = Fake()
        let center = NotificationCenter()
        let pill = PillModel()
        let watcher = makeWatcher(fake, center: center, into: pill)
        watcher.start()
        fake.result = [1]
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        #expect(pill.fullScreenDisplayIDs == [1])
        fake.result = []
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(pill.fullScreenDisplayIDs.isEmpty)
        fake.result = [1]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(pill.fullScreenDisplayIDs == [1])
    }

    @Test("an unchanged answer does not call back")
    func watcherQuietWhenUnchanged() {
        let fake = Fake(); fake.result = [1]
        let center = NotificationCenter()
        var changes = 0
        let watcher = FullScreenWatcher(
            detector: FullScreenDetector { fake.result }, notifications: center, settleDelay: nil,
            onChange: { _ in changes += 1 })
        watcher.start()
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        #expect(changes == 1)
    }
}
