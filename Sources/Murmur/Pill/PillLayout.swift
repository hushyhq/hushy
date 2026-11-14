import MurmurCore
import SwiftUI

/// How the pill's content sits in its panel for an edge anchor (DECISIONS 2026-09-28 "Pill rests
/// at an edge centre"): the capsule stays horizontal on the panel edge nearest the display edge,
/// and rows, cards, banners, hints and tooltips open toward the screen centre.
struct PillLayout: Equatable {
    /// The SwiftUI coordinate space of the panel's content; hit regions are reported in it.
    static let space = "pill.panel"

    let anchor: PillAnchor

    var opensDownward: Bool { anchor.opensDownward }

    /// States whose capsule is icons and bars only, so it can stand vertical at a side edge.
    /// Rows and cards (copied, held, upgrade, done, error, confirm) stay horizontal: they're text.
    static func canStandVertical(_ state: PillState) -> Bool {
        switch state {
        case .idle, .listening, .handsFree, .recordingNote, .processing, .actionListening, .actionProcessing: true
        default: false
        }
    }

    /// The pill stands vertical at the left and right edges (founder decision 2026-09-28).
    func isVertical(_ state: PillState) -> Bool {
        anchor.isSide && Self.canStandVertical(state)
    }

    /// Where the pill's content is pinned inside the panel.
    var alignment: Alignment {
        switch anchor {
        case .bottom: .bottom
        case .top: .top
        // Side edges: vertically centred, hugging the edge.
        case .left: .leading
        case .right: .trailing
        }
    }

    var horizontal: HorizontalAlignment { alignment.horizontal }

    /// A stacked confirm card and its footer capsule share one edge: the left, or the right
    /// at the right anchor (so the card still opens toward the centre).
    var stackEdge: HorizontalAlignment { anchor == .right ? .trailing : .leading }

    /// Beside a side edge the content keeps room for its shadow (`PillGeometry.sideShadowPad`).
    var sidePadding: CGFloat {
        anchor == .left || anchor == .right ? PillGeometry.sideShadowPad : 0
    }

    /// Things that open from the capsule slide in from its side.
    var openingEdge: Edge { opensDownward ? .top : .bottom }
}

/// Frames of everything the pill draws that should take the pointer, in `PillLayout.space`.
struct PillHitRegionKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Marks this view as a drawn shape the pointer may hit; everywhere else in the panel,
    /// clicks pass through to the app underneath (`PillHitTest`).
    func pillHitRegion() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: PillHitRegionKey.self, value: [proxy.frame(in: .named(PillLayout.space))])
        })
    }
}
