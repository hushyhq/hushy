import SwiftUI

/// "Afterglow" motion, glow and ink tokens (see docs/design/DESIGN-LANGUAGE.md §2).
///
/// The rule the tokens encode: only *live* things glow (mic open, words arriving, something
/// waiting for the user's ✓), and everything that stops being live *cools* — it decays along
/// `Motion.cool` rather than blinking off. Animate transform and opacity only; the pill's capsule
/// size is the one sanctioned exception (one spring per state change, never per audio frame).
extension Theme {
    enum Motion {
        /// Button press in/out. Paired with `PressableStyle` so feedback lands on the first frame.
        static let press = Animation.spring(response: 0.16, dampingFraction: 0.86)
        /// Hover tints and focus rings.
        static let hover = Animation.easeOut(duration: 0.12)
        /// Opacity-only changes, and the Reduce Motion fallback for every spatial animation.
        static let fade = Animation.easeOut(duration: 0.16)
        /// State changes in place: pill state, toggles, a selection plate moving between rows.
        static let snappy = Theme.snappy
        /// Anything that travels: panes, sheets, sidebar collapse.
        static let settle = Theme.settle
        /// Success only (✓ draw, "Added"): one overshoot. Never used for errors.
        static let pop = Animation.spring(response: 0.32, dampingFraction: 0.62)
        /// The afterglow decay: live → rest, wet ink → dry ink. A trailing effect — the state
        /// has already changed; only the glow fades behind it, so 600 ms never blocks anyone.
        static let cool = Animation.timingCurve(0.05, 0.7, 0.1, 1, duration: coolDuration)
        static let coolDuration: Double = 0.6
        /// Per-item delay for list and word reveals; items past `staggerCap` share the last delay.
        static let stagger: Double = 0.024
        static let staggerCap = 6

        /// The spatial animation to use, degrading to a cross-fade under Reduce Motion.
        static func spatial(_ animation: Animation = settle, reduceMotion: Bool) -> Animation {
            reduceMotion ? fade : animation
        }

        /// Delay for the `index`-th item of a staggered reveal.
        static func staggerDelay(_ index: Int) -> Double {
            Double(min(max(index, 0), staggerCap)) * stagger
        }
    }

    /// Text that exists but isn't final yet — raw ASR while cleanup runs, a note's newest
    /// streaming line. Dries to `textPrimary`.
    static let inkWet = Color.white.opacity(0.46)
}

/// Which live signal a glow speaks for: `phosphor` (lime, "this is you") or `working` (purple,
/// "this is the model"). The two never share a control (docs/product/UI-ROUND-2026-09-28.md §3).
enum LiveGlowKind {
    case phosphor
    case working
}

extension View {
    /// Afterglow: live elements get a *light* shadow, never a dark one. Dark surfaces only — on
    /// paper a glow reads as a blur bug, so light mode gets a 1 pt ring instead. Defaults to the
    /// lime `phosphor` glow; pass `kind: .working` for the pill shimmer's purple halo
    /// (`workingGlow`), which is dark-only with no light-mode ring substitute — it never appears
    /// on window surfaces, only inside the always-dark pill.
    func liveGlow(_ isLive: Bool, radius: CGFloat = 8, scheme: ColorScheme, kind: LiveGlowKind = .phosphor) -> some View {
        modifier(LiveGlow(isLive: isLive, radius: radius, scheme: scheme, kind: kind))
    }
}

private struct LiveGlow: ViewModifier {
    let isLive: Bool
    let radius: CGFloat
    let scheme: ColorScheme
    var kind: LiveGlowKind = .phosphor

    func body(content: Content) -> some View {
        switch kind {
        case .phosphor:
            if scheme == .dark {
                content.shadow(color: Theme.phosphorFill.opacity(isLive ? 0.35 : 0), radius: isLive ? radius : 0)
            } else {
                content
            }
        case .working:
            // Pill-only, always dark — no light-mode ring substitute needed.
            content.shadow(color: Theme.pillWorking.opacity(isLive ? 0.25 : 0), radius: isLive ? radius : 0)
        }
    }
}

/// Press feedback on the first frame: a 0.97 dip and a slight dim on mouse-down, springing back
/// on release. Under Reduce Motion only the dim remains.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}
