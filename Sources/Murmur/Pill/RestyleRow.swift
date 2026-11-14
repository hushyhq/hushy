import MurmurCore
import SwiftUI

/// The pill after the restyle shortcut (`PillState.restyle`): one chip per way of writing and a Copy toggle. Carries
/// no text: the selection waits in `RestyleController`, in memory, until a chip is picked or the row times out.
struct RestyleChooser: Equatable {
    /// The Copy toggle: the result goes to the clipboard and the selection stays as it was.
    var copy = false
    /// The selection cannot be replaced (text on a page, in a terminal): the result is always copied, and Copy shows on.
    var copyOnly = false

    var copies: Bool { copy || copyOnly }

    /// The row clears itself after this long if nothing is picked, and the selection is let go.
    static let lifetime: Duration = .seconds(12)

    /// The number keys the event tap gives the chips while the row shows (`PillKeyRouter`), and C for Copy.
    static let styleKeys: [RestyleStyle] = RestyleStyle.allCases
}

struct RestyleRow: View {
    let chooser: RestyleChooser
    let onPick: (RestyleStyle) -> Void
    let onToggleCopy: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            PillCircleButton(glyph: "xmark", tint: .muted, tooltip: .cancel, namesKey: true, action: onCancel)
                .accessibilityLabel(RestyleCopy.close)
            ForEach(Array(RestyleChooser.styleKeys.enumerated()), id: \.element) { index, style in
                chip(RestyleCopy.chip(style), key: "\(index + 1)", filled: false) { onPick(style) }
                    .accessibilityLabel(RestyleCopy.chip(style))
            }
            chip(RestyleCopy.copyToggle, key: "c", filled: chooser.copies, action: onToggleCopy)
                .disabled(chooser.copyOnly)
                .accessibilityLabel(RestyleCopy.copyToggle)
                .accessibilityValue(chooser.copies ? RestyleCopy.on : RestyleCopy.off)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func chip(_ title: String, key: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(key).font(.system(size: 9, weight: .semibold, design: .monospaced)).opacity(0.5)
            }
            .foregroundStyle(filled ? Theme.onPhosphor : .white.opacity(0.88))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(filled ? Theme.phosphorFill : .white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}
