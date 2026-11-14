import SwiftUI

/// Settings → General's "Pill" row: Mini, Large or Hidden, each with a small picture of what it
/// looks like while you talk (`PillPresence`). The pictures are drawn with shapes in the pill's own
/// colours, so they match the real pill in light and dark and `ImageRenderer` can draw them.
///
/// Large's live words are off in Low Power Mode (`DictationController.liveDraft`): Large stays
/// selectable, and says so under its picture, rather than silently looking like Mini.
struct PillPresencePicker: View {
    @Binding var selection: PillPresence
    var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pill").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text("How much of Hushy you see while you talk. Click the resting pill to dictate.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Equal columns whatever the words: the pictures are compared side by side.
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ForEach(PillPresence.allCases) { presence in
                    PresenceTile(
                        presence: presence, isSelected: selection == presence,
                        note: presence == .large && isLowPower ? "Words off in Low Power Mode" : nil
                    ) { selection = presence }
                    .frame(maxWidth: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, Theme.Space.l)
        }
    }
}

private struct PresenceTile: View {
    let presence: PillPresence
    let isSelected: Bool
    let note: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                PresencePicture(presence: presence)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.selection))
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 12)).foregroundStyle(isSelected ? Theme.phosphor : Theme.textTertiary)
                    Text(presence.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                }
                Text(note ?? presence.detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(note == nil ? Theme.textSecondary : Theme.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(isSelected ? Theme.bgRaised : (hovering ? Theme.bgRaised.opacity(0.6) : .clear)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Theme.phosphor.opacity(0.7) : Theme.hairline, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .animation(Theme.Motion.fade, value: isSelected)
        .accessibilityLabel("\(presence.title) pill. \(note ?? presence.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What each choice looks like while you talk.
private struct PresencePicture: View {
    let presence: PillPresence

    private let levels: [CGFloat] = [0.35, 0.7, 1, 0.55, 0.85, 0.45, 0.75]

    var body: some View {
        switch presence {
        case .mini:
            capsule { bars }
        case .large:
            capsule {
                HStack(spacing: 7) {
                    bars
                    Text("Let's meet at")
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1).fixedSize()
                }
            }
        case .hidden:
            Capsule()
                .strokeBorder(Theme.textTertiary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 44, height: 18)
                .overlay(Text("fn").font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textTertiary))
        }
    }

    private var bars: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(Theme.phosphorFill).frame(width: 2, height: 3 + 9 * level)
            }
        }
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(Theme.pillSurface))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}
