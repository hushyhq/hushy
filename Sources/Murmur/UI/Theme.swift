import AppKit
import SwiftUI

enum Theme {
    // MARK: Colors

    struct HexPair: Equatable, Sendable {
        let light: UInt32
        let dark: UInt32
    }

    enum Hex {
        static let bgBase = HexPair(light: 0xF6F7F3, dark: 0x0B0C0F)
        static let bgRaised = HexPair(light: 0xFFFFFE, dark: 0x15171B)
        static let bgSunken = HexPair(light: 0xECEEE7, dark: 0x08090B)
        static let hairline = HexPair(light: 0xDFE2D6, dark: 0x22262C)
        static let hairlineStrong = HexPair(light: 0xC9CDBD, dark: 0x343941)
        static let textPrimary = HexPair(light: 0x1B1D17, dark: 0xECEEF2)
        static let textSecondary = HexPair(light: 0x565B50, dark: 0x9AA1AD)
        static let textTertiary = HexPair(light: 0x62675C, dark: 0x8B939E)
        static let phosphor = HexPair(light: 0x4C6B0F, dark: 0xC6F432)
        static let phosphorFill = HexPair(light: 0xC6F432, dark: 0xC6F432)
        static let phosphorTint = HexPair(light: 0xE7EFCB, dark: 0x232B12)
        static let onPhosphor = HexPair(light: 0x0E1014, dark: 0x0E1014)
        static let working = HexPair(light: 0x4A5AE6, dark: 0x8B97FF)
        static let onWorking = HexPair(light: 0xFFFFFF, dark: 0x0E1014)
        static let workingTint = HexPair(light: 0xE8EBFF, dark: 0x1E2140)
        static let drop = HexPair(light: 0x9E5C00, dark: 0xFFC24D)
        static let saidInk = HexPair(light: 0x2F420A, dark: 0xD9F77A)
        static let success = HexPair(light: 0x1D7B4B, dark: 0x3DDC97)
        static let warning = HexPair(light: 0x9A5C00, dark: 0xFFB547)
        static let error = HexPair(light: 0xC42D43, dark: 0xFF5C72)
        static let pill = HexPair(light: 0x111317, dark: 0x111317)
        static let pillInk = HexPair(light: 0xECEEF2, dark: 0xECEEF2)
        static let pillInkSecondary = HexPair(light: 0x9AA1AD, dark: 0x9AA1AD)
        static let pillInkTertiary = HexPair(light: 0x8B939E, dark: 0x8B939E)
        static let action = HexPair(light: 0x111317, dark: 0xECEEF2)
        static let onAction = HexPair(light: 0xF6F7F3, dark: 0x0B0C0F)
        static let saidMarkLight: UInt32 = 0xE3F0A8
    }

    static let bgBase = dynamic(Hex.bgBase)
    static let bgRaised = dynamic(Hex.bgRaised)
    static let bgSunken = dynamic(Hex.bgSunken)
    static let hairline = dynamic(Hex.hairline)
    static let hairlineStrong = dynamic(Hex.hairlineStrong)
    static let textPrimary = dynamic(Hex.textPrimary)
    static let textSecondary = dynamic(Hex.textSecondary)
    static let textTertiary = dynamic(Hex.textTertiary)
    static let phosphor = dynamic(Hex.phosphor)
    static let said = phosphor
    static let phosphorFill = dynamic(Hex.phosphorFill)
    static let phosphorTint = dynamic(Hex.phosphorTint)
    static let onPhosphor = Color(hex: Hex.onPhosphor.light)
    static let working = dynamic(Hex.working)
    static let wrote = working
    static let workingFill = working
    static let onWorking = dynamic(Hex.onWorking)
    static let workingTint = dynamic(Hex.workingTint)
    static let drop = dynamic(Hex.drop)
    static let saidInk = dynamic(Hex.saidInk)
    static let pillWorking = Color(hex: Hex.working.dark)
    static let pillIdleMark = Color(hex: Hex.pillInkSecondary.light)

    /// Deprecated alias for `working`, kept for one release so existing call sites that don't
    /// carry the new semantic meaning (decorative use, not "the model is working") don't need to
    /// change this round. New call sites should use `working` directly.
    @available(*, deprecated, renamed: "working")
    static let processing = working
    /// Deprecated alias for `pillWorking`, kept for one release. New call sites should use
    /// `pillWorking` directly.
    @available(*, deprecated, renamed: "pillWorking")
    static let pillProcessing = pillWorking
    static let success = dynamic(Hex.success)
    static let warning = dynamic(Hex.warning)
    static let error = dynamic(Hex.error)
    static let pill = Color(hex: Hex.pill.light)
    static let pillSurface = pill.opacity(0.92)
    static let selection = dynamic(light: 0xEAECE2, dark: 0x1F2229)

    /// Distinct, low-saturation hues for speaker name chips in a note's transcript — chosen to
    /// stay legible as text-on-tint in both themes and to read as "distinct people," not a
    /// rainbow of unrelated brand colors. Index chosen by
    /// `SpeakerColorAssignment.colorIndex(forSpeakerId:paletteSize:)` (`MurmurCore`), so the same
    /// speaker always gets the same chip color for the life of a note. "You" never draws from
    /// this palette — see `SpeakerChip`'s own styling.
    static let speakerColors: [Color] = [
        dynamic(light: 0x2F6FB2, dark: 0x7FB2E8),  // blue
        dynamic(light: 0xB2552F, dark: 0xE8A67F),  // amber
        dynamic(light: 0x5C8A3A, dark: 0xA6D17F),  // green
        dynamic(light: 0x9A4FAE, dark: 0xD79BE8),  // violet
        dynamic(light: 0xB23F63, dark: 0xE87FA0),  // rose
        dynamic(light: 0x3F9A93, dark: 0x7FDCD3),  // teal
    ]

    /// Soft elevation shadow for raised surfaces in light mode (near-invisible in dark, where
    /// contrast already comes from the surface color itself).
    static let cardShadow = dynamic(light: 0x9AA08C, dark: 0x000000)
    static var cardShadowOpacity: Double { 0.14 }

    // MARK: Spacing (4 pt grid)

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let section: CGFloat = 48
    }

    // MARK: Radii — deliberately not uniform

    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 10
        static let sheet: CGFloat = 14
    }

    // MARK: Motion

    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let settle = Animation.spring(response: 0.45, dampingFraction: 0.9)
    static let fade = Animation.easeOut(duration: 0.12)

    /// The timeline's motion vocabulary is exactly two curves: `settle` (one spring) for
    /// anything that moves in space — a pane sliding in, a bar appearing — and `fade` (one short
    /// ease) for opacity, hover and selection tints. Under Reduce Motion a spatial move degrades
    /// to the opacity ease (content cross-fades in place instead of travelling); fades stay, since
    /// an opacity change isn't motion.
    static func spatial(reduceMotion: Bool) -> Animation { reduceMotion ? fade : settle }

    /// The matching transition for a trailing inspector pane: slide + fade, or just fade under
    /// Reduce Motion.
    static func trailingPane(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    // MARK: Type

    enum Font {
        static let hero = SwiftUI.Font.system(size: 46, weight: .regular, design: .serif)
        static let heroNumber = SwiftUI.Font.system(size: 64, weight: .regular, design: .serif).monospacedDigit()
        static let section = SwiftUI.Font.system(size: 30, weight: .regular, design: .serif)
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let emphasis = SwiftUI.Font.system(size: 16, weight: .medium)
        static let body = SwiftUI.Font.system(size: 14.5)
        static let caption = SwiftUI.Font.system(size: 12, weight: .medium)
        static let eyebrow = SwiftUI.Font.system(size: 12, weight: .semibold).width(.expanded)
        static let mono = SwiftUI.Font.system(size: 13, design: .monospaced)
        static let data = SwiftUI.Font.system(size: 14, design: .monospaced).monospacedDigit()
    }

    private static func dynamic(_ pair: HexPair) -> Color { dynamic(light: pair.light, dark: pair.dark) }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
