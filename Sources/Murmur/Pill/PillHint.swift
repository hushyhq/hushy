import SwiftUI

/// What a pill button's hover hint says: one word ("Cancel", "Done") and the key that does the
/// same. The style decides how much of it shows (`PillHintStyle`). "Done", not "Paste": ✓ also copies instead of pasting (no text field,
/// focus moved) and finishes notes and actions (DECISIONS 2026-09-28).
struct PillHint: Equatable {
    let title: String
    var key: String?
    /// A second key that does the same ("Cancel esc or control"), when there is one.
    var alternateKey: String?

    /// The compact one-row form ("Cancel [esc]", "Cancel [esc] or [control]"), `[x]` rendering as
    /// a key cap.
    var compact: String {
        let keys = [key, alternateKey].compactMap { $0 }.map { "[\($0)]" }.joined(separator: " or ")
        return keys.isEmpty ? title : "\(title) \(keys)"
    }

    static let cancel = PillHint(title: "Cancel", key: "esc")
    /// Just "Done": ✓ and ⏎ only ever paste (paste-and-send removed, founder 2026-09-28).
    static let finish = PillHint(title: "Done", key: "⏎")
    /// Hands-free dictation's ✓ and ✕ name their keys (founder 2026-10-24: "Enter to paste, esc to cancel").
    /// "Paste" again, over the 2026-09-28 "Done": the founder's daily flow is double-tap fn, talk, Enter.
    static let paste = PillHint(title: "Paste", key: "enter")
    static let discardNote = PillHint(title: "Discard note")
    static let saveNote = PillHint(title: "Stop and save")
    /// ✓ on the voice-action pill. "Send" and "return" are the words Settings and onboarding use.
    static let runAction = PillHint(title: "Send", key: "return")
}

/// The hover-hint look. `.compact` ships today; A/B/C are the founder's shortlist (2026-09-28:
/// purple hints, a founder override of "purple is the model" for these hints only).
enum PillHintStyle: String, CaseIterable, Sendable {
    /// One small row on a dark capsule: "Cancel esc".
    case compact
    /// A: the word alone, 15 pt, on a deep purple-tinted capsule with a hairline and a soft glow.
    case tinted
    /// B: A plus a quiet key cap ("Cancel · esc", "Done · ⏎").
    case tintedKeys
    /// C: a solid purple capsule with high-contrast ink and a subtle inner highlight.
    case solid
    /// The founder's final candidate: A's flat tinted fill with the word alone, and a crisp 1 pt
    /// purple rim that carries a tight glow hugging the edge — a lit rim, not a cloud.
    case rim

    /// Only B shows key caps.
    var showsKeys: Bool { self == .tintedKeys }
}

extension EnvironmentValues {
    @Entry var pillHintStyle: PillHintStyle = .rim
}

/// The hint colours as hex, so the WCAG test checks the exact values drawn (`ThemeContrastTests`).
enum PillHintPalette {
    static let nearBlack: UInt32 = 0x0E0F14
    static let purple: UInt32 = 0x8B97FF
    /// #8B97FF at 16% over near-black.
    static let tintedSurface: UInt32 = 0x22253A
    static let text: UInt32 = 0xF4F5FF
    static let mutedText: UInt32 = 0xA3A8C8
    static let keyFill: UInt32 = 0x393E65
    static let keyText: UInt32 = 0xC9CEFF
    static let solidFillDark: UInt32 = 0x8B97FF
    static let solidInkDark: UInt32 = 0x0E1014
    static let solidFillLight: UInt32 = 0x4A5AE6
    static let solidInkLight: UInt32 = 0xFFFFFF

    /// `top` at `alpha` over `bottom`, per channel, rounded — the flattened colour a reader sees.
    static func blend(_ top: UInt32, alpha: Double, over bottom: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let t = Double((top >> shift) & 0xFF)
            let b = Double((bottom >> shift) & 0xFF)
            return UInt32((b + (t - b) * alpha).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    static func color(_ hex: UInt32) -> Color { Color(hex: hex) }
}

/// A hint in style A, B or C: a roomy capsule with a small notch pointing at its button.
struct PillHintBubble: View {
    let hint: PillHint
    let style: PillHintStyle
    /// The system appearance around the (always-dark) pill: C uses the light purple on light.
    let hostScheme: ColorScheme
    /// Which side of the hint its button is on: below it (bottom anchor), above it (top anchor),
    /// or beside it (a vertical pill at a side edge).
    let pointing: Edge
    /// How far the notch sits from the capsule's centre, so it stays on the button.
    var notchOffset: CGFloat = 0

    var body: some View {
        Group {
            switch pointing {
            case .bottom: VStack(spacing: 0) { capsule; notch }
            case .top: VStack(spacing: 0) { notch; capsule }
            case .trailing: HStack(spacing: 0) { capsule; notch }
            case .leading: HStack(spacing: 0) { notch; capsule }
            }
        }
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var capsule: some View {
        HStack(spacing: 7) {
            Text(hint.title).font(.system(size: 15, weight: .medium)).foregroundStyle(ink)
            if style.showsKeys { keys }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Capsule().fill(fill))
        .overlay(border)
        .shadow(color: style == .rim ? .clear : glow, radius: 10)
    }

    static let rimWidth: CGFloat = 1

    /// The rim's glow: tight around the edge; much subtler in light mode.
    static func rimGlow(hostScheme: ColorScheme) -> (radius: CGFloat, opacity: Double) {
        hostScheme == .light ? (radius: 2, opacity: 0.2) : (radius: 3, opacity: 0.6)
    }

    @ViewBuilder
    private var keys: some View {
        if let key = hint.key {
            muted("·")
            keyCap(key)
        }
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(PillHintPalette.color(PillHintPalette.mutedText))
    }

    private func keyCap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(PillHintPalette.color(PillHintPalette.keyText))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4.5).fill(PillHintPalette.color(PillHintPalette.keyFill)))
    }

    private var notch: some View {
        let isVertical = pointing == .top || pointing == .bottom
        return HintNotch(pointing: pointing)
            .fill(fill)
            .frame(width: isVertical ? 12 : 6, height: isVertical ? 6 : 12)
            .offset(x: isVertical ? notchOffset : 0, y: isVertical ? 0 : notchOffset)
    }

    private var isSolid: Bool { style == .solid }

    private var fill: Color {
        guard isSolid else { return PillHintPalette.color(PillHintPalette.tintedSurface) }
        return PillHintPalette.color(hostScheme == .light ? PillHintPalette.solidFillLight : PillHintPalette.solidFillDark)
    }

    private var ink: Color {
        guard isSolid else { return PillHintPalette.color(PillHintPalette.text) }
        return PillHintPalette.color(hostScheme == .light ? PillHintPalette.solidInkLight : PillHintPalette.solidInkDark)
    }

    @ViewBuilder
    private var border: some View {
        if style == .rim {
            let glow = Self.rimGlow(hostScheme: hostScheme)
            let purple = PillHintPalette.color(PillHintPalette.purple)
            Capsule().strokeBorder(purple, lineWidth: Self.rimWidth)
                .shadow(color: purple.opacity(glow.opacity), radius: glow.radius)
        } else if isSolid {
            // A subtle inner highlight along the top edge.
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0)], startPoint: .top, endPoint: .center),
                lineWidth: 1)
        } else {
            Capsule().strokeBorder(PillHintPalette.color(PillHintPalette.purple).opacity(0.45), lineWidth: 0.5)
        }
    }

    private var glow: Color {
        PillHintPalette.color(PillHintPalette.purple).opacity(isSolid ? 0.35 : 0.25)
    }
}

/// A small triangle pointing from the hint at its button.
struct HintNotch: Shape {
    let pointing: Edge

    func path(in rect: CGRect) -> Path {
        let (base1, base2, tip): (CGPoint, CGPoint, CGPoint) = switch pointing {
        case .bottom: (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY))
        case .top: (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.minY))
        case .trailing: (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.midY))
        case .leading: (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY))
        }
        var path = Path()
        path.move(to: base1)
        path.addLine(to: base2)
        path.addLine(to: tip)
        path.closeSubpath()
        return path
    }
}
