import CoreGraphics
import Foundation

/// Where the user dragged the pill before 2026-09-28, stored as fractions of a screen's visible
/// frame. Read only to migrate to an edge anchor (`PillGeometry.migratedAnchor(from:)`).
public struct PillPlacement: Codable, Equatable, Sendable {
    public var screenID: UInt32
    public var fractionX: Double
    public var fractionY: Double

    public init(screenID: UInt32, fractionX: Double, fractionY: Double) {
        self.screenID = screenID
        self.fractionX = fractionX
        self.fractionY = fractionY
    }
}

/// Where the pill rests: the centre of one of a display's four edges (DECISIONS 2026-09-28 "Pill
/// rests at an edge centre"). The capsule stays horizontal everywhere; rows, cards and tooltips
/// open toward the screen centre.
public enum PillAnchor: String, Codable, CaseIterable, Sendable {
    case bottom, top, left, right

    /// Rows, cards and tooltips open downward only at the top edge; upward everywhere else.
    public var opensDownward: Bool { self == .top }

    /// The left and right edges: the pill stands vertical there (founder decision 2026-09-28).
    public var isSide: Bool { self == .left || self == .right }
}

/// The saved anchor per display, and the display the pill was last placed on (nil until the
/// user drags it: the pill then follows the screen with the pointer).
public struct PillAnchorPrefs: Codable, Equatable, Sendable {
    public private(set) var screenID: UInt32?
    private var anchors: [String: PillAnchor]

    public init() {
        screenID = nil
        anchors = [:]
    }

    public func anchor(forScreen id: UInt32) -> PillAnchor {
        anchors[String(id)] ?? .bottom
    }

    /// Records a drop: this display's anchor, and this display as the pill's home.
    public mutating func set(_ anchor: PillAnchor, forScreen id: UInt32) {
        anchors[String(id)] = anchor
        screenID = id
    }
}

/// Pure placement maths for the floating pill: the four edge anchors, the panel frame at each,
/// snapping a release to the nearest one, and clamping on-screen.
public enum PillGeometry {
    /// Within this distance of a guide (screen centre line, default bottom row) the pill snaps.
    public static let snapDistance: CGFloat = 28

    public static func defaultAnchor(in visible: CGRect, clearance: CGFloat) -> CGPoint {
        CGPoint(x: visible.midX, y: visible.minY + clearance)
    }

    /// Gap between the menu bar (or notch) and a top-anchored panel.
    public static let topClearance: CGFloat = 8
    /// Visible gap between a side edge and the capsule.
    public static let sideClearance: CGFloat = 16
    /// Room the pill's SwiftUI content keeps beside the capsule at a side anchor, for its shadow.
    public static let sideShadowPad: CGFloat = 12
    /// Gap above the Dock (or the screen's bottom edge) for the bottom anchor. Founder 2026-09-28:
    /// 16 pt left the pill floating ~2 mm too high; 6 pt still keeps hovers off the Dock icons.
    public static let dockClearance: CGFloat = 6

    /// The highest point a top-anchored pill may reach: below the menu bar, and below the notch
    /// even when the menu bar is hidden (full-screen Spaces report a taller visible frame).
    public static func topLimit(screenFrame: CGRect, visible: CGRect, safeAreaTop: CGFloat) -> CGFloat {
        min(visible.maxY, screenFrame.maxY - safeAreaTop)
    }

    /// The panel frame for `anchor`. The capsule sits on the panel's edge nearest the display
    /// edge (bottom, top, left or right); everything else opens toward the centre. Clamped so
    /// the whole panel — rows, cards, tooltips — stays on this display.
    public static func frame(for anchor: PillAnchor, size: CGSize, in visible: CGRect, topLimit: CGFloat) -> CGRect {
        let bounds = CGRect(x: visible.minX, y: visible.minY, width: visible.width,
                            height: max(0, min(visible.maxY, topLimit) - visible.minY))
        // Side panels are centred on the display's middle: the vertical pill, a row or a card all
        // centre on it.
        let sideY = visible.midY - size.height / 2
        let origin = switch anchor {
        case .bottom: CGPoint(x: visible.midX - size.width / 2, y: visible.minY + dockClearance)
        case .top: CGPoint(x: visible.midX - size.width / 2, y: bounds.maxY - topClearance - size.height)
        case .left: CGPoint(x: visible.minX + sideClearance - sideShadowPad, y: sideY)
        case .right: CGPoint(x: visible.maxX - sideClearance + sideShadowPad - size.width, y: sideY)
        }
        return clamped(CGRect(origin: origin, size: size), in: bounds)
    }

    /// The anchor a release at `point` snaps to: the nearest edge centre of this display.
    /// Ties go to the default, bottom.
    public static func nearestAnchor(to point: CGPoint, in visible: CGRect, topLimit: CGFloat) -> PillAnchor {
        let top = min(visible.maxY, topLimit)
        let centres: [(PillAnchor, CGPoint)] = [
            (.bottom, CGPoint(x: visible.midX, y: visible.minY)),
            (.top, CGPoint(x: visible.midX, y: top)),
            (.left, CGPoint(x: visible.minX, y: visible.midY)),
            (.right, CGPoint(x: visible.maxX, y: visible.midY)),
        ]
        var best = centres[0]
        for candidate in centres.dropFirst() where distance(candidate.1, point) < distance(best.1, point) {
            best = candidate
        }
        return best.0
    }

    /// The grey drop spot shown at each anchor while the pill is dragged: capsule-shaped, sitting
    /// where the resting capsule would (same clearances as `frame(for:…)`), vertical at the side
    /// edges like the pill there.
    public static let dropTargetSize = CGSize(width: 64, height: 22)

    public static func dropTarget(for anchor: PillAnchor, in visible: CGRect, topLimit: CGFloat) -> CGRect {
        let size = anchor.isSide ? CGSize(width: dropTargetSize.height, height: dropTargetSize.width) : dropTargetSize
        let top = min(visible.maxY, topLimit)
        let origin = switch anchor {
        case .bottom: CGPoint(x: visible.midX - size.width / 2, y: visible.minY + dockClearance)
        case .top: CGPoint(x: visible.midX - size.width / 2, y: top - topClearance - size.height)
        case .left: CGPoint(x: visible.minX + sideClearance, y: visible.midY - size.height / 2)
        case .right: CGPoint(x: visible.maxX - sideClearance - size.width, y: visible.midY - size.height / 2)
        }
        return CGRect(origin: origin, size: size)
    }

    /// A screen rect (origin bottom-left) in a full-display overlay's view coordinates (top-left).
    public static func viewRect(_ rect: CGRect, inDisplay display: CGRect) -> CGRect {
        CGRect(x: rect.minX - display.minX, y: display.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A pre-anchor free-form position → the nearest anchor, judged on a 16:10 reference display
    /// (the fractions are screen-relative, so the display itself isn't needed).
    public static func migratedAnchor(from placement: PillPlacement) -> PillAnchor {
        let reference = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        return nearestAnchor(to: anchor(for: placement, in: reference), in: reference, topLimit: reference.maxY)
    }

    /// Panel frame for a bottom-centre anchor (the pill follows the cursor while dragging),
    /// kept entirely inside the visible frame.
    public static func frame(anchor: CGPoint, size: CGSize, in visible: CGRect) -> CGRect {
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        let x = min(max(anchor.x - size.width / 2, visible.minX), maxX)
        let y = min(max(anchor.y, visible.minY), maxY)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    public static func placement(for anchor: CGPoint, in visible: CGRect, screenID: UInt32) -> PillPlacement {
        let fx = visible.width > 0 ? Double((anchor.x - visible.minX) / visible.width) : 0.5
        let fy = visible.height > 0 ? Double((anchor.y - visible.minY) / visible.height) : 0
        return PillPlacement(screenID: screenID, fractionX: clamp01(fx), fractionY: clamp01(fy))
    }

    public static func anchor(for placement: PillPlacement, in visible: CGRect) -> CGPoint {
        CGPoint(
            x: visible.minX + CGFloat(clamp01(placement.fractionX)) * visible.width,
            y: visible.minY + CGFloat(clamp01(placement.fractionY)) * visible.height)
    }

    private static func clamped(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        let x = min(max(rect.minX, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        let y = min(max(rect.minY, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func clamp01(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}

/// Click-through for the pill's panel: the panel is larger than what it draws (room for
/// tooltips, rows and cards), so it takes the pointer only over drawn shapes — the capsule, a
/// row, a card, a banner, a tooltip while showing — and lets every other click reach the app
/// underneath (DECISIONS 2026-09-28). Regions come from SwiftUI in view points (top-left origin).
public enum PillHitTest {
    /// Forgiveness around each shape, so the edge of a 11 pt resting capsule is easy to hit.
    public static let slop: CGFloat = 4

    /// A view rect (origin top-left of the panel's content) in screen points (origin bottom-left).
    public static func screenRect(_ rect: CGRect, inWindow window: CGRect) -> CGRect {
        CGRect(x: window.minX + rect.minX, y: window.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func contains(
        _ point: CGPoint, regions: [CGRect], inWindow window: CGRect, slop: CGFloat = PillHitTest.slop
    ) -> Bool {
        regions.contains { screenRect($0, inWindow: window).insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    /// Whether the panel should take mouse events with the pointer at `point`: only in an
    /// interactive state and over a drawn shape — or throughout a drag of the pill.
    public static func acceptsMouse(
        at point: CGPoint, regions: [CGRect], inWindow window: CGRect, interactive: Bool, dragging: Bool
    ) -> Bool {
        dragging || (interactive && contains(point, regions: regions, inWindow: window))
    }
}

/// Whether the pill's panel takes the mouse. Opens when the pointer comes within `PillHitTest.slop`
/// of a drawn shape in an interactive state; once open it stays open within `staySlop` (so the
/// hover growing, shrinking or a hint appearing can't flap it); it is latched open from mouse-down
/// to mouse-up and through a drag, so a press is always delivered whole. A region change alone
/// can open it but never close it — only the pointer moving, a release or the state closes it.
public struct PillMouseGate: Equatable, Sendable {
    public static let staySlop: CGFloat = 12

    public private(set) var isOpen = false
    public private(set) var isPressed = false
    public var isDragging = false

    public init() {}

    private var isHeld: Bool { isPressed || isDragging }

    public mutating func mouseDown() {
        isPressed = true
        isOpen = true
    }

    @discardableResult
    public mutating func mouseUp(at point: CGPoint, regions: [CGRect], inWindow window: CGRect, interactive: Bool) -> Bool {
        isPressed = false
        return pointerMoved(to: point, regions: regions, inWindow: window, interactive: interactive)
    }

    /// The pointer moved (or the state/panel changed): the full decision, with hysteresis.
    @discardableResult
    public mutating func pointerMoved(to point: CGPoint, regions: [CGRect], inWindow window: CGRect, interactive: Bool) -> Bool {
        guard !isHeld else { isOpen = true; return true }
        let slop = isOpen ? Self.staySlop : PillHitTest.slop
        isOpen = interactive && PillHitTest.contains(point, regions: regions, inWindow: window, slop: slop)
        return isOpen
    }

    /// The drawn shapes changed under a still pointer: may open, never closes.
    @discardableResult
    public mutating func regionsChanged(pointer: CGPoint, regions: [CGRect], inWindow window: CGRect, interactive: Bool) -> Bool {
        if !isOpen, interactive, PillHitTest.contains(pointer, regions: regions, inWindow: window) { isOpen = true }
        return isOpen
    }
}
