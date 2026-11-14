import AppKit
import CoreGraphics

// The idle pill steps aside while the frontmost app is full screen (founder decision 2026-10-04):
// a film, a keynote or a game should not carry a floating capsule. Any non-idle state shows as
// normal, so a dictation started over a full-screen app still has its pill.
//
// Method: the passive window list (`CGWindowListCopyWindowInfo`, on-screen windows), reading only
// each window's owner PID, layer and bounds. Window names are never read, so this needs no Screen
// Recording permission and shows no prompt. A display is "full screen" when the frontmost app has
// an ordinary window covering all of it and the system menu bar is not on it: macOS hides the
// menu bar in a full-screen Space, and on a notch Mac the full-screen window starts below the
// notch (y = 33), which is why the test is "no menu-bar window" and not "window starts at y = 0".

/// A display as `CGDisplayBounds` sees it (global coordinates, top-left origin).
struct FullScreenDisplay: Equatable, Sendable {
    let id: UInt32
    let bounds: CGRect
}

/// One on-screen window from the window list.
struct FullScreenWindow: Equatable, Sendable {
    let pid: Int32
    let layer: Int
    let bounds: CGRect
}

/// The pure rule, tested on window samples.
enum FullScreenGeometry {
    /// `kCGMainMenuWindowLevel`: the system menu bar's window layer.
    static let menuBarLayer = 24
    /// Ordinary app windows live on layer 0; floating panels, status items and overlays do not.
    static let appWindowLayer = 0
    /// How far below a display's top edge a full-screen window may start: the notch strip.
    private static let topSlack: CGFloat = 40
    /// Rounding between window bounds and display bounds.
    private static let edgeSlack: CGFloat = 1

    static func fullScreenDisplays(
        frontPID: Int32, windows: [FullScreenWindow], displays: [FullScreenDisplay]
    ) -> Set<UInt32> {
        let mine = windows.filter { $0.pid == frontPID && $0.layer == appWindowLayer }
        let menuBars = windows.filter { $0.layer == menuBarLayer }
        let full = displays.filter { display in
            let probe = display.bounds.insetBy(dx: 1, dy: 1)
            let hasMenuBar = menuBars.contains { $0.bounds.intersects(probe) }
            return !hasMenuBar && mine.contains { covers($0.bounds, display.bounds) }
        }
        return Set(full.map(\.id))
    }

    private static func covers(_ window: CGRect, _ display: CGRect) -> Bool {
        window.minX <= display.minX + edgeSlack && window.maxX >= display.maxX - edgeSlack
            && window.maxY >= display.maxY - edgeSlack && window.minY <= display.minY + topSlack
    }
}

/// Reads which displays have a full-screen frontmost app. Injected, so tests fake it.
struct FullScreenDetector {
    let fullScreenDisplayIDs: @MainActor () -> Set<UInt32>

    /// The real Mac: the frontmost app's PID, the on-screen windows and the active displays.
    static let live = FullScreenDetector { LiveWindowList.fullScreenDisplays() }
    /// For tests and previews that must never see full screen.
    static let never = FullScreenDetector { [] }
}

/// Why the idle pill may step aside: full screen on a display and/or display-sleep assertions.
struct PillDistraction: Equatable, Sendable {
    var fullScreenDisplayIDs: Set<UInt32> = []
    var videoPlaying = false
}

/// Full-screen geometry plus video/call playback assertions. Injected for tests.
struct PillDistractionDetector {
    let snapshot: @MainActor () -> PillDistraction

    static func live(
        fullScreen: FullScreenDetector = .live,
        video: VideoPlayingDetector = .live()
    ) -> PillDistractionDetector {
        PillDistractionDetector {
            PillDistraction(
                fullScreenDisplayIDs: fullScreen.fullScreenDisplayIDs(),
                videoPlaying: video.isVideoPlaying())
        }
    }

    static let never = PillDistractionDetector { PillDistraction() }
}

@MainActor
private enum LiveWindowList {
    static func fullScreenDisplays() -> Set<UInt32> {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return [] }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return FullScreenGeometry.fullScreenDisplays(
            frontPID: pid, windows: info.compactMap(window(from:)), displays: activeDisplays())
    }

    private static func window(from info: [String: Any]) -> FullScreenWindow? {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let layer = info[kCGWindowLayer as String] as? Int,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        else { return nil }
        return FullScreenWindow(pid: pid, layer: layer, bounds: bounds)
    }

    private static func activeDisplays() -> [FullScreenDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { FullScreenDisplay(id: $0, bounds: CGDisplayBounds($0)) }
    }
}

/// Re-reads `PillDistractionDetector` when something that can change the answer happens, and on a
/// slow timer only while the idle pill could show (`shouldPoll`). Full-screen transitions also get
/// a settle re-read after `settleDelay`.
@MainActor
final class PillDistractionWatcher {
    private let detector: PillDistractionDetector
    private let notifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private let settleDelay: Duration?
    private let pollInterval: Duration?
    private let shouldPoll: @MainActor () -> Bool
    private let onChange: @MainActor (PillDistraction) -> Void
    private var last: PillDistraction?
    private var observers: [any NSObjectProtocol] = []
    private var settleTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    /// `workspaceNotifications` is where `NSWorkspace` posts its notifications; tests pass one
    /// center for everything.
    init(
        detector: PillDistractionDetector,
        notifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter? = nil,
        settleDelay: Duration? = .milliseconds(700),
        pollInterval: Duration? = .seconds(5),
        shouldPoll: @escaping @MainActor () -> Bool = { true },
        onChange: @escaping @MainActor (PillDistraction) -> Void
    ) {
        self.detector = detector
        self.notifications = notifications
        self.workspaceNotifications = workspaceNotifications ?? notifications
        self.settleDelay = settleDelay
        self.pollInterval = pollInterval
        self.shouldPoll = shouldPoll
        self.onChange = onChange
    }

    func start() {
        guard observers.isEmpty else { return }
        refresh()
        observe(NSWorkspace.activeSpaceDidChangeNotification, on: workspaceNotifications)
        observe(NSWorkspace.didActivateApplicationNotification, on: workspaceNotifications)
        observe(NSApplication.didChangeScreenParametersNotification, on: notifications)
        observe(.powerAssertionsChanged, on: notifications)
        restartPollLoop()
    }

    func stop() {
        settleTask?.cancel()
        settleTask = nil
        pollTask?.cancel()
        pollTask = nil
        for observer in observers {
            notifications.removeObserver(observer)
            workspaceNotifications.removeObserver(observer)
        }
        observers = []
    }

    /// Call when `shouldPoll`'s inputs change (pill presence or the hide-during-video setting).
    func refreshPollingPolicy() {
        restartPollLoop()
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.triggered() }
        }
        observers.append(token)
    }

    private func triggered() {
        refresh()
        guard let delay = settleDelay else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func restartPollLoop() {
        pollTask?.cancel()
        pollTask = nil
        guard let interval = pollInterval, shouldPoll() else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if self.shouldPoll() { self.refresh() }
                    else { self.restartPollLoop() }
                }
            }
        }
    }

    private func refresh() {
        let snapshot = detector.snapshot()
        guard snapshot != last else { return }
        last = snapshot
        onChange(snapshot)
    }
}

/// Tests that only exercise full-screen geometry keep using this name.
typealias FullScreenWatcher = PillDistractionWatcher

extension PillDistractionWatcher {
    /// Full-screen-only tests pass a fake window list and read display ids from the snapshot.
    convenience init(
        detector: FullScreenDetector,
        notifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter? = nil,
        settleDelay: Duration? = .milliseconds(700),
        pollInterval: Duration? = nil,
        onChange: @escaping @MainActor (Set<UInt32>) -> Void
    ) {
        self.init(
            detector: PillDistractionDetector {
                PillDistraction(fullScreenDisplayIDs: detector.fullScreenDisplayIDs())
            },
            notifications: notifications,
            workspaceNotifications: workspaceNotifications,
            settleDelay: settleDelay,
            pollInterval: pollInterval,
            onChange: { onChange($0.fullScreenDisplayIDs) })
    }
}
