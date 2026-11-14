import SwiftUI

// The controls of the one confirm-card style (ACTIONS-IA §4, DESIGN-LANGUAGE §5.8), shared by
// the pill's action card, the Assistant's chat card and the learned-term suggestion in History.
// Colors are semantic (`.primary`) so each host's color scheme decides the ink.

/// The ✓ that names its consequence ("✓ Add", "✓ Run"). While it waits for the user it
/// breathes: the only live thing on a card.
struct ConfirmVerbButton: View {
    let verb: String
    /// What VoiceOver reads, e.g. "Add Priya to your dictionary". Defaults to "Confirm: Add".
    var accessibilityText: String?
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { ConfirmVerbCapsule(verb: verb) }
            .buttonStyle(PressableStyle(scale: 0.94))
            .accessibilityLabel(accessibilityText ?? "Confirm: \(verb)")
            .help(help ?? verb)
    }
}

/// The ✓ capsule's look, for hosts that wrap it in their own button.
struct ConfirmVerbCapsule: View {
    let verb: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            Text(verb).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.onPhosphor)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Theme.phosphorFill))
        .modifier(BreathingGlow())
    }
}

/// A small round glyph button on a confirm row (✕, ✎), muted until pressed.
struct ConfirmGlyphButton: View {
    let symbol: String
    let accessibilityText: String
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { ConfirmGlyph(symbol: symbol) }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel(accessibilityText)
            .help(help ?? accessibilityText)
    }
}

/// The round glyph's look.
struct ConfirmGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.primary.opacity(0.8))
            .frame(width: 20, height: 20)
            .background(Circle().fill(.primary.opacity(0.12)))
    }
}

/// "Undo" on a row that recorded a decision. Dry ink, not lime: once decided, nothing is
/// waiting for the user any more (DESIGN-LANGUAGE §5.8, "cools to ✓ Added · Undo in dry ink").
struct UndoLink: View {
    var title = "Undo"
    let accessibilityText: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .underline(hovering, color: Theme.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .accessibilityLabel(accessibilityText)
    }
}

/// A ✓ that lands lit (the `pop` flash) and then cools to dry ink along `Motion.cool`: the
/// afterglow of a decision. Snapshots and Reduce Motion show the cooled state.
struct CoolingCheckmark: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLit = true

    var body: some View {
        let lit = isLit && !isSnapshot && !reduceMotion
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(lit ? Theme.phosphor : Theme.textSecondary)
            .scaleEffect(lit ? 1.15 : 1)
            .onAppear {
                guard !isSnapshot, !reduceMotion else { return }
                withAnimation(Theme.Motion.cool.delay(0.12)) { isLit = false }
            }
            .accessibilityHidden(true)
    }
}

/// "Waiting for you": a slow phosphor glow that breathes around the ✓ while a proposal is
/// pending (`Motion` breathe, 2.4 s). Snapshots and Reduce Motion show a static ring, so the
/// state still reads without motion.
struct BreathingGlow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var inhaled = false

    func body(content: Content) -> some View {
        let isStatic = reduceMotion || isSnapshot
        content
            .shadow(color: Theme.phosphorFill.opacity(isStatic ? 0.35 : (inhaled ? 0.5 : 0.12)), radius: isStatic ? 5 : (inhaled ? 7 : 3))
            .onAppear {
                guard !isStatic else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { inhaled = true }
            }
    }
}
