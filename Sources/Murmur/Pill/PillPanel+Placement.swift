import AppKit
import MurmurCore
import SwiftUI

/// Where the pill rests: the centre of one of a display's four edges, saved per display
/// (DECISIONS 2026-09-28 "Pill rests at an edge centre"). Dragging carries it anywhere while grey
/// drop spots mark the four edge centres; on release it snaps to the nearest one.
extension PillPanel {
    /// Places the pill at its display's saved anchor: the display it was last dropped on if
    /// that's connected, else the one with the pointer (the default follows the pointer).
    func reposition() {
        guard let display = homeDisplay() else { return }
        let anchor = display.id.map(prefs.anchor(forScreen:)) ?? .bottom
        if model.anchor != anchor { model.anchor = anchor }
        if model.displayID != display.id { model.displayID = display.id }
        setFrame(PillGeometry.frame(for: anchor, size: layoutSize, in: display.visible, topLimit: display.topLimit),
                 display: true)
        updateMouseGate()
    }

    // MARK: Dragging

    /// The pill follows the cursor, kept on the display under it, while grey drop spots show
    /// the four edge centres of that display and highlight where a release would land.
    func dragChanged() {
        let mouse = pointerLocation()
        if dragStart == nil { dragStart = (mouse, frame.origin) }
        guard let start = dragStart, let display = displayAt(mouse) else { return }
        let moved = CGRect(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y,
                           width: frame.width, height: frame.height)
        setFrame(PillGeometry.frame(anchor: CGPoint(x: moved.midX, y: moved.minY), size: moved.size, in: display.visible),
                 display: true)
        showDropTargets(at: mouse)
        armDragIdleTimer()
        // The carried pill is its plain resting capsule, turned for the edge it's nearing.
        let nearing = PillGeometry.nearestAnchor(to: mouse, in: display.visible, topLimit: display.topLimit)
        if !model.isDragging { model.isDragging = true }
        if model.dragAnchor != nearing {
            withAnimation(reduceMotion ? nil : model.motion.animation(.morph)) { model.dragAnchor = nearing }
        }
    }

    /// Snaps to the nearest edge centre of the display under the pointer and saves it for that
    /// display — with a short animation (the pill morphs between horizontal and vertical), or none
    /// under Reduce Motion. Idempotent: a late SwiftUI onEnded after the mouse-up is a no-op.
    func dragEnded() {
        guard dragStart != nil else { return }
        let mouse = pointerLocation()
        dragStart = nil
        stopDragIdleTimer()
        hideDropTargets()
        model.isDragging = false
        model.dragAnchor = nil
        guard let display = displayAt(mouse), let id = display.id else { return reposition() }
        let anchor = PillGeometry.nearestAnchor(to: mouse, in: display.visible, topLimit: display.topLimit)
        prefs.set(anchor, forScreen: id)
        PillAnchorStore.save(prefs, to: anchorDefaults)
        withAnimation(reduceMotion ? nil : model.motion.animation(.morph)) { model.anchor = anchor }
        let target = PillGeometry.frame(for: anchor, size: layoutSize, in: display.visible, topLimit: display.topLimit)
        if reduceMotion {
            setFrame(target, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = model.motion.snapSeconds
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(target, display: true)
            }
        }
        updateMouseGate()
    }

    /// "Reset position": every display back to bottom-centre, following the pointer.
    func resetPosition() {
        prefs = PillAnchorPrefs()
        PillAnchorStore.save(prefs, to: anchorDefaults)
        reposition()
    }

    // MARK: Screens

    /// Below the menu bar and the notch, even in a full-screen Space.
    static func topLimit(of screen: NSScreen) -> CGFloat {
        PillGeometry.topLimit(screenFrame: screen.frame, visible: screen.visibleFrame,
                              safeAreaTop: screen.safeAreaInsets.top)
    }

    /// The display the pill was last dropped on if it's connected, else the one with the pointer.
    private func homeDisplay() -> PillDisplay? {
        let saved = prefs.screenID.flatMap { id in environment.displays().first { $0.id == id } }
        return saved ?? displayAt(pointerLocation())
    }

    static func id(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// The saved anchors in UserDefaults, and the one-time migration from the free-form position
/// the pill had before 2026-09-28 (`pillPlacement` → nearest anchor on that display).
enum PillAnchorStore {
    static let key = "pillAnchors"
    static let legacyKey = "pillPlacement"

    static func load(from defaults: UserDefaults) -> PillAnchorPrefs {
        if let data = defaults.data(forKey: key), let prefs = try? JSONDecoder().decode(PillAnchorPrefs.self, from: data) {
            return prefs
        }
        guard let legacy = defaults.data(forKey: legacyKey) else { return PillAnchorPrefs() }
        defaults.removeObject(forKey: legacyKey)
        guard let placement = try? JSONDecoder().decode(PillPlacement.self, from: legacy) else { return PillAnchorPrefs() }
        var prefs = PillAnchorPrefs()
        prefs.set(PillGeometry.migratedAnchor(from: placement), forScreen: placement.screenID)
        save(prefs, to: defaults)
        return prefs
    }

    static func save(_ prefs: PillAnchorPrefs, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        defaults.set(data, forKey: key)
    }
}
