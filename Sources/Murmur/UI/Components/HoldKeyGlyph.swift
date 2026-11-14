import SwiftUI

/// Direction A from design/logo-fresh: the "h key". The Wave-H is the logo; this is the gesture.
/// Proposed as the in-app hold-to-talk visual (onboarding hotkey practice, the hotkey UI and the
/// pill's hold state where it fits the existing pill design). Rendered in snapshots only
/// (`Snapshots.renderBrand`) until the founder OKs it; nothing live uses it yet.
struct HoldKeyGlyph: View {
    var size: CGFloat = 56
    var held = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let isDark = scheme == .dark
        let corner = size * 0.22
        let lift = held ? size * 0.02 : size * 0.07
        ZStack(alignment: .bottom) {
            // The key's side: what you see below the face until it is pressed down.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(isDark ? Color(hex: 0x0A0B0D) : Color(hex: 0xA8ADA5))
            Capsule()
                .fill(Theme.phosphorFill)
                .frame(width: size * 0.74, height: size * 0.05)
                .padding(.bottom, size * 0.035)
                .shadow(color: Theme.phosphor.opacity(held ? 0.7 : 0.35), radius: size * 0.06)
            // The face, with the h on it.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(
                    colors: isDark ? [Color(hex: 0x2B2F37), Color(hex: 0x171A1F)] : [.white, Color(hex: 0xEEF0EB)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(isDark ? .white.opacity(0.12) : .black.opacity(0.08), lineWidth: 1))
                .overlay {
                    HGlyph()
                        .stroke(isDark ? Theme.phosphorFill : Theme.textPrimary,
                                style: StrokeStyle(lineWidth: size * 0.088, lineCap: .round, lineJoin: .round))
                        .frame(width: size * 0.55, height: size * 0.55)
                        .shadow(color: isDark ? Theme.phosphor.opacity(held ? 0.8 : 0.45) : .clear, radius: size * 0.08)
                }
                .padding(.bottom, lift)
        }
        .frame(width: size, height: size)
        .scaleEffect(held ? 0.97 : 1)
        .shadow(color: .black.opacity(isDark ? 0.35 : 0.12), radius: size * 0.05, y: size * 0.03)
        .accessibilityHidden(true)
    }
}

/// The geometric lowercase h shared by the key and the wordmark. 100-box: stem at x 27 from y 8
/// to 92, shoulder rising to y 40 and a right leg at x 73; stroked 16 wide with round caps.
struct HGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 100
        let x = rect.minX, y = rect.minY
        var path = Path()
        path.move(to: CGPoint(x: x + 27 * s, y: y + 8 * s))
        path.addLine(to: CGPoint(x: x + 27 * s, y: y + 92 * s))
        path.move(to: CGPoint(x: x + 27 * s, y: y + 62 * s))
        path.addCurve(to: CGPoint(x: x + 50 * s, y: y + 40 * s),
                      control1: CGPoint(x: x + 27 * s, y: y + 46 * s), control2: CGPoint(x: x + 36 * s, y: y + 40 * s))
        path.addCurve(to: CGPoint(x: x + 73 * s, y: y + 62 * s),
                      control1: CGPoint(x: x + 64 * s, y: y + 40 * s), control2: CGPoint(x: x + 73 * s, y: y + 48 * s))
        path.addLine(to: CGPoint(x: x + 73 * s, y: y + 92 * s))
        return path
    }
}
