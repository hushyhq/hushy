import AppKit
import SwiftUI

/// Geometry shared by every timeline row on Home and History, so their branches, text and
/// trailing columns land on the same pixels in both places. The group header's `AppBadge`
/// (24 pt wide, flush left) sits directly above the gutter, so the spine runs down the badge's
/// center line.
enum TimelineMetrics {
    /// Width of the leading tree gutter; row text starts after it.
    static let gutterWidth: CGFloat = 30
    /// The spine's x — the center of the 24 pt app badge above it.
    static let spineX: CGFloat = 12
    /// Where a branch ends; the gap to `gutterWidth` keeps it from touching the text.
    static let branchEndX: CGFloat = 23
    /// Radius of the rounded "├"/"└" joint where a branch leaves the spine.
    static let jointRadius: CGFloat = 5
    static let strokeWidth: CGFloat = 1.25
    static let rowVerticalPadding: CGFloat = 5
    /// Fixed trailing column for the status dot / stack count, present on *every* row (empty
    /// when there's nothing to show) so times right-align identically with or without a dot.
    static let statusColumnWidth: CGFloat = 24
    /// Inset of the hover/selection surface from the gutter, so a branch points *into* it.
    static let highlightInset: CGFloat = 2

    static let titleSize: CGFloat = 13.5
    static var titleFont: Font { .system(size: titleSize) }

    /// Vertical center of a row's first text line, measured from the top of its text: the
    /// baseline (ascender) minus half the x-height — the optical middle of lowercase text, which
    /// is where a branch into it should land. Derived from the real font so it can't drift.
    static let firstLineCenter: CGFloat = {
        let font = NSFont.systemFont(ofSize: titleSize)
        return (font.ascender - font.xHeight / 2).rounded(.toNearestOrAwayFromZero)
    }()

    /// The branch's y inside a row: top padding plus the first line's optical center.
    static var branchY: CGFloat { rowVerticalPadding + firstLineCenter }

    static var spineColor: Color { Theme.textTertiary.opacity(0.45) }
}

/// A row's slice of the tree, drawn per row so it composes across separately laid-out rows
/// (including native `List` rows): the spine runs the full height of the row, and a branch leaves
/// it through a rounded "├" joint. The group's last row instead turns the spine into its branch
/// with a rounded "└" elbow, so the spine ends exactly there. The branch only ever extends to the
/// *right* of the spine — nothing pokes out on the left.
struct TimelineBranch: Shape {
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        let x = TimelineMetrics.spineX
        let y = TimelineMetrics.branchY
        let r = TimelineMetrics.jointRadius
        let end = TimelineMetrics.branchEndX
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        if isLast {
            path.addLine(to: CGPoint(x: x, y: y - r))
        } else {
            path.addLine(to: CGPoint(x: x, y: rect.height))
            path.move(to: CGPoint(x: x, y: y - r))
        }
        path.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: end, y: y))
        return path
    }
}

/// How a row's surface is tinted: nothing, a quiet hover wash, or the selected tint.
enum TimelineRowHighlight: Equatable {
    case none, hover, selected
}

/// The one row layout both Home (`TimelineEntryRow`) and History (`HistoryRow`) use:
/// `[tree gutter][content][status column]`, the branch drawn behind the gutter, and a rounded
/// hover/selection surface that starts just after the branch tip. Hover and selection change only
/// fills (via `Theme.fade`), never layout, so rows don't shift under the pointer.
struct TimelineRowScaffold<Content: View, Status: View>: View {
    let isLast: Bool
    var highlight: TimelineRowHighlight = .none
    /// False while History is selecting many: the row's check mark stands where the branch was.
    var showsBranch = true
    @ViewBuilder let content: Content
    @ViewBuilder let status: Status

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: TimelineMetrics.gutterWidth, height: 1)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            // Centered on the first text line, whatever it holds (dot, count badge, nothing).
            // A `ZStack` over a clear fill so the column keeps its width even when `status` is
            // empty — a frame around an empty conditional collapses to nothing.
            ZStack {
                Color.clear
                status
            }
            .frame(width: TimelineMetrics.statusColumnWidth, height: TimelineMetrics.firstLineCenter * 2)
        }
        .padding(.vertical, TimelineMetrics.rowVerticalPadding)
        .padding(.trailing, Theme.Space.xs)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(fill)
                .padding(.leading, TimelineMetrics.branchEndX + TimelineMetrics.highlightInset)
                .padding(.trailing, -Theme.Space.xs)
                .animation(Theme.fade, value: highlight)
        }
        .background(alignment: .topLeading) {
            if showsBranch {
                TimelineBranch(isLast: isLast)
                    .stroke(TimelineMetrics.spineColor, style: StrokeStyle(lineWidth: TimelineMetrics.strokeWidth, lineCap: .round, lineJoin: .round))
                    .frame(width: TimelineMetrics.gutterWidth)
            }
        }
    }

    private var fill: Color {
        switch highlight {
        case .none: .clear
        case .hover: Theme.selection.opacity(0.55)
        case .selected: Theme.phosphorTint
        }
    }
}

/// Status column content: a small colored dot.
struct TimelineStatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }
}
