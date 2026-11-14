import MurmurCore
import SwiftUI

/// Wraps children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(proposal: proposal, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat
        var items: [(index: Int, x: CGFloat)]
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, items: [])
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing, height: 0, items: [])
                x = 0
            }
            current.items.append((index, x))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

/// "spoken → typed" example used in page banners.
struct ExampleChip: View {
    let from: String
    let to: String
    @Environment(\.colorScheme) private var scheme

    private var ink: Color { scheme == .dark ? .white : Theme.textPrimary }
    private var chipFill: Color { scheme == .dark ? .white.opacity(0.14) : .black.opacity(0.05) }
    private var chipFillStrong: Color { scheme == .dark ? .white.opacity(0.22) : .black.opacity(0.08) }
    private var arrowTint: Color { scheme == .dark ? .white.opacity(0.6) : Theme.textSecondary }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text("“\(from)”").italic()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(chipFill))
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(arrowTint)
            Text(to)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(chipFillStrong))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
    }
}
