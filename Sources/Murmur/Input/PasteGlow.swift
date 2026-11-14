import AppKit
import ApplicationServices
import MurmurCore
import QuartzCore

/// Where the paste glow goes, as pure geometry so a test can hold the rules.
///
/// Accessibility reports frames in global coordinates with the origin at the top-left of the
/// primary display (the one with the menu bar); AppKit windows use the bottom-left. A frame that
/// cannot be a text field the person is looking at draws nothing: too small to see, off every
/// display, or so large it is the whole window or page (a web view that reports its document as
/// the focused element), where an outline would flash the screen rather than point at the field.
enum PasteGlowGeometry {
    /// The ring sits this far outside the field, so it frames the field instead of covering its edge.
    static let outset: CGFloat = 4
    static let minimumSide: CGFloat = 8
    /// Above this share of its display, the "field" is a window or page, not a field.
    static let maximumScreenShare: CGFloat = 0.6

    /// The glow window's frame in AppKit coordinates, or nil when nothing should be drawn.
    /// - Parameters:
    ///   - axFrame: the focused element's frame as Accessibility reports it.
    ///   - screens: every display's frame in AppKit coordinates, the primary display first.
    static func windowFrame(axFrame: CGRect, screens: [CGRect]) -> CGRect? {
        guard let primary = screens.first, axFrame.width >= minimumSide, axFrame.height >= minimumSide,
              axFrame.origin.x.isFinite, axFrame.origin.y.isFinite else { return nil }
        let flipped = CGRect(x: axFrame.minX, y: primary.maxY - axFrame.maxY, width: axFrame.width, height: axFrame.height)
        guard let screen = screens.max(by: { overlap($0, flipped) < overlap($1, flipped) }),
              overlap(screen, flipped) > 0 else { return nil }
        guard flipped.width * flipped.height <= screen.width * screen.height * maximumScreenShare else { return nil }
        return flipped.insetBy(dx: -outset, dy: -outset)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        return shared.isNull ? 0 : shared.width * shared.height
    }

    /// The ring's corner: a little rounder than the field's own, capped for tall text views.
    static func cornerRadius(for frame: CGRect) -> CGFloat {
        min(10, max(5, min(frame.width, frame.height) / 4))
    }
}

/// The wash's look, shared by the live layer and the snapshot still (`Snapshots+UXFeel`). A faint fill in the
/// model's blue, no outline (founder, 2026-10-28: "a faded highlight… a light glow, not very dark… the bluish
/// accent"; the lime ring was distracting).
enum PasteGlowStyle {
    static let lineWidth: CGFloat = 0
    /// How strong the wash is at its peak, on light and on dark backgrounds.
    static let fillAlphaLight: CGFloat = 0.10
    static let fillAlphaDark: CGFloat = 0.16
    static let haloOpacity: Float = 0.18
    static let haloStart: CGFloat = 6
    static let haloPeak: CGFloat = 12
}

/// The timing of one glow, in seconds. Together about 800 ms: in fast, hold, out slow.
enum PasteGlowTiming {
    static let fadeIn: Double = 0.14
    static let hold: Double = 0.16
    static let fadeOut: Double = 0.5
    static var total: Double { fadeIn + hold + fadeOut }
    /// After the paste, so the field has laid out the new text before its frame is read.
    static let delayAfterPaste: Double = 0.05
}

/// A faint blue wash over the field a dictation was just pasted into, so the eye lands on
/// the words. Shown only in Hushy's own windows, which in practice means the onboarding practice chat:
/// in other apps it distracted (founder, 2026-10-28: "remove the highlighting except during onboarding"). Borderless, click-through, never key or main, and joined to every Space; it is ordered
/// front without activating Hushy, so focus never leaves the app the person is typing in.
///
/// One panel is reused. Under Reduce Motion the ring fades in and out with no bloom (opacity only).
@MainActor
final class PasteGlow {
    static let shared = PasteGlow()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// Reads `field`'s frame (bounded, `AXBounds`) shortly after the paste and glows around it.
    /// Draws nothing when the frame cannot be read or fails `PasteGlowGeometry`.
    func show(around field: AXUIElement) {
        guard FeatureFlags.pasteGlow, Self.isOwnField(field) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + PasteGlowTiming.delayAfterPaste) { [weak self] in
            MainActor.assumeIsolated {
                guard let axFrame = Self.frame(of: field),
                      let frame = PasteGlowGeometry.windowFrame(axFrame: axFrame, screens: NSScreen.screens.map(\.frame))
                else { return }
                self?.glow(in: frame)
            }
        }
    }

    /// True when the field belongs to Hushy itself (the onboarding practice chat), never another app.
    static func isOwnField(_ field: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(field, &pid) == .success && pid == ProcessInfo.processInfo.processIdentifier
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        AXBounds.bounded(element) {
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            // The type IDs were checked just above, so these casts cannot fail.
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return CGRect(origin: origin, size: extent)
        }
    }

    private func glow(in frame: CGRect) {
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.setFrame(frame, display: false)
        let ring = Self.ring(in: panel)
        let bounds = CGRect(origin: .zero, size: frame.size).insetBy(dx: PasteGlowGeometry.outset / 2, dy: PasteGlowGeometry.outset / 2)
        ring.frame = bounds
        ring.cornerRadius = PasteGlowGeometry.cornerRadius(for: bounds)
        ring.backgroundColor = Self.accent.withAlphaComponent(Self.isDark ? PasteGlowStyle.fillAlphaDark : PasteGlowStyle.fillAlphaLight).cgColor
        ring.shadowColor = Self.accent.cgColor
        ring.removeAllAnimations()
        ring.opacity = 0
        ring.add(Self.fade(), forKey: "glow")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { ring.add(Self.bloom(), forKey: "bloom") }
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PasteGlowTiming.total + 0.05, execute: work)
    }

    private static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// The model's blue (`Theme.working`): #4A5AE6 on light, #8B97FF on dark, by the system appearance.
    private static var accent: NSColor {
        isDark ? NSColor(red: 0x8B / 255, green: 0x97 / 255, blue: 0xFF / 255, alpha: 1)
            : NSColor(red: 0x4A / 255, green: 0x5A / 255, blue: 0xE6 / 255, alpha: 1)
    }

    private static func fade() -> CAKeyframeAnimation {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        let total = PasteGlowTiming.total
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, PasteGlowTiming.fadeIn / total, (PasteGlowTiming.fadeIn + PasteGlowTiming.hold) / total, 1]
            .map { NSNumber(value: $0) }
        fade.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        fade.duration = total
        return fade
    }

    /// The soft halo grows a little as it fades: shadow radius only, no movement.
    private static func bloom() -> CABasicAnimation {
        let bloom = CABasicAnimation(keyPath: "shadowRadius")
        bloom.fromValue = PasteGlowStyle.haloStart
        bloom.toValue = PasteGlowStyle.haloPeak
        bloom.duration = PasteGlowTiming.total
        bloom.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return bloom
    }

    private static func makePanel() -> NSPanel {
        let panel = GlowPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }

    private static func ring(in panel: NSPanel) -> CALayer {
        guard let host = panel.contentView?.layer else { return CALayer() }
        if let ring = host.sublayers?.first { return ring }
        let ring = CALayer()
        ring.borderWidth = PasteGlowStyle.lineWidth
        ring.shadowOpacity = PasteGlowStyle.haloOpacity
        ring.shadowRadius = (PasteGlowStyle.haloStart + PasteGlowStyle.haloPeak) / 2
        ring.shadowOffset = .zero
        ring.opacity = 0
        host.addSublayer(ring)
        return ring
    }

    /// Never key, never main: the glow must not take focus from the field it points at.
    private final class GlowPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}
