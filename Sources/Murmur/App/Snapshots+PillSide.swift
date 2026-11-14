import MurmurCore
import SwiftUI

/// Founder review set for the vertical side pill, drop spots and hover ring (2026-09-28):
/// - `pill-side-<bottom|left|right>-<state>`: every state at the side edges next to the bottom;
/// - `pill-drag-<anchor>`: mid-drag, the four grey drop spots with the nearest highlighted;
/// - `pill-hover-<ring|expand>-<closeup|right>-<cancel|done>`: A (ring) vs B (✓ expands).
extension Snapshots {
    static func renderPillSide(scheme: ColorScheme, directory: URL) async {
        let levels = [0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55]
        for (name, state, hovered) in sideStates() {
            for anchor in [PillAnchor.bottom, .left, .right] {
                let pill = PillModel()
                pill.state = state
                pill.setLevels(levels)
                pill.isHovered = hovered
                await capture(anchoredPill(pill, at: anchor).environment(\.colorScheme, scheme),
                              name: "pill-side-\(anchor.rawValue)-\(name)", scheme: scheme,
                              size: mockDisplay.size, directory: directory, fixedSize: true)
            }
        }
        for anchor in PillAnchor.allCases {
            await capture(dragScene(towards: anchor).environment(\.colorScheme, scheme),
                          name: "pill-drag-\(anchor.rawValue)", scheme: scheme,
                          size: mockDisplay.size, directory: directory, fixedSize: true)
        }
        await renderHoverAffordances(levels: levels, scheme: scheme, directory: directory)
    }

    private static func sideStates() -> [(String, PillState, Bool)] {
        let actions = (1...3).map { ProposedAction(kind: .createReminder, title: "Reminder \($0)", sourceText: "reminder") }
        return [
            ("idle", .idle, false), ("idle-hover", .idle, true), ("listening", .listening, false),
            ("handsFree", .handsFree(startedAt: Date()), false), ("recordingNote", .recordingNote(startedAt: Date()), false),
            ("processing", .processing(), false), ("actionListening", .actionListening, false),
            ("actionProcessing", .actionProcessing, false),
            ("done", .done(words: 42), false), ("copied", .copied(reason: .pasteFailed), false),
            ("held", .held(copied: false), false), ("error", .error(PillModel.microphoneFailedMessage), false),
            ("actionConfirm-single", .actionConfirm(ActionConfirmationCardState(actions: [actions[0]])), false),
            ("actionConfirm-stacked3", .actionConfirm(ActionConfirmationCardState(actions: actions)), false),
        ]
    }

    /// Mid-drag toward `anchor`: the drop spots with that one highlighted, and the pill being carried
    /// a little short of it.
    private static func dragScene(towards anchor: PillAnchor) -> some View {
        let display = PillDisplay(id: 1, frame: mockDisplay, visible: mockDisplay, topLimit: mockDisplay.maxY)
        let target = PillGeometry.dropTarget(for: anchor, in: mockDisplay, topLimit: mockDisplay.maxY)
        let pointer = CGPoint(
            x: target.midX + (anchor == .left ? 90 : anchor == .right ? -90 : 40),
            y: target.midY + (anchor == .bottom ? 70 : anchor == .top ? -70 : 30))
        let targets = PillDropTargetsModel()
        targets.update(display: display, pointer: pointer)
        targets.isShown = true
        // The carried pill: its plain resting capsule (no hover, no hints), turned for the edge
        // it's nearing — as `PillPanel.dragChanged` sets it.
        let pill = PillModel()
        pill.state = .idle
        pill.isHovered = true
        pill.isDragging = true
        pill.dragAnchor = anchor
        return ZStack(alignment: .topLeading) {
            Theme.bgSunken
            PillDropTargetsView(model: targets)
            PillView(model: pill)
                .frame(width: 120, height: 60)
                .position(x: pointer.x, y: mockDisplay.height - pointer.y)
        }
        .frame(width: mockDisplay.width, height: mockDisplay.height)
    }

    private static func renderHoverAffordances(levels: [Double], scheme: ColorScheme, directory: URL) async {
        for affordance in [PillButtonAffordance.ring, .expand] {
            for (name, title) in [("cancel", "Cancel"), ("done", "Done")] {
                let closeUp = PillModel()
                closeUp.state = .handsFree(startedAt: Date())
                closeUp.setLevels(levels)
                await capture(
                    PillView(model: closeUp).padding(.horizontal, 60).padding(.vertical, 40).background(Theme.bgSunken)
                        .environment(\.pillButtonAffordance, affordance).environment(\.snapshotTooltipText, title)
                        .environment(\.colorScheme, scheme),
                    name: "pill-hover-\(affordance.rawValue)-closeup-\(name)", scheme: scheme,
                    size: CGSize(width: 560, height: 170), directory: directory, fixedSize: true)
                let side = PillModel()
                side.state = .handsFree(startedAt: Date())
                side.setLevels(levels)
                await capture(
                    anchoredPill(side, at: .right)
                        .environment(\.pillButtonAffordance, affordance).environment(\.snapshotTooltipText, title)
                        .environment(\.colorScheme, scheme),
                    name: "pill-hover-\(affordance.rawValue)-right-\(name)", scheme: scheme,
                    size: mockDisplay.size, directory: directory, fixedSize: true)
            }
        }
    }
}
