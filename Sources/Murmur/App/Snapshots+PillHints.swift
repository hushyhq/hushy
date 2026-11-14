import MurmurCore
import SwiftUI

/// The founder's hint shortlist (2026-09-28): every `PillHintStyle` for the ✕ "Cancel" and ✓
/// "Done" hints, as a close-up and at the bottom and right anchors — `pill-hint-<style>-<where>-
/// <cancel|done>` — plus a mock of a vertical pill at the side anchors (`pill-vertical-…`), for
/// the "should side anchors go vertical?" call. The vertical pill is a snapshot mock only.
extension Snapshots {
    private static let hintCases: [(String, String)] = [("cancel", "Cancel"), ("done", "Done")]

    static func renderPillHints(scheme: ColorScheme, directory: URL) async {
        let levels = [0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55]
        for style in PillHintStyle.allCases {
            for (name, title) in hintCases {
                let closeUp = PillView(model: handsFreePill(levels))
                    .padding(.horizontal, 60).padding(.vertical, 40).background(Theme.bgSunken)
                await capture(hinted(closeUp, style: style, title: title, scheme: scheme),
                              name: "pill-hint-\(style.rawValue)-closeup-\(name)", scheme: scheme,
                              size: CGSize(width: 560, height: 190), directory: directory, fixedSize: true)
                for anchor in [PillAnchor.bottom, .right] {
                    await capture(hinted(anchoredPill(handsFreePill(levels), at: anchor), style: style, title: title,
                                         scheme: scheme),
                                  name: "pill-hint-\(style.rawValue)-\(anchor.rawValue)-\(name)", scheme: scheme,
                                  size: mockDisplay.size, directory: directory, fixedSize: true)
                }
            }
        }
        for side in [PillAnchor.left, .right] {
            for (name, hint) in [("cancel", PillHint.cancel), ("done", PillHint.finish)] { // the final (rim) style
                await capture(VerticalPillMock(side: side, hint: hint, hostScheme: scheme, levels: levels)
                                .environment(\.colorScheme, scheme),
                              name: "pill-vertical-\(side.rawValue)-\(name)", scheme: scheme,
                              size: mockDisplay.size, directory: directory, fixedSize: true)
            }
        }
    }

    private static func handsFreePill(_ levels: [Double]) -> PillModel {
        let pill = PillModel()
        pill.state = .handsFree(startedAt: Date())
        pill.setLevels(levels)
        return pill
    }

    private static func hinted(_ view: some View, style: PillHintStyle, title: String, scheme: ColorScheme) -> some View {
        view.environment(\.pillHintStyle, style)
            .environment(\.snapshotTooltipText, title)
            .environment(\.colorScheme, scheme)
    }
}

/// Snapshot-only mock: Wispr-style vertical pill (✕, waveform, ✓ stacked) at a side edge, with
/// the final (rim) hint beside it pointing at its button, on the mock display.
private struct VerticalPillMock: View {
    let side: PillAnchor
    let hint: PillHint
    let hostScheme: ColorScheme
    let levels: [Double]

    var body: some View {
        ZStack(alignment: side == .left ? .leading : .trailing) {
            Theme.bgSunken
            HStack(spacing: 9) {
                if side == .right { sideHint }
                capsule
                if side == .left { sideHint }
            }
            .padding(.horizontal, 16)
        }
        .frame(width: Snapshots.mockDisplay.width, height: Snapshots.mockDisplay.height)
    }

    private var isCancel: Bool { hint == .cancel }

    private var capsule: some View {
        VStack(spacing: 10) {
            circle("xmark", lime: false)
            Waveform(levels: levels)
                .fixedSize()
                .rotationEffect(.degrees(90))
                .frame(width: 22, height: 52)
            circle("checkmark", lime: true)
        }
        .padding(.vertical, 8)
        .frame(width: 34)
        .background(Capsule().fill(Theme.pill))
        .overlay(Capsule().strokeBorder(Theme.phosphorFill.opacity(0.32), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }

    private func circle(_ glyph: String, lime: Bool) -> some View {
        Image(systemName: glyph)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(lime ? Theme.onPhosphor : .white.opacity(0.8))
            .frame(width: 20, height: 20)
            .background(Circle().fill(lime ? Theme.phosphorFill : .white.opacity(0.14)))
    }

    /// The hint beside the capsule, level with its button, notch pointing sideways at it.
    private var sideHint: some View {
        PillHintBubble(hint: hint, style: .rim, hostScheme: hostScheme,
                       pointing: side == .right ? .trailing : .leading)
            .offset(y: isCancel ? -44 : 44)
    }
}
