import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Murmur

@MainActor
private final class RecordingPresenter: RivalKeyPresenting {
    private(set) var shown: [RivalKeyOffer] = []
    private(set) var dismissals = 0
    private(set) var switchKey: (() -> Void)?
    private(set) var keepKey: (() -> Void)?

    func present(_ offer: RivalKeyOffer, switchKey: @escaping () -> Void, keepKey: @escaping () -> Void) {
        shown.append(offer)
        self.switchKey = switchKey
        self.keepKey = keepKey
    }

    func dismiss() { dismissals += 1 }
}

/// The notice and the one-click key change, with a throwaway defaults suite, a fake list of running
/// apps and a fake card. No real app is launched and no real preference is read or written.
@Suite("Shared dictation key: notice and switch")
@MainActor
struct RivalKeyCoordinatorTests {
    private let wispr = "com.electron.wispr-flow"
    private let granola = "com.granola.app"

    @MainActor private struct Rig {
        let settings: AppSettings
        let presenter = RecordingPresenter()
        let suite: String
    }

    private func makeRig(running: Set<String>, trigger: TriggerKey = .fn) -> (Rig, RivalKeyCoordinator, Box) {
        let suite = "hushy-test-rival-key-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.triggerKey = trigger
        let rig = Rig(settings: settings, suite: suite)
        let box = Box(running)
        let coordinator = RivalKeyCoordinator(settings: settings, presenter: rig.presenter, runningBundleIDs: { box.value })
        return (rig, coordinator, box)
    }

    @MainActor final class Box { var value: Set<String>; init(_ value: Set<String>) { self.value = value } }

    private func cleanup(_ rig: Rig) { UserDefaults(suiteName: rig.suite)?.removePersistentDomain(forName: rig.suite) }

    @Test("a rival already running when Hushy starts gets a notice")
    func noticeAtStart() {
        let (rig, coordinator, _) = makeRig(running: [wispr])
        defer { cleanup(rig) }
        coordinator.start(workspaceNotifications: NotificationCenter())
        #expect(rig.presenter.shown.count == 1)
        #expect(rig.presenter.shown.first?.rivals.map(\.id) == ["wispr-flow"])
        #expect(rig.presenter.shown.first?.suggested == .rightOption)
    }

    @Test("no notice when no rival runs or Hushy is on another key")
    func quiet() {
        let (rig, coordinator, _) = makeRig(running: ["com.apple.finder"])
        let (rig2, coordinator2, _) = makeRig(running: [wispr], trigger: .rightOption)
        defer { cleanup(rig); cleanup(rig2) }
        coordinator.start(workspaceNotifications: NotificationCenter())
        coordinator2.start(workspaceNotifications: NotificationCenter())
        #expect(rig.presenter.shown.isEmpty)
        #expect(rig2.presenter.shown.isEmpty)
    }

    @Test("a rival that launches later gets a notice, once")
    func noticeOnLaunch() {
        let (rig, coordinator, box) = makeRig(running: [])
        defer { cleanup(rig) }
        coordinator.start(workspaceNotifications: NotificationCenter())
        #expect(rig.presenter.shown.isEmpty)
        coordinator.appLaunched(bundleID: granola)
        coordinator.appLaunched(bundleID: granola)
        box.value = [granola]
        coordinator.appLaunched(bundleID: "com.apple.TextEdit")
        #expect(rig.presenter.shown.count == 1)
        #expect(rig.presenter.shown.first?.rivals.map(\.id) == ["granola"])
    }

    @Test("one click moves Hushy to the suggested key and closes the card")
    func switchesKey() {
        let (rig, coordinator, _) = makeRig(running: [wispr])
        defer { cleanup(rig) }
        coordinator.start(workspaceNotifications: NotificationCenter())
        rig.presenter.switchKey?()
        #expect(rig.settings.triggerKey == .rightOption)
        #expect(rig.presenter.dismissals == 1)
        #expect(coordinator.showing == nil)
        coordinator.appLaunched(bundleID: granola)
        #expect(rig.presenter.shown.count == 1)
    }

    @Test("the switch survives a restart: the stored key is the new one")
    func switchPersists() {
        let (rig, coordinator, _) = makeRig(running: [wispr])
        defer { cleanup(rig) }
        coordinator.start(workspaceNotifications: NotificationCenter())
        rig.presenter.switchKey?()
        let reopened = AppSettings(defaults: UserDefaults(suiteName: rig.suite)!)
        #expect(reopened.triggerKey == .rightOption)
    }

    @Test("keeping the key remembers the rival and leaves the key alone")
    func keepsKey() {
        let (rig, coordinator, box) = makeRig(running: [wispr])
        defer { cleanup(rig) }
        coordinator.start(workspaceNotifications: NotificationCenter())
        rig.presenter.keepKey?()
        #expect(rig.settings.triggerKey == .fn)
        #expect(rig.settings.keptSharedKeyWith == ["wispr-flow"])
        coordinator.appLaunched(bundleID: wispr)
        #expect(rig.presenter.shown.count == 1)
        box.value = [wispr, granola]
        coordinator.appLaunched(bundleID: granola)
        #expect(rig.presenter.shown.count == 2)
        #expect(rig.presenter.shown.last?.rivals.map(\.id) == ["granola"])
        let reopened = AppSettings(defaults: UserDefaults(suiteName: rig.suite)!)
        #expect(reopened.keptSharedKeyWith == ["wispr-flow"])
    }

    @Test("the card closes when the other app quits")
    func closesOnQuit() {
        let (rig, coordinator, box) = makeRig(running: [wispr])
        defer { cleanup(rig) }
        coordinator.start(workspaceNotifications: NotificationCenter())
        box.value = []
        coordinator.appQuit(bundleID: wispr)
        #expect(coordinator.showing == nil)
        #expect(rig.presenter.dismissals == 1)
    }

    @Test("a quit notice that arrives before the running list updates still closes the card")
    func quitBeforeListUpdates() {
        let (rig, coordinator, _) = makeRig(running: [wispr])
        defer { cleanup(rig) }
        coordinator.start(workspaceNotifications: NotificationCenter())
        coordinator.appQuit(bundleID: wispr)
        #expect(coordinator.showing == nil)
    }

    @Test("a key changed in Settings while the card is up makes the click a no-op that closes it")
    func staleCard() {
        let (rig, coordinator, _) = makeRig(running: [wispr])
        defer { cleanup(rig) }
        coordinator.start(workspaceNotifications: NotificationCenter())
        rig.settings.triggerKey = .controlOption
        rig.presenter.switchKey?()
        #expect(rig.settings.triggerKey == .controlOption)
        #expect(coordinator.showing == nil)
    }

    @Test("shipped words name no rival, and name them only behind the switch")
    func copyKeepsNamesOut() {
        let offer = RivalKeyOffer(
            rivals: RivalDictationApps.table.filter { ["wispr-flow", "granola"].contains($0.id) },
            current: .fn, suggested: .rightOption)
        #expect(!RivalKeyCopy.namesRivals)
        let shipped = [RivalKeyCopy.title(offer: offer), RivalKeyCopy.detail,
                       RivalKeyCopy.switchButton(offer: offer), RivalKeyCopy.keepButton(offer: offer)]
        for app in RivalDictationApps.table {
            for line in shipped { #expect(!line.localizedCaseInsensitiveContains(app.name)) }
        }
        for line in shipped { #expect(line.hasPrefix("[placeholder]")) }
        #expect(RivalKeyCopy.title(offer: offer, namesRivals: true).contains("Wispr Flow and Granola"))
    }

    @Test("after the switch fn starts no dictation and is left for the other app; Right Option starts one")
    func switchedKeyReachesTheTap() {
        let (rig, coordinator, _) = makeRig(running: [wispr])
        defer { cleanup(rig) }
        let monitor = HotkeyMonitor()
        var events: [HotkeyEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.trigger = rig.settings.triggerKey

        func press(_ code: Int, _ flags: CGEventFlags, at seconds: Double) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
            event.type = .flagsChanged
            event.flags = flags
            event.timestamp = CGEventTimestamp(seconds * 1_000_000_000)
            return monitor.handle(type: .flagsChanged, event: event)
        }

        #expect(press(kVK_Function, .maskSecondaryFn, at: 1))
        _ = press(kVK_Function, [], at: 2)
        #expect(events.first == .pressed, "on fn, Hushy starts and hides fn from macOS: the double-dictation setup")

        coordinator.start(workspaceNotifications: NotificationCenter())
        rig.presenter.switchKey?()
        monitor.trigger = rig.settings.triggerKey
        events.removeAll()

        #expect(!press(kVK_Function, .maskSecondaryFn, at: 10), "fn now passes through untouched")
        _ = press(kVK_Function, [], at: 11)
        #expect(events.isEmpty)
        _ = press(kVK_RightOption, .maskAlternate, at: 20)
        #expect(events == [.pressed])
        _ = press(kVK_RightOption, [], at: 21)
    }
}
