import MurmurCore
import SwiftUI

/// The pill at each edge anchor (DECISIONS 2026-09-28 "Pill rests at an edge centre"), placed on
/// a mock 900×560 display by the real `PillGeometry.frame(for:…)`. The dashed outline is the
/// panel: only the drawn shapes inside it take clicks. `pill-anchor-<edge>-<idle|copied|stacked3>`.
extension Snapshots {
    static let mockDisplay = CGRect(x: 0, y: 0, width: 900, height: 560)

    static func renderPillAnchors(scheme: ColorScheme, directory: URL) async {
        let actions = (1...3).map { ProposedAction(kind: .createReminder, title: "Reminder \($0)", sourceText: "reminder") }
        let states: [(String, PillState)] = [
            ("idle", .idle),
            ("copied", .copied(reason: .pasteFailed)),
            ("stacked3", .actionConfirm(ActionConfirmationCardState(actions: actions))),
        ]
        for anchor in PillAnchor.allCases {
            for (name, state) in states {
                let pill = PillModel()
                pill.state = state
                await capture(anchoredPill(pill, at: anchor).environment(\.colorScheme, scheme),
                              name: "pill-anchor-\(anchor.rawValue)-\(name)", scheme: scheme,
                              size: mockDisplay.size, directory: directory, fixedSize: true)
            }
        }
    }

    static func anchoredPill(_ pill: PillModel, at anchor: PillAnchor) -> some View {
        pill.showWhenIdle = true
        pill.anchor = anchor
        let panel = PillGeometry.frame(for: anchor, size: PillPanel.frameSize(for: pill.state, anchor: anchor), in: mockDisplay,
                                       topLimit: mockDisplay.maxY)
        return ZStack(alignment: .topLeading) {
            Theme.bgSunken
            PillView(model: pill)
                .frame(width: panel.width, height: panel.height)
                .overlay(Rectangle().strokeBorder(Theme.textTertiary.opacity(0.5),
                                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                // AppKit's y runs up from the bottom; SwiftUI's runs down from the top.
                .offset(x: panel.minX, y: mockDisplay.height - panel.maxY)
        }
        .frame(width: mockDisplay.width, height: mockDisplay.height)
    }
}
