import MurmurCore
import SwiftUI

/// Every hover and hover-hint state of the pill, for the visual sign-off of the click/tooltip
/// round: `pill-hover-<state>` in the classic 480×160 frame (bottom anchor, comparable with the
/// round-1 renders), and `pill-hover-<anchor>-<state>` on the mock display for all four anchors.
extension Snapshots {
    struct HoverCase {
        let name: String
        let state: PillState
        var hovered: PillModel.IdleControl?? = nil
        /// The one hint to force visible (`snapshotTooltipText`).
        var tooltip: String?
    }

    static let hoverCases: [HoverCase] = {
        let actions = (1...3).map { ProposedAction(kind: .createReminder, title: "Reminder \($0)", sourceText: "reminder") }
        return [
            HoverCase(name: "idle-hover", state: .idle, hovered: .some(nil)),
            HoverCase(name: "idle-hover-action", state: .idle, hovered: .some(.action)),
            HoverCase(name: "handsFree", state: .handsFree(startedAt: Date())),
            HoverCase(name: "handsFree-tooltip-cancel", state: .handsFree(startedAt: Date()), tooltip: "Cancel"),
            HoverCase(name: "handsFree-tooltip-finish", state: .handsFree(startedAt: Date()),
                      tooltip: "Paste"),
            HoverCase(name: "recordingNote-tooltip-stop", state: .recordingNote(startedAt: Date()), tooltip: "Stop and save"),
            HoverCase(name: "actionListening-tooltip-cancel", state: .actionListening, tooltip: "Cancel"),
            HoverCase(name: "actionConfirm-single", state: .actionConfirm(ActionConfirmationCardState(actions: [actions[0]]))),
            HoverCase(name: "actionConfirm-stacked3", state: .actionConfirm(ActionConfirmationCardState(actions: actions))),
        ]
    }()

    static func renderPillHover(scheme: ColorScheme, directory: URL) async {
        let levels = [0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55]
        for hoverCase in hoverCases {
            let classic = model(for: hoverCase, levels: levels)
            let tall = hoverCase.name.hasSuffix("stacked3")
            await capture(
                PillView(model: classic).padding(40).background(Theme.bgSunken)
                    .environment(\.snapshotTooltipText, hoverCase.tooltip).environment(\.colorScheme, scheme),
                name: "pill-hover-\(hoverCase.name)", scheme: scheme,
                size: CGSize(width: tall ? 560 : 480, height: tall ? 360 : 160), directory: directory, fixedSize: true)
            for anchor in PillAnchor.allCases {
                await capture(
                    anchoredPill(model(for: hoverCase, levels: levels), at: anchor)
                        .environment(\.snapshotTooltipText, hoverCase.tooltip).environment(\.colorScheme, scheme),
                    name: "pill-hover-\(anchor.rawValue)-\(hoverCase.name)", scheme: scheme,
                    size: mockDisplay.size, directory: directory, fixedSize: true)
            }
        }
    }

    private static func model(for hoverCase: HoverCase, levels: [Double]) -> PillModel {
        let pill = PillModel()
        pill.state = hoverCase.state
        pill.showWhenIdle = true
        pill.setLevels(levels)
        if let control = hoverCase.hovered {
            pill.isHovered = true
            pill.hoveredIdleControl = control
        }
        return pill
    }
}
