import SwiftUI

/// A quiet full-width row that opens or closes more of Home's timeline in place: "Show 12 more"
/// under a day's entries, and the one-line "Yesterday · 14 dictations · 2 voice actions" summary
/// of the most recent earlier day. Secondary text, a chevron, nothing loud. Hover tints the row
/// and lifts the text; keyboard focus draws a ring. Under Reduce Motion the chevron swaps
/// instead of turning (the expanded content only ever fades).
struct HomeDisclosureRow: View {
    let title: String
    let isExpanded: Bool
    /// Chevron angle (degrees, from a down-pointing chevron) while collapsed and while expanded.
    let collapsedAngle: Double
    let expandedAngle: Double
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var hovering = false

    var body: some View {
        // Deliberately not a `Button`: a Button would also activate itself on Space, and the feed
        // above binds Space to Quick Look. Here the row's own handler takes Space and Return,
        // returns `.handled`, and so the key never bubbles up to the feed.
        row
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.space) { action(); return .handled }
            .onKeyPress(.return) { action(); return .handled }
            .onHover { hovering = $0 }
            .animation(Theme.fade, value: hovering)
            .animation(Theme.fade, value: isFocused)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }

    private var row: some View {
            HStack(spacing: Theme.Space.s) {
                Text(title)
                    .font(Theme.Font.caption)
                    .foregroundStyle(hovering || isFocused ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                chevron
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(hovering ? Theme.selection : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.phosphor, lineWidth: isFocused ? 1.5 : 0))
    }

    @ViewBuilder
    private var chevron: some View {
        let symbol = Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(hovering || isFocused ? Theme.textSecondary : Theme.textTertiary)
        if reduceMotion {
            // No turning: the chevron changes direction at once.
            symbol.rotationEffect(.degrees(isExpanded ? expandedAngle : collapsedAngle))
        } else {
            symbol
                .rotationEffect(.degrees(isExpanded ? expandedAngle : collapsedAngle))
                .animation(Theme.settle, value: isExpanded)
        }
    }
}
