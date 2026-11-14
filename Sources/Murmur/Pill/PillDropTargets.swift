import AppKit
import MurmurCore
import Observation
import SwiftUI

/// One display as the pill's drag sees it (injectable, so the headless harness can drag on a
/// display parked far off every real screen).
struct PillDisplay: Equatable {
    var id: UInt32?
    var frame: CGRect
    var visible: CGRect
    var topLimit: CGFloat

    @MainActor
    static func of(_ screen: NSScreen) -> PillDisplay {
        PillDisplay(id: PillPanel.id(of: screen), frame: screen.frame, visible: screen.visibleFrame,
                    topLimit: PillPanel.topLimit(of: screen))
    }
}

/// Everything the pill's panel reads from the Mac: displays, pointer, where anchors are saved,
/// the mouse button, and how long a drag may go without an event. `.live` in the app; the headless
/// harness injects a display parked off every real screen and throwaway defaults at init, so a
/// test never reads or writes `.standard` or places a window on a real display.
struct PillPanelEnvironment {
    var displays: @MainActor () -> [PillDisplay]
    var pointerLocation: @MainActor () -> NSPoint
    var anchorDefaults: UserDefaults
    var isMouseButtonDown: @MainActor () -> Bool
    /// A drag with no event for this long ends (button up) — the drop spots never linger.
    var dragIdleTimeout: TimeInterval
    /// Where "Hushy resigned active" and "another app became active" arrive, which cancel a drag. The app's own
    /// centres when live; a test gives its own, so a real app switch on the Mac (or another test's notification)
    /// cannot end a drag it is in the middle of.
    var notificationCenter: NotificationCenter
    var workspaceNotificationCenter: NotificationCenter
    /// Whether the panel may ever hold the keyboard (only while a name's spelling is corrected).
    /// The app's panel may; a test's never does, so a test run cannot take the keyboard of
    /// whoever is using the Mac.
    var allowsKeyboard = false

    @MainActor
    static var live: PillPanelEnvironment {
        PillPanelEnvironment(
            displays: { NSScreen.screens.map(PillDisplay.of) },
            pointerLocation: { NSEvent.mouseLocation },
            anchorDefaults: .standard,
            isMouseButtonDown: { NSEvent.pressedMouseButtons & 1 != 0 },
            dragIdleTimeout: 2,
            notificationCenter: .default,
            workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
            allowsKeyboard: true)
    }
}

/// What the drop-spot overlay draws: the four edge-centre targets (view points in the overlay,
/// which covers the whole display) and the one a release would snap to.
@MainActor
@Observable
final class PillDropTargetsModel {
    var targets: [PillAnchor: CGRect] = [:]
    var highlighted: PillAnchor?
    var isShown = false

    /// Targets for `display`, highlighting the one nearest `pointer` (the same rule the release
    /// snaps by).
    func update(display: PillDisplay, pointer: CGPoint) {
        var next: [PillAnchor: CGRect] = [:]
        for anchor in PillAnchor.allCases {
            let rect = PillGeometry.dropTarget(for: anchor, in: display.visible, topLimit: display.topLimit)
            next[anchor] = PillGeometry.viewRect(rect, inDisplay: display.frame)
        }
        if next != targets { targets = next }
        let nearest = PillGeometry.nearestAnchor(to: pointer, in: display.visible, topLimit: display.topLimit)
        if nearest != highlighted { highlighted = nearest }
    }
}

/// The soft grey drop spots: capsule-shaped placeholders in neutral grey (not purple or lime — this
/// is a place, not a signal), the nearest brighter and slightly larger. Fades in and out; under
/// Reduce Motion no scale, just the fade.
struct PillDropTargetsView: View {
    let model: PillDropTargetsModel
    var motion = PillMotion.standard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(PillAnchor.allCases, id: \.self) { anchor in
                if let rect = model.targets[anchor] {
                    target(isNearest: model.highlighted == anchor)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .opacity(model.isShown ? 1 : 0)
        .animation(motion.animation(.fade), value: model.isShown)
        .animation(reduceMotion ? nil : motion.animation(.morph), value: model.highlighted)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func target(isNearest: Bool) -> some View {
        Capsule()
            .fill(Color(white: 0.55).opacity(isNearest ? 0.5 : 0.28))
            .overlay(Capsule().strokeBorder(Color(white: isNearest ? 0.85 : 0.6).opacity(isNearest ? 0.8 : 0.5),
                                            lineWidth: 0.75))
            .scaleEffect(isNearest && !reduceMotion ? 1.12 : 1)
    }
}

/// The drop-spot overlay for one display: a click-through, non-activating panel above normal
/// windows and just below the pill, created when a drag starts and closed after the drop. It
/// follows the display under the pointer, so only that display shows targets.
@MainActor
final class PillDropTargetsOverlay {
    let panel: NSPanel
    let model = PillDropTargetsModel()
    private var display: PillDisplay?

    init(pillLevel: NSWindow.Level) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: pillLevel.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PillDropTargetsView(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    /// Shows (or moves) the targets on `display`, highlighting the one nearest `pointer`.
    func update(display: PillDisplay, pointer: CGPoint) {
        if display != self.display {
            self.display = display
            panel.setFrame(display.frame, display: true)
        }
        model.update(display: display, pointer: pointer)
        if !model.isShown {
            panel.orderFrontRegardless()
            model.isShown = true
        }
    }

    /// Fades the targets out, then closes the panel.
    func dismiss() {
        model.isShown = false
        let panel = panel
        // A run-loop timer (not a Task): it closes the panel even while a nested run loop spins.
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.close()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
