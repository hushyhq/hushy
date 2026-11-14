import SwiftUI

/// Accent palettes for page banners: bright, mid and deep tones over graphite (dark mode), or
/// pale/luminous tones over paper (light mode).
enum BannerPalette {
    case phosphor, amber, indigo, violet, teal, rose, blue

    /// Dark-mode mesh stops: bright, mid, deep — over graphite.
    var colors: (Color, Color, Color) {
        switch self {
        case .phosphor: (Color(hex: 0x9BC21E), Color(hex: 0x2E5E4E), Color(hex: 0x16241F))
        case .amber: (Color(hex: 0xE0A546), Color(hex: 0x7A3E22), Color(hex: 0x241712))
        case .indigo: (Color(hex: 0x7C86FF), Color(hex: 0x2B2F6B), Color(hex: 0x13142A))
        case .violet: (Color(hex: 0xB58CFF), Color(hex: 0x4B2A73), Color(hex: 0x1B1226))
        case .teal: (Color(hex: 0x4FD1C5), Color(hex: 0x1D5560), Color(hex: 0x0F1F24))
        case .rose: (Color(hex: 0xFF8FA3), Color(hex: 0x6E2A45), Color(hex: 0x24121A))
        case .blue: (Color(hex: 0x6FB6FF), Color(hex: 0x1F4F85), Color(hex: 0x0F1B2B))
        }
    }

    /// Light-mode mesh stops: a luminous pale tint, a soft mid tone and a cream base — same
    /// hue family as the dark palette, lifted to sit on paper instead of graphite.
    var lightColors: (Color, Color, Color) {
        switch self {
        case .phosphor: (Color(hex: 0xD8E9A0), Color(hex: 0xEDF2DC), Color(hex: 0xF8F8F1))
        case .amber: (Color(hex: 0xF3D9A8), Color(hex: 0xF6E7CE), Color(hex: 0xFAF5EB))
        case .indigo: (Color(hex: 0xCBD0FA), Color(hex: 0xE3E5FB), Color(hex: 0xF4F5FD))
        case .violet: (Color(hex: 0xE0CFFA), Color(hex: 0xEEE3FB), Color(hex: 0xF8F3FD))
        case .teal: (Color(hex: 0xBEEAE3), Color(hex: 0xDCF2EE), Color(hex: 0xF2FAF9))
        case .rose: (Color(hex: 0xFAD2DA), Color(hex: 0xFBE6EA), Color(hex: 0xFDF5F6))
        case .blue: (Color(hex: 0xC9E2FA), Color(hex: 0xE1EEFB), Color(hex: 0xF3F8FD))
        }
    }

    /// Deep ink tone used for the waveform and small accents on the light banner variant.
    var lightInk: Color {
        switch self {
        case .phosphor: Color(hex: 0x4C6B0F)
        case .amber: Color(hex: 0x8A5A1E)
        case .indigo: Color(hex: 0x3C46B0)
        case .violet: Color(hex: 0x6F3FAD)
        case .teal: Color(hex: 0x1C7A6E)
        case .rose: Color(hex: 0xB84C63)
        case .blue: Color(hex: 0x2A6BB0)
        }
    }
}

/// Atmospheric header for each page: a mesh gradient in the page's accent, with a fine grain
/// so it reads as material rather than a flat fill. Static (no animation), so it costs nothing
/// while scrolling. Dark mode keeps the graphite mesh with white text; light mode uses a
/// luminous pale mesh with dark ink text so the banner sits natively on the page instead of
/// reading as a pasted-in dark island.
struct PageBanner<Accessory: View>: View {
    typealias Palette = BannerPalette

    let title: String
    var emphasis: String? = nil
    let subtitle: String
    var palette: Palette = .phosphor
    @ViewBuilder var accessory: Accessory
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let isDark = scheme == .dark
        ZStack(alignment: .bottomLeading) {
            BannerBackground(palette: palette)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                (Text(title) + Text(emphasis.map { " " + $0 } ?? "").italic())
                    .font(.system(size: 30, weight: .regular, design: .serif))
                    .foregroundStyle(isDark ? .white : Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(isDark ? .white.opacity(0.72) : Theme.textSecondary)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                accessory.padding(.top, Theme.Space.s)
            }
            .padding(Theme.Space.xl + 4)
        }
        .frame(minHeight: 176)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet).strokeBorder(
            isDark ? .white.opacity(0.06) : .black.opacity(0.05), lineWidth: 0.5))
        .shadow(color: isDark ? .clear : Theme.cardShadow.opacity(Theme.cardShadowOpacity), radius: 16, y: 4)
    }
}

/// The mesh-gradient backdrop shared by banners and hero cards. Reads `colorScheme` from the
/// environment so callers that force `.dark` on their own container (like `HomeView`'s hero
/// card) still get the dark mesh, while page banners follow the live theme.
struct BannerBackground: View {
    let palette: BannerPalette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if scheme == .dark {
            darkMesh
        } else {
            lightMesh
        }
    }

    private var darkMesh: some View {
        let (bright, mid, deep) = palette.colors
        return ZStack {
            MeshGradient(
                width: 3, height: 3,
                points: meshPoints,
                colors: [
                    deep, deep, mid,
                    deep, mid.opacity(0.9), bright.opacity(0.75),
                    deep, deep, mid,
                ])
            // A soft highlight, like light falling across the material.
            RadialGradient(colors: [bright.opacity(0.35), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
                .blendMode(.screen)
            Grain().opacity(0.07).blendMode(.overlay)
        }
    }

    /// Luminous pale mesh for light mode: cream base with lime/tint highlights, a faint warm
    /// grain for texture instead of the dark variant's white-noise grain (which reads as dirt
    /// on a light surface).
    private var lightMesh: some View {
        let (bright, mid, base) = palette.lightColors
        return ZStack {
            MeshGradient(
                width: 3, height: 3,
                points: meshPoints,
                colors: [
                    base, base, mid,
                    base, mid, bright.opacity(0.85),
                    base, base, mid,
                ])
            RadialGradient(colors: [bright.opacity(0.55), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
                .blendMode(.multiply)
            Grain().opacity(0.035).blendMode(.multiply)
        }
    }

    private var meshPoints: [SIMD2<Float>] {
        [
            [0, 0], [0.55, 0], [1, 0],
            [0, 0.5], [0.62, 0.42], [1, 0.55],
            [0, 1], [0.45, 1], [1, 1],
        ]
    }
}

extension PageBanner where Accessory == EmptyView {
    init(title: String, emphasis: String? = nil, subtitle: String, palette: Palette = .phosphor) {
        self.init(title: title, emphasis: emphasis, subtitle: subtitle, palette: palette) { EmptyView() }
    }
}

/// Deterministic film grain, drawn once.
struct Grain: View {
    var body: some View {
        Canvas { context, size in
            var generator = SplitMix(seed: 7)
            let dots = Int(size.width * size.height / 30)
            for _ in 0..<dots {
                let x = CGFloat(generator.next() % UInt64(max(size.width, 1)))
                let y = CGFloat(generator.next() % UInt64(max(size.height, 1)))
                let shade = Double(generator.next() % 100) / 100
                context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(shade)))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
