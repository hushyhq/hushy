import SwiftUI

/// The resting pill's glyph (design v3): dot, short bar, dot, short bar, dot — symmetric, in a
/// neutral grey, and static (nothing happens at rest, so Reduce Motion has nothing to remove).
/// Standing vertical at a side edge the same five marks run top to bottom.
struct PillIdleMark: View {
    var vertical = false

    /// Mark sizes in order, points: outer dots, bars, a slightly larger middle dot.
    static let marks: [CGSize] = [
        CGSize(width: 2, height: 2), CGSize(width: 2, height: 5), CGSize(width: 2, height: 3),
        CGSize(width: 2, height: 5), CGSize(width: 2, height: 2),
    ]
    static let spacing: CGFloat = 3
    static let tint = Theme.pillIdleMark

    /// The glyph's length along the capsule; the capsule adds `endPadding` at both ends.
    static var length: CGFloat { marks.reduce(0) { $0 + $1.width } + spacing * CGFloat(marks.count - 1) }
    static let endPadding: CGFloat = 9

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: Self.spacing)) : AnyLayout(HStackLayout(spacing: Self.spacing))
        layout {
            ForEach(Array(Self.marks.enumerated()), id: \.offset) { _, mark in
                Capsule()
                    .fill(Self.tint)
                    // Across the capsule the mark is `height` tall; along it, `width` wide. A
                    // vertical pill swaps them so the same glyph is turned on its end.
                    .frame(width: vertical ? mark.height : mark.width, height: vertical ? mark.width : mark.height)
            }
        }
        .accessibilityHidden(true)
    }
}
