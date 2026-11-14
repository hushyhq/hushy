import CoreGraphics
import Foundation
import Testing
@testable import MurmurCore

@Suite("PillGeometry")
struct PillGeometryTests {
    let visible = CGRect(x: 0, y: 80, width: 1440, height: 800)
    let size = CGSize(width: 280, height: 104)

    @Test("default anchor is bottom-centre above the Dock")
    func defaultAnchor() {
        #expect(PillGeometry.defaultAnchor(in: visible, clearance: 16) == CGPoint(x: 720, y: 96))
    }

    @Test("frames are clamped fully on-screen")
    func clamps() {
        let offRight = PillGeometry.frame(anchor: CGPoint(x: 5000, y: -300), size: size, in: visible)
        #expect(offRight.maxX == visible.maxX)
        #expect(offRight.minY == visible.minY)
        let offTop = PillGeometry.frame(anchor: CGPoint(x: -50, y: 5000), size: size, in: visible)
        #expect(offTop.minX == visible.minX)
        #expect(offTop.maxY == visible.maxY)
    }

    @Test("placement round-trips through fractions and survives a resolution change")
    func roundTrip() {
        let anchor = CGPoint(x: 1200, y: 480)
        let placement = PillGeometry.placement(for: anchor, in: visible, screenID: 7)
        #expect(PillGeometry.anchor(for: placement, in: visible) == anchor)
        let bigger = CGRect(x: 0, y: 80, width: 2880, height: 1600)
        let scaled = PillGeometry.anchor(for: placement, in: bigger)
        #expect(abs(scaled.x - 2400) < 0.001)
        #expect(abs(scaled.y - 880) < 0.001)
    }

    @Test("corrupt stored fractions fall back inside the screen")
    func corrupt() {
        let placement = PillPlacement(screenID: 1, fractionX: .nan, fractionY: 9)
        let point = PillGeometry.anchor(for: placement, in: visible)
        #expect(visible.insetBy(dx: -1, dy: -1).contains(point))
    }

    // MARK: Edge anchors (2026-09-28: the pill rests only at the centre of a display edge)

    @Test("each anchor's panel frame: exact geometry on a 1440×800 visible frame")
    func anchorFrames() {
        let top = visible.maxY
        #expect(PillGeometry.frame(for: .bottom, size: size, in: visible, topLimit: top)
                == CGRect(x: 580, y: 80 + PillGeometry.dockClearance, width: 280, height: 104))
        #expect(PillGeometry.frame(for: .top, size: size, in: visible, topLimit: top)
                == CGRect(x: 580, y: 880 - 8 - 104, width: 280, height: 104))
        // Side panels are centred on the display's vertical middle (the vertical pill, rows and
        // cards all centre on it).
        #expect(PillGeometry.frame(for: .left, size: size, in: visible, topLimit: top)
                == CGRect(x: 4, y: 480 - 52, width: 280, height: 104))
        #expect(PillGeometry.frame(for: .right, size: size, in: visible, topLimit: top)
                == CGRect(x: 1440 - 4 - 280, y: 480 - 52, width: 280, height: 104))
    }

    @Test("a notch or hidden menu bar lowers the top anchor to the safe area")
    func notch() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let fullScreenVisible = CGRect(x: 0, y: 0, width: 1512, height: 982) // menu bar hidden
        let limit = PillGeometry.topLimit(screenFrame: screen, visible: fullScreenVisible, safeAreaTop: 32)
        #expect(limit == 950)
        let frame = PillGeometry.frame(for: .top, size: size, in: fullScreenVisible, topLimit: limit)
        #expect(frame.maxY == CGFloat(950 - 8))
        #expect(PillGeometry.topLimit(screenFrame: screen, visible: CGRect(x: 0, y: 0, width: 1512, height: 945),
                                      safeAreaTop: 32) == 945)
    }

    @Test("rows, stacked cards and tooltips stay on-screen at every anchor, even on a small display",
          arguments: PillAnchor.allCases)
    func staysOnScreen(anchor: PillAnchor) {
        let small = CGRect(x: 1920, y: 0, width: 1024, height: 600) // a second display to the right
        for panel in [CGSize(width: 280, height: 104), CGSize(width: 360, height: 104), CGSize(width: 464, height: 260)] {
            let frame = PillGeometry.frame(for: anchor, size: panel, in: small, topLimit: small.maxY)
            #expect(small.contains(frame), "\(anchor) \(panel) → \(frame)")
        }
    }

    @Test("a release snaps to the nearest edge-centre anchor")
    func nearest() {
        #expect(PillGeometry.nearestAnchor(to: CGPoint(x: 700, y: 120), in: visible, topLimit: visible.maxY) == .bottom)
        #expect(PillGeometry.nearestAnchor(to: CGPoint(x: 900, y: 860), in: visible, topLimit: visible.maxY) == .top)
        #expect(PillGeometry.nearestAnchor(to: CGPoint(x: 30, y: 300), in: visible, topLimit: visible.maxY) == .left)
        #expect(PillGeometry.nearestAnchor(to: CGPoint(x: 1400, y: 700), in: visible, topLimit: visible.maxY) == .right)
        // Off-screen releases still pick an anchor on this display.
        #expect(PillGeometry.nearestAnchor(to: CGPoint(x: 720, y: -500), in: visible, topLimit: visible.maxY) == .bottom)
    }

    @Test("dead centre is a tie; bottom (the default) wins")
    func tie() {
        let square = CGRect(x: 0, y: 0, width: 800, height: 800)
        #expect(PillGeometry.nearestAnchor(to: CGPoint(x: 400, y: 400), in: square, topLimit: 800) == .bottom)
    }

    @Test("a saved free-form position migrates to the nearest anchor", arguments: [
        (0.5, 0.0, PillAnchor.bottom), (0.62, 0.1, .bottom), (0.5, 0.95, .top), (0.02, 0.5, .left),
        (0.97, 0.4, .right), (Double.nan, 0.0, .bottom),
    ])
    func migration(fx: Double, fy: Double, expected: PillAnchor) {
        let old = PillPlacement(screenID: 3, fractionX: fx, fractionY: fy)
        #expect(PillGeometry.migratedAnchor(from: old) == expected)
    }

    @Test("per-display anchors round-trip through JSON; unknown displays default to bottom")
    func prefsRoundTrip() throws {
        var prefs = PillAnchorPrefs()
        #expect(prefs.anchor(forScreen: 9) == .bottom)
        prefs.set(.left, forScreen: 9)
        prefs.set(.top, forScreen: 12)
        let decoded = try JSONDecoder().decode(PillAnchorPrefs.self, from: JSONEncoder().encode(prefs))
        #expect(decoded == prefs)
        #expect(decoded.anchor(forScreen: 9) == .left)
        #expect(decoded.anchor(forScreen: 12) == .top)
        #expect(decoded.screenID == 12, "the display the pill was last placed on")
    }
}

// MARK: - Click-through: only drawn shapes take the pointer

@Suite("PillHitTest")
struct PillHitTestTests {
    /// A 280×104 panel at (580, 96) in screen points (y up).
    let window = CGRect(x: 580, y: 96, width: 280, height: 104)
    /// A 44×11 resting capsule at the bottom-centre of the panel, in view points (y down).
    let capsule = CGRect(x: 118, y: 93, width: 44, height: 11)

    @Test("view rects (top-left origin) convert to screen rects (bottom-left origin)")
    func conversion() {
        #expect(PillHitTest.screenRect(capsule, inWindow: window) == CGRect(x: 698, y: 96, width: 44, height: 11))
    }

    @Test("the pointer counts inside a drawn shape plus a small slop, nowhere else in the panel")
    func contains() {
        #expect(PillHitTest.contains(CGPoint(x: 720, y: 100), regions: [capsule], inWindow: window))
        #expect(PillHitTest.contains(CGPoint(x: 696, y: 100), regions: [capsule], inWindow: window), "within slop")
        #expect(!PillHitTest.contains(CGPoint(x: 600, y: 180), regions: [capsule], inWindow: window), "empty panel corner")
        #expect(!PillHitTest.contains(CGPoint(x: 720, y: 150), regions: [capsule], inWindow: window), "where a tooltip would be")
        let tooltip = CGRect(x: 90, y: 30, width: 100, height: 40)
        #expect(PillHitTest.contains(CGPoint(x: 720, y: 150), regions: [capsule, tooltip], inWindow: window))
        #expect(!PillHitTest.contains(CGPoint(x: 720, y: 100), regions: [], inWindow: window))
    }

    @Test("clicks are taken only for an interactive state over a shape, or while dragging")
    func accepts() {
        let over = CGPoint(x: 720, y: 100)
        let away = CGPoint(x: 600, y: 180)
        #expect(PillHitTest.acceptsMouse(at: over, regions: [capsule], inWindow: window, interactive: true, dragging: false))
        #expect(!PillHitTest.acceptsMouse(at: away, regions: [capsule], inWindow: window, interactive: true, dragging: false))
        #expect(!PillHitTest.acceptsMouse(at: over, regions: [capsule], inWindow: window, interactive: false, dragging: false))
        #expect(PillHitTest.acceptsMouse(at: away, regions: [capsule], inWindow: window, interactive: true, dragging: true))
    }
}

// MARK: - The mouse gate: a latch, hysteresis, and no flapping

@Suite("PillMouseGate")
struct PillMouseGateTests {
    let window = CGRect(x: 580, y: 96, width: 280, height: 104)
    /// The resting capsule, and the hover-grown capsule + hint label (view points, y down).
    let rest = [CGRect(x: 118, y: 93, width: 44, height: 11)]
    let hovered = [CGRect(x: 106, y: 70, width: 68, height: 34), CGRect(x: 100, y: 40, width: 80, height: 24)]
    let onCapsule = CGPoint(x: 720, y: 100)
    let away = CGPoint(x: 600, y: 185)

    private func move(_ gate: inout PillMouseGate, _ point: CGPoint, _ regions: [CGRect], interactive: Bool = true) -> Bool {
        gate.pointerMoved(to: point, regions: regions, inWindow: window, interactive: interactive)
    }

    private func regions(_ gate: inout PillMouseGate, _ regions: [CGRect]) -> Bool {
        gate.regionsChanged(pointer: onCapsule, regions: regions, inWindow: window, interactive: true)
    }

    @Test("opens over a shape in an interactive state, stays shut elsewhere")
    func opens() {
        var gate = PillMouseGate()
        #expect(!move(&gate, away, rest))
        #expect(move(&gate, onCapsule, rest))
        var shut = PillMouseGate()
        #expect(!move(&shut, onCapsule, rest, interactive: false))
    }

    @Test("a region change (hover growing, a hint appearing) can open the gate but never close it")
    func regionChangesNeverClose() {
        var gate = PillMouseGate()
        _ = move(&gate, onCapsule, rest)
        // Mid-animation frames that briefly miss the pointer must not shut the gate (the flap).
        #expect(regions(&gate, [CGRect(x: 0, y: 0, width: 1, height: 1)]))
        #expect(regions(&gate, hovered))
        var closed = PillMouseGate()
        #expect(regions(&closed, rest), "a shape appearing under a still pointer opens it")
    }

    @Test("once open it stays open within 12 pt of a shape (hysteresis), closes beyond")
    func hysteresis() {
        var gate = PillMouseGate()
        _ = move(&gate, onCapsule, rest)
        // 10 pt left of the resting capsule: outside the 4 pt opening slop, inside the 12 pt stay slop.
        #expect(move(&gate, CGPoint(x: 688, y: 100), rest))
        #expect(!move(&gate, CGPoint(x: 680, y: 100), rest))
        var fresh = PillMouseGate()
        #expect(!move(&fresh, CGPoint(x: 688, y: 100), rest))
    }

    @Test("latched open from mouse-down to mouse-up, whatever the pointer or regions do")
    func pressLatch() {
        var gate = PillMouseGate()
        _ = move(&gate, onCapsule, rest)
        gate.mouseDown()
        #expect(move(&gate, away, []))
        #expect(move(&gate, away, rest, interactive: false), "a state change mid-press still delivers the release")
        let open = gate.mouseUp(at: away, regions: rest, inWindow: window, interactive: true)
        #expect(!open)
    }

    @Test("a drag keeps it open; a non-interactive state closes it when nothing is held")
    func dragAndState() {
        var gate = PillMouseGate()
        _ = move(&gate, onCapsule, rest)
        gate.isDragging = true
        #expect(move(&gate, away, rest))
        gate.isDragging = false
        #expect(!move(&gate, onCapsule, rest, interactive: false))
    }
}

// MARK: - Drop targets while dragging (the four edge-centre spots)

@Suite("PillGeometry — drop targets")
struct PillDropTargetTests {
    let visible = CGRect(x: 0, y: 80, width: 1440, height: 800)
    let size = PillGeometry.dropTargetSize

    @Test("each target sits where the capsule rests at that anchor, in that anchor's orientation")
    func targetsPerAnchor() {
        let top = visible.maxY
        #expect(size == CGSize(width: 64, height: 22))
        #expect(PillGeometry.dropTarget(for: .bottom, in: visible, topLimit: top)
                == CGRect(x: 720 - 32, y: 80 + PillGeometry.dockClearance, width: 64, height: 22))
        #expect(PillGeometry.dropTarget(for: .top, in: visible, topLimit: top)
                == CGRect(x: 720 - 32, y: 880 - 8 - 22, width: 64, height: 22))
        // Side edges: vertical targets, like the vertical pill that rests there.
        #expect(PillGeometry.dropTarget(for: .left, in: visible, topLimit: top)
                == CGRect(x: 16, y: 480 - 32, width: 22, height: 64))
        #expect(PillGeometry.dropTarget(for: .right, in: visible, topLimit: top)
                == CGRect(x: 1440 - 16 - 22, y: 480 - 32, width: 22, height: 64))
    }

    @Test("targets follow each display: a second display to the left, and a notch limit on top")
    func perDisplay() {
        let second = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let bottom = PillGeometry.dropTarget(for: .bottom, in: second, topLimit: second.maxY)
        #expect(bottom.midX == second.midX)
        #expect(second.contains(bottom))
        let notched = PillGeometry.dropTarget(for: .top, in: CGRect(x: 0, y: 0, width: 1512, height: 982), topLimit: 950)
        #expect(notched.maxY == CGFloat(950 - 8))
        for anchor in PillAnchor.allCases {
            #expect(second.contains(PillGeometry.dropTarget(for: anchor, in: second, topLimit: second.maxY)))
        }
    }

    @Test("the highlighted target is the one a release would snap to", arguments: [
        (CGPoint(x: 700, y: 140), PillAnchor.bottom), (CGPoint(x: 900, y: 840), .top),
        (CGPoint(x: 60, y: 420), .left), (CGPoint(x: 1380, y: 700), .right),
    ])
    func highlight(pointer: CGPoint, expected: PillAnchor) {
        #expect(PillGeometry.nearestAnchor(to: pointer, in: visible, topLimit: visible.maxY) == expected)
    }

    @Test("screen rects become top-left view rects inside a display's full-frame overlay")
    func overlayCoordinates() {
        let display = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: -1000, y: 16, width: 64, height: 22)
        #expect(PillGeometry.viewRect(rect, inDisplay: display) == CGRect(x: 920, y: 1080 - 38, width: 64, height: 22))
    }
}
