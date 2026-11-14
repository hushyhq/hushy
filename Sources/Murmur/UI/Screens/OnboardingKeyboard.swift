import SwiftUI

/// The bottom row of a Mac keyboard, drawn so the dictation key can be found and watched. The key
/// for the person's own trigger is outlined in the accent; it fills and sinks while it is really
/// down, and once the double-tap is learned it keeps a quiet accent tint. A completed gesture sends
/// one ring out from the key (none under Reduce Motion: the fill alone says it).
///
/// Shapes only, no AppKit controls, so `ImageRenderer` can draw every state for the stills.
struct OnboardingKeyboard: View {
    let trigger: TriggerKey
    let isDown: Bool
    let isLearned: Bool
    /// Bumped once per completed gesture.
    let celebrations: Int
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Left to right: fn/globe, control, option, command, space, command, option.
    enum Key: CaseIterable {
        case fn, control, option, command, space, rightCommand, rightOption

        var width: CGFloat {
            switch self {
            case .fn, .control, .option, .rightOption: 52
            case .command, .rightCommand: 64
            case .space: 160
            }
        }

        var symbol: String? {
            switch self {
            case .fn: "globe"
            default: nil
            }
        }

        var glyph: String? {
            switch self {
            case .fn: "fn"
            case .control: "⌃"
            case .option, .rightOption: "⌥"
            case .command, .rightCommand: "⌘"
            case .space: nil
            }
        }

        var word: String? {
            switch self {
            case .control: "control"
            case .option, .rightOption: "option"
            case .command, .rightCommand: "command"
            case .fn, .space: nil
            }
        }
    }

    static func targets(for trigger: TriggerKey) -> Set<Key> {
        switch trigger {
        case .fn: [.fn]
        case .rightOption: [.rightOption]
        case .rightCommand: [.rightCommand]
        case .controlOption: [.control, .option]
        }
    }

    var body: some View {
        let targets = Self.targets(for: trigger)
        HStack(spacing: 6) {
            ForEach(Key.allCases, id: \.self) { key in
                KeyShape(
                    key: key, isTarget: targets.contains(key), isDown: isDown && targets.contains(key),
                    isLearned: isLearned, celebrations: celebrations, reduceMotion: reduceMotion)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.bgSunken)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)))
        .opacity(isEnabled ? 1 : 0.45)
        .saturation(isEnabled ? 1 : 0)
        .accessibilityElement()
        .accessibilityLabel("Keyboard, with the \(trigger.shortTitle) key marked")
        .accessibilityValue(isDown ? "Pressed" : (isLearned ? "Learned" : "Waiting"))
    }

    private struct KeyShape: View {
        let key: Key
        let isTarget: Bool
        let isDown: Bool
        let isLearned: Bool
        let celebrations: Int
        let reduceMotion: Bool

        private let height: CGFloat = 52
        private let radius: CGFloat = 7

        var body: some View {
            ZStack {
                // The key's side: a darker edge under the cap that the cap sinks onto when pressed.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.hairline)
                    .offset(y: 2)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(capFill)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(outline, lineWidth: isTarget ? 1.5 : 1))
                    .overlay(alignment: .topTrailing) { glyphLabel.padding(.top, 5).padding(.trailing, 6) }
                    .overlay(alignment: .bottomLeading) { wordLabel.padding(.bottom, 5).padding(.leading, 6) }
                    .offset(y: isDown ? 2 : 0)
                    .shadow(color: isDown ? Theme.phosphor.opacity(0.45) : .clear, radius: isDown ? 12 : 0)
                if isTarget, !reduceMotion {
                    KeyRing(trigger: celebrations, radius: radius)
                }
            }
            .frame(width: key.width, height: height)
            .animation(isDown ? Theme.Motion.press : Theme.Motion.cool, value: isDown)
            .animation(Theme.Motion.fade, value: isLearned)
        }

        private var capFill: Color {
            guard isTarget else { return Theme.bgRaised }
            if isDown { return Theme.phosphorFill }
            return isLearned ? Theme.phosphorTint : Theme.bgRaised
        }

        private var outline: Color {
            isTarget ? Theme.phosphor.opacity(isDown ? 0 : 0.9) : Theme.hairline
        }

        private var labelColor: Color {
            if isTarget, isDown { return Theme.onPhosphor }
            return isTarget ? Theme.textPrimary : Theme.textTertiary
        }

        @ViewBuilder private var glyphLabel: some View {
            if let symbol = key.symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(labelColor)
            } else if let glyph = key.glyph, key != .fn {
                Text(glyph).font(.system(size: 11, weight: .medium)).foregroundStyle(labelColor)
            }
        }

        @ViewBuilder private var wordLabel: some View {
            if key == .fn {
                Text("fn").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(labelColor)
            } else if let word = key.word {
                Text(word).font(.system(size: 8.5, weight: .medium)).foregroundStyle(labelColor)
            }
        }
    }

    /// One ring that leaves the key when a gesture completes: scale and opacity only.
    private struct KeyRing: View {
        let trigger: Int
        let radius: CGFloat
        @State private var expanded = true

        var body: some View {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.phosphor, lineWidth: 2)
                .scaleEffect(expanded ? 1.45 : 1)
                .opacity(expanded ? 0 : 0.8)
                .allowsHitTesting(false)
                .onChange(of: trigger) {
                    // Snap back without animating, then send the ring out on the next pass.
                    var reset = Transaction()
                    reset.disablesAnimations = true
                    withTransaction(reset) { expanded = false }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.55)) { expanded = true }
                    }
                }
        }
    }
}
