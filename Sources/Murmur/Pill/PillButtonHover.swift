import SwiftUI

/// How the pill's icon-only ✕/✓ buttons answer a hover (founder, 2026-09-28: "the tick already
/// implies Done and X cancel — do we need to say it?").
enum PillButtonAffordance: String, CaseIterable, Sendable {
    /// A: a crisp 1.5 pt purple ring 3 pt outside the button, with the rim's tight glow. No text.
    case ring
    /// B: ✕ gets the ring; ✓ grows into a small lime "✓ Done" capsule over the pill (no reflow).
    case expand
    /// The earlier text hint bubble ("Cancel" / "Done").
    case hint
}

/// Which way an icon-only button reads.
enum PillButtonRole: Equatable {
    case cancel
    case confirm
}

extension EnvironmentValues {
    @Entry var pillButtonAffordance: PillButtonAffordance = .ring
}

/// The hover ring's geometry and glow, pure so it's pinned by tests.
enum PillHoverRing {
    static let lineWidth: CGFloat = 1.5
    /// Clear space between the button's edge and the ring's inner edge.
    static let gap: CGFloat = 3
    /// The ring's fade: the pill's hover time (`PillMotion.hoverDuration`).
    static let fade: Duration = .milliseconds(Int((PillMotion.standard.hoverDuration * 1_000).rounded()))

    /// The ring's diameter measured on the stroke's centre line, for a button of `diameter`.
    static func strokeDiameter(button diameter: CGFloat) -> CGFloat {
        diameter + 2 * (gap + lineWidth / 2)
    }
}

/// Hover behaviour for an icon-only pill button (`PillButtonAffordance`). The VoiceOver label
/// stays on the button ("Cancel" / "Done"); the ring and the expanded capsule are decoration.
struct PillButtonHoverModifier: ViewModifier {
    let hint: PillHint
    let role: PillButtonRole
    var diameter: CGFloat = 20
    @Environment(\.pillButtonAffordance) private var affordance
    @PillReduceMotion private var reduceMotion
    @Environment(\.pillMotion) private var motion
    @Environment(\.snapshotTooltipText) private var forcedText
    @State private var hovering = false

    private var isHovered: Bool { hovering || forcedText == hint.title }
    private var expands: Bool { affordance == .expand && role == .confirm }

    func body(content: Content) -> some View {
        switch affordance {
        case .hint:
            content.pillTooltip(hint)
        case .ring, .expand:
            content
                .overlay { if !expands { PillHoverRingView(diameter: diameter, isShown: isHovered) } }
                .anchorPreference(key: PillTooltipPreferenceKey.self, value: .bounds) { anchor in
                    expands && isHovered ? PillTooltipRequest(hint: hint, anchor: anchor, expand: true) : nil
                }
                .onHover { inside in
                    if reduceMotion { hovering = inside } else {
                        withAnimation(motion.animation(.hover)) { hovering = inside }
                    }
                }
        }
    }
}

/// The hover ring around an icon-only pill button (`PillHoverRing`). Decoration only.
struct PillHoverRingView: View {
    var diameter: CGFloat = 20
    let isShown: Bool

    var body: some View {
        let glow = PillHintBubble.rimGlow(hostScheme: .dark)
        let purple = PillHintPalette.color(PillHintPalette.purple)
        let size = PillHoverRing.strokeDiameter(button: diameter)
        Circle()
            .stroke(purple, lineWidth: PillHoverRing.lineWidth)
            .shadow(color: purple.opacity(glow.opacity), radius: glow.radius)
            .frame(width: size, height: size)
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// B's expanded ✓: a small lime capsule "✓ Done" drawn over the pill at the button, growing
/// toward the pill's middle, so the waveform never reflows. Decoration: the click still lands on
/// the ✓ button underneath.
struct ExpandedConfirmCapsule: View {
    let hint: PillHint
    static let height: CGFloat = 22

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            Text(hint.title).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Theme.onPhosphor)
        .padding(.horizontal, 9)
        .frame(height: Self.height)
        .background(Capsule().fill(Theme.phosphorFill))
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Centre for a capsule of `width` over `button`: its ✓ end stays on the button and it grows
    /// toward the pill's middle (leftward, or rightward on a left-edge vertical pill), kept inside.
    static func centre(button: CGRect, width: CGFloat, container: CGSize, growsRight: Bool) -> CGPoint {
        let half = width / 2
        let x = growsRight ? button.minX - 1 + half : button.maxX + 1 - half
        let clamped = min(max(x, half + 2), max(half + 2, container.width - half - 2))
        return CGPoint(x: clamped, y: button.midY)
    }
}

extension View {
    /// Hover for an icon-only pill button; see `PillButtonAffordance`.
    func pillButtonHover(_ hint: PillHint, role: PillButtonRole, diameter: CGFloat = 20) -> some View {
        modifier(PillButtonHoverModifier(hint: hint, role: role, diameter: diameter))
    }
}
