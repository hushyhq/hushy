import SwiftUI

/// One of the two small round buttons that flank the waveform — muted ✕ to cancel/discard,
/// phosphor ✓ to finish. Matches the Wispr reference: two small buttons, mic/waveform as the
/// highlight, no oversized stop control, and a small dark tooltip on hover ("Cancel · esc",
/// "Done") like the Wispr reference.
struct PillCircleButton: View {
    enum Tint { case muted, phosphor }

    let glyph: String
    let tint: Tint
    /// The hover hint, e.g. "Cancel" (esc) or "Done" (⏎).
    let tooltip: PillHint
    /// The voice-action pill's buttons: the hover also names the key that does the same
    /// (`pillKeyHint`). Dictation's buttons keep the ring alone.
    var namesKey = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint == .phosphor ? Theme.onPhosphor : .white.opacity(0.8))
                .frame(width: 20, height: 20)
                .background(Circle().fill(tint == .phosphor ? Theme.phosphorFill : .white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        if namesKey {
            button.pillKeyHint(tooltip)
        } else {
            button.pillButtonHover(tooltip, role: glyph == "xmark" ? .cancel : .confirm)
        }
    }
}

/// A hover hint request bubbled up from a pill button to `PillView`, which draws it outside the
/// capsule's clip, centred on the button (`anchor`) — not on the pill.
struct PillTooltipRequest: Equatable {
    let hint: PillHint
    let anchor: Anchor<CGRect>
    /// B's expanded ✓ ("✓ Done" over the button) rather than a hint bubble.
    var expand = false
    /// Always the small one-row hint with its key cap ("Cancel esc"), whatever the hint style.
    var namesKey = false
}

/// Bubbles the hovered button's hint (if any) up past the pill's clipped capsule.
struct PillTooltipPreferenceKey: PreferenceKey {
    static var defaultValue: PillTooltipRequest? { nil }
    static func reduce(value: inout PillTooltipRequest?, nextValue: () -> PillTooltipRequest?) {
        // SwiftUI seeds `value` with nil for each pass, so "last non-nil wins" self-clears.
        guard let next = nextValue() else { return }
        value = next
    }
}

/// Where a hint sits: centred on its button, 8 pt clear of it (above; below at the top edge),
/// kept 4 pt inside the panel. Pure, so the geometry is unit-tested.
enum PillTooltipPlacement {
    static let gap: CGFloat = 8
    static let margin: CGFloat = 4

    static func centre(
        button: CGRect, bubble: CGSize, container: CGSize, opensDownward: Bool, gap: CGFloat = gap
    ) -> CGPoint {
        let half = bubble.width / 2
        let x = min(max(button.midX, half + margin), max(half + margin, container.width - half - margin))
        let y = opensDownward ? button.maxY + gap + bubble.height / 2 : button.minY - gap - bubble.height / 2
        return CGPoint(x: x, y: y)
    }

    /// Beside a vertical side pill: the hint sits `gap` to the right (or left) of the button,
    /// vertically centred on it, kept inside the panel.
    static func centreBeside(
        button: CGRect, bubble: CGSize, container: CGSize, toRight: Bool, gap: CGFloat = gap
    ) -> CGPoint {
        let halfWidth = bubble.width / 2
        let beside = toRight ? button.maxX + gap + halfWidth : button.minX - gap - halfWidth
        // Kept inside the panel sideways too: a long hint in a narrow panel is pushed in, not cut.
        let x = min(max(beside, halfWidth + margin), max(halfWidth + margin, container.width - halfWidth - margin))
        let half = bubble.height / 2
        let y = min(max(button.midY, half + margin), max(half + margin, container.height - half - margin))
        return CGPoint(x: x, y: y)
    }

    /// A notch offset of `delta` along a side of `length`, kept `inset` clear of the ends.
    static func notchOffset(along delta: CGFloat, length: CGFloat, inset: CGFloat) -> CGFloat {
        let limit = max(0, length / 2 - inset)
        return min(max(delta, -limit), limit)
    }

    /// The notch's offset from the hint's centre so it points at the button, kept on the
    /// capsule's straight edge (clear of its rounded ends).
    static func notchOffset(button: CGRect, centre: CGPoint, bubbleWidth: CGFloat) -> CGFloat {
        let limit = max(0, bubbleWidth / 2 - 14)
        return min(max(button.midX - centre.x, -limit), limit)
    }
}

/// The hover hint: one compact row on a dark capsule, like the pill itself — "Cancel  esc",
/// "Done ⏎". `[x]` in the text renders as a small graphite key cap.
struct TooltipBubble: View {
    let text: String

    var body: some View {
        PillHintWords(text: text)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color(hex: 0x16181C)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    nonisolated static func tokens(_ line: String) -> [(text: String, isKey: Bool)] {
        var result: [(String, Bool)] = []
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            let before = rest[..<open].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty { result.append((before, false)) }
            result.append((String(rest[rest.index(after: open)..<close]), true))
            rest = rest[rest.index(after: close)...]
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append((tail, false)) }
        return result.map { (text: $0.0, isKey: $0.1) }
    }
}

/// A hint's words in one row, `[x]` drawn as a small graphite key cap: "Cancel esc". Used inside
/// the hover bubble, and in the card footer, where the words take the title's place instead.
struct PillHintWords: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(TooltipBubble.tokens(text).enumerated()), id: \.offset) { _, token in
                if token.isKey {
                    Text(token.text)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 14)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(.white.opacity(0.12)))
                } else {
                    Text(token.text)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Reports a hover-tooltip request after a short delay, so `PillView` can draw the tooltip above
/// the pill (see `PillTooltipPreferenceKey`). Appears with a quick fade + scale, no delay on
/// dismiss so it never lingers after the mouse leaves.
struct PillTooltipModifier: ViewModifier {
    let hint: PillHint
    /// Snapshot mode forces the tooltip to show without a live hover, so `--snapshots` can
    /// capture it (see `Snapshots.swift`).
    @Environment(\.snapshotForceTooltip) private var forceVisible
    /// Snapshot mode: show only the hint whose title matches (e.g. just the ✕'s).
    @Environment(\.snapshotTooltipText) private var forcedText
    @Environment(\.pillMotion) private var motion
    @PillReduceMotion private var reduceMotion
    @State private var isHovering = false
    @State private var isShown = false

    private var isVisible: Bool { isShown || forceVisible || forcedText == hint.title }

    func body(content: Content) -> some View {
        content
            .anchorPreference(key: PillTooltipPreferenceKey.self, value: .bounds) { anchor in
                isVisible ? PillTooltipRequest(hint: hint, anchor: anchor) : nil
            }
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    let delayToken = UUID()
                    hoverToken = delayToken
                    DispatchQueue.main.asyncAfter(deadline: .now() + motion.hintDelay) {
                        guard hoverToken == delayToken, isHovering else { return }
                        withAnimation(motion.animation(.open, reduceMotion: reduceMotion)) { isShown = true }
                    }
                } else {
                    withAnimation(motion.animation(.hover)) { isShown = false }
                }
            }
    }

    @State private var hoverToken: UUID?
}

/// Hover for the voice-action pill's ✕ and ✓: the ring dictation's buttons get, at once, and after
/// a moment a small hint that names the key doing the same ("Cancel esc", "Send return"). This is
/// where a person learns the keys, in place of a row of key caps on the pill (founder, 2026-10-07:
/// "when you hover over the X, it should say what shortcut we could use to cancel").
struct PillKeyHintModifier: ViewModifier {
    let hint: PillHint
    var diameter: CGFloat = 20
    @PillReduceMotion private var reduceMotion
    @Environment(\.pillMotion) private var motion
    @Environment(\.snapshotTooltipText) private var forcedText
    @State private var isHovering = false
    @State private var isShown = false
    @State private var hoverToken: UUID?

    /// The ring answers at once; the words wait this long, so a pointer passing over shows nothing.
    static let delay: TimeInterval = PillMotion.standard.hintDelay

    private var isForced: Bool { forcedText == hint.title }

    func body(content: Content) -> some View {
        content
            .overlay { PillHoverRingView(diameter: diameter, isShown: isHovering || isForced) }
            .anchorPreference(key: PillTooltipPreferenceKey.self, value: .bounds) { anchor in
                isShown || isForced ? PillTooltipRequest(hint: hint, anchor: anchor, namesKey: true) : nil
            }
            .onHover { hovering in
                if reduceMotion { isHovering = hovering } else {
                    withAnimation(motion.animation(.hover)) { isHovering = hovering }
                }
                guard hovering else {
                    hoverToken = nil
                    withAnimation(motion.animation(.hover)) { isShown = false }
                    return
                }
                let token = UUID()
                hoverToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + motion.hintDelay) {
                    guard hoverToken == token else { return }
                    withAnimation(motion.animation(.fade)) { isShown = true }
                }
            }
    }
}

extension View {
    /// Attaches a `PillTooltipModifier` with `hint` shown after a brief hover.
    func pillTooltip(_ hint: PillHint) -> some View {
        modifier(PillTooltipModifier(hint: hint))
    }

    /// The ring, then the key's name; see `PillKeyHintModifier`.
    func pillKeyHint(_ hint: PillHint, diameter: CGFloat = 20) -> some View {
        modifier(PillKeyHintModifier(hint: hint, diameter: diameter))
    }
}
