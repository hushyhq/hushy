import MurmurCore
import SwiftUI

/// The row of app filter chips: "All apps", then "Claude", "Ghostty"… most-used first, from
/// whole-history aggregates (see `HistoryAppChipModel`). No counts on the chips. The row scrolls horizontally when it doesn't fit, with a soft fade on
/// whichever edge has more chips beyond it, so a cut-off chip reads as "more this way" rather
/// than a clipping bug.
struct HistoryAppFilterChips: View {
    let chips: [HistoryAppChip]
    @Binding var selection: HistoryPageFilter
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var overflow = EdgeOverflow()

    private static let fadeWidth: CGFloat = 28

    var body: some View {
        // `ScrollView` contents can't be drawn by `ImageRenderer` (see `HistoryScrubber`/
        // `ScreenLayout`'s same note) — snapshot mode lays the chips out in a plain `HStack`
        // when they fit, else clipped with the trailing fade, which is what the live row looks
        // like at rest.
        if isSnapshot {
            ViewThatFits(in: .horizontal) {
                chipRow
                chipRow
                    .fixedSize()
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .mask(fadeMask(leading: false, trailing: true))
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                chipRow.padding(.vertical, 1) // room for the chip strokes
            }
            .onScrollGeometryChange(for: EdgeOverflow.self) { geometry in
                EdgeOverflow(
                    leading: geometry.contentOffset.x > 1,
                    trailing: geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1)
            } action: { _, newValue in
                overflow = newValue
            }
            .mask(fadeMask(leading: overflow.leading, trailing: overflow.trailing))
            .animation(Theme.fade, value: overflow)
        }
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                AppChipButton(chip: chip, isSelected: isSelected(chip)) {
                    selection = chip.bundleID.map { HistoryPageFilter.app($0) } ?? .all
                }
            }
        }
    }

    private func fadeMask(leading: Bool, trailing: Bool) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(leading ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .black.opacity(trailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
        }
    }

    private func isSelected(_ chip: HistoryAppChip) -> Bool {
        switch selection {
        case .all: chip.isAllApps
        case .app(let bundleID): bundleID == chip.bundleID
        case .needsAttention: false
        }
    }
}

/// Which edges of the chip row have chips scrolled out of view.
private struct EdgeOverflow: Equatable {
    var leading = false
    var trailing = false
}

/// One chip: the app icon and name. A selected *app* is a filled accent pill — it's an active
/// filter. "All apps" selected is the no-filter state, so it gets the quiet selection tint
/// instead (the same distinction the date strip draws for "All dates"), so the row never shows
/// two accent fills when only the date is filtered. At rest a hairline capsule; hover warms the
/// fill slightly — tints only, no size change, so the row never shifts under the pointer.
private struct AppChipButton: View {
    let chip: HistoryAppChip
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let bundleID = chip.bundleID {
                    AppBadge(bundleID: bundleID, appName: chip.name).frame(width: 16, height: 16)
                }
                Text(chip.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(isSelected && !chip.isAllApps ? Theme.onPhosphor
                             : (isSelected || isHovered ? Theme.textPrimary : Theme.textSecondary))
            .padding(.horizontal, Theme.Space.s + 2)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(isSelected && !chip.isAllApps ? .clear : Theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
            .animation(Theme.fade, value: isSelected)
            .animation(Theme.fade, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(chip.isAllApps ? "Show dictations from every app" : "Show only \(chip.name)")
        .accessibilityLabel(chip.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if isSelected { return chip.isAllApps ? Theme.selection : Theme.phosphorFill }
        return isHovered ? Theme.selection : .clear
    }
}
