import AppKit
import MurmurCore
import SwiftUI
import Testing
@testable import Murmur

/// The vertical side pill, the hover ring / expanded ✓, and the drop-spot model (founder
/// decisions 2026-09-28).
@Suite("Pill — vertical at side edges, hover ring, drop spots")
@MainActor
struct PillVerticalTests {
    @Test("icon-and-bar states stand vertical at the side edges; text rows and cards never do")
    func verticalStates() {
        for state: PillState in [.idle, .listening, .handsFree(startedAt: .now), .recordingNote(startedAt: .now),
                                 .processing(), .actionListening] {
            #expect(PillLayout(anchor: .left).isVertical(state), "\(state)")
            #expect(PillLayout(anchor: .right).isVertical(state), "\(state)")
            #expect(!PillLayout(anchor: .bottom).isVertical(state))
            #expect(!PillLayout(anchor: .top).isVertical(state))
        }
        for state: PillState in [.copied(reason: .pasteFailed), .held(copied: false), .done(words: 3),
                                 .error("x"), .actionConfirm(PillOutcomeTests.card(rows: 1))] {
            #expect(!PillLayout(anchor: .right).isVertical(state), "\(state)")
        }
    }

    @Test("a vertical pill's panel is tall enough; rows at the side keep the row panel")
    func sidePanelSizes() {
        let tall = PillPanel.size(for: .handsFree(startedAt: .now), anchor: .right)
        #expect(tall.height == PillPanel.verticalHeight)
        #expect(PillPanel.size(for: .idle, anchor: .left).height == PillPanel.verticalHeight)
        #expect(PillPanel.size(for: .copied(reason: .pasteFailed), anchor: .right) == PillPanel.rowSize)
        #expect(PillPanel.size(for: .handsFree(startedAt: .now), anchor: .bottom).height == PillPanel.size.height)
    }

    @Test("the hover ring: 1.5 pt, 3 pt clear of the button, fading in over 120 ms")
    func hoverRing() {
        #expect(PillHoverRing.lineWidth == 1.5)
        #expect(PillHoverRing.gap == 3)
        #expect(PillHoverRing.fade == .milliseconds(120))
        // Inner edge 3 pt outside a 20 pt button: centre-line diameter 20 + 2 × (3 + 0.75).
        #expect(PillHoverRing.strokeDiameter(button: 20) == 27.5)
        #expect(PillButtonAffordance.ring != PillButtonAffordance.expand)
    }

    @Test("B's expanded ✓ keeps its ✓ end on the button and grows toward the pill's middle")
    func expandedConfirmPlacement() {
        let container = CGSize(width: 420, height: 104)
        let button = CGRect(x: 250, y: 79, width: 20, height: 20)
        let left = ExpandedConfirmCapsule.centre(button: button, width: 70, container: container, growsRight: false)
        #expect(left.x + 35 == button.maxX + 1)
        #expect(left.y == button.midY)
        let right = ExpandedConfirmCapsule.centre(button: button, width: 70, container: container, growsRight: true)
        #expect(right.x - 35 == button.minX - 1)
    }

    @Test("drop-spot model: four targets in overlay coordinates, the nearest highlighted, vertical at the sides")
    func dropTargetsModel() {
        let display = PillDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                  visible: CGRect(x: 0, y: 80, width: 1440, height: 795), topLimit: 875)
        let model = PillDropTargetsModel()
        model.update(display: display, pointer: CGPoint(x: 1400, y: 470))
        #expect(model.targets.count == 4)
        #expect(model.highlighted == .right)
        let right = model.targets[.right]
        #expect(right?.height ?? 0 > right?.width ?? 0, "vertical at the side edge")
        let bottom = model.targets[.bottom]
        #expect(bottom?.width ?? 0 > bottom?.height ?? 0)
        // Overlay coordinates: y runs down from the display's top.
        #expect(bottom.map { $0.maxY == 900 - (80 + PillGeometry.dockClearance) } == true)
        model.update(display: display, pointer: CGPoint(x: 720, y: 100))
        #expect(model.highlighted == .bottom)
    }
}
