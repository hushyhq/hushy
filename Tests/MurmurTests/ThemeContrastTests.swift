import Foundation
import Testing
@testable import Murmur

/// WCAG 2.x contrast-ratio guard for the two live-signal colours (docs/product/UI-ROUND-2026-09-28.md
/// §3: "lime is you; purple is the model"). Computes ratios directly from the hex values `Theme`
/// is built from, rather than resolving `NSColor` through an `NSAppearance` (which would make the
/// test depend on how the test runner's process resolves dynamic system colors). If a hex value
/// in `Theme.swift` ever drifts, this test — not a screenshot — is what catches it.
@Suite("Theme contrast (WCAG)")
struct ThemeContrastTests {
    /// The minimum ratio WCAG 2.x AA requires for normal text (and for the 11–12 pt labels/icons
    /// these tokens are used on, per the design doc's own contrast column).
    private static let minimumAA = 4.5

    private enum Hex {
        static let bgBaseLight = Theme.Hex.bgBase.light
        static let bgBaseDark = Theme.Hex.bgBase.dark
        static let bgRaisedLight = Theme.Hex.bgRaised.light
        static let bgRaisedDark = Theme.Hex.bgRaised.dark
        static let bgSunkenLight = Theme.Hex.bgSunken.light
        static let pillSurface = Theme.Hex.pill.light

        static let phosphorLight = Theme.Hex.phosphor.light
        static let phosphorDark = Theme.Hex.phosphor.dark

        static let workingLight = Theme.Hex.working.light
        static let workingDark = Theme.Hex.working.dark
        static let workingFillLight = Theme.Hex.working.light
        static let workingFillDark = Theme.Hex.working.dark
        static let onWorkingLight = Theme.Hex.onWorking.light
        static let onWorkingDark = Theme.Hex.onWorking.dark
        static let pillWorking = Theme.Hex.working.dark
    }

    // MARK: WCAG relative luminance / contrast ratio

    /// Relative luminance per WCAG 2.x (sRGB → linear, Rec. 709 coefficients).
    private static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ byte: UInt32) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel((hex >> 16) & 0xFF)
        let g = channel((hex >> 8) & 0xFF)
        let b = channel(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// WCAG contrast ratio between two colours, order-independent (lighter over darker + 0.05).
    private static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    // MARK: `working` — the model-authored signal

    @Test("working (light) clears AA on both light surfaces")
    func workingLightOnSurfaces() {
        #expect(Self.contrastRatio(Hex.workingLight, Hex.bgBaseLight) >= Self.minimumAA)
        #expect(Self.contrastRatio(Hex.workingLight, Hex.bgRaisedLight) >= Self.minimumAA)
    }

    @Test("working (dark) clears AA on both dark surfaces")
    func workingDarkOnSurfaces() {
        #expect(Self.contrastRatio(Hex.workingDark, Hex.bgBaseDark) >= Self.minimumAA)
        #expect(Self.contrastRatio(Hex.workingDark, Hex.bgRaisedDark) >= Self.minimumAA)
    }

    @Test("pillWorking clears AA on the always-dark pill surface")
    func pillWorkingOnPill() {
        #expect(Self.contrastRatio(Hex.pillWorking, Hex.pillSurface) >= Self.minimumAA)
    }

    @Test("onWorking clears AA on workingFill in both schemes")
    func onWorkingOnWorkingFill() {
        #expect(Self.contrastRatio(Hex.onWorkingLight, Hex.workingFillLight) >= Self.minimumAA)
        #expect(Self.contrastRatio(Hex.onWorkingDark, Hex.workingFillDark) >= Self.minimumAA)
    }

    /// The regression this whole test exists for: the retired light value (`#5B6CFF`) failed AA
    /// at 4.2:1 on white (docs/product/UI-ROUND-2026-09-28.md §3). Locks in that its replacement
    /// clears the bar by a real margin, not by rounding.
    @Test("the new light working value fixes the old AA failure")
    func workingLightFixesRegression() {
        let retiredValue: UInt32 = 0x5B6CFF
        let retiredRatio = Self.contrastRatio(retiredValue, Hex.bgRaisedLight)
        let newRatio = Self.contrastRatio(Hex.workingLight, Hex.bgRaisedLight)
        #expect(retiredRatio < Self.minimumAA, "sanity check: the retired value should still fail AA")
        #expect(newRatio >= Self.minimumAA)
        #expect(newRatio > retiredRatio)
    }

    // MARK: `phosphor` — the user-authored signal (guarded here too, so the test protects both halves)

    @Test("phosphor (light) clears AA on both light surfaces")
    func phosphorLightOnSurfaces() {
        #expect(Self.contrastRatio(Hex.phosphorLight, Hex.bgBaseLight) >= Self.minimumAA)
        #expect(Self.contrastRatio(Hex.phosphorLight, Hex.bgRaisedLight) >= Self.minimumAA)
    }

    @Test("phosphor (dark) clears AA on both dark surfaces")
    func phosphorDarkOnSurfaces() {
        #expect(Self.contrastRatio(Hex.phosphorDark, Hex.bgBaseDark) >= Self.minimumAA)
        #expect(Self.contrastRatio(Hex.phosphorDark, Hex.bgRaisedDark) >= Self.minimumAA)
    }

    // MARK: Pill hover hints (founder decision 2026-09-28: purple hints, variants A/B/C)

    @Test("hint variants A/B: text, muted text and key caps clear AA on the purple-tinted surface")
    func hintTintedVariants() {
        let surface = PillHintPalette.tintedSurface
        #expect(Self.contrastRatio(PillHintPalette.text, surface) >= Self.minimumAA)
        #expect(Self.contrastRatio(PillHintPalette.mutedText, surface) >= Self.minimumAA)
        #expect(Self.contrastRatio(PillHintPalette.keyText, PillHintPalette.keyFill) >= Self.minimumAA)
    }

    @Test("hint variant C: ink on the solid purple clears AA in both appearances")
    func hintSolidVariant() {
        #expect(Self.contrastRatio(PillHintPalette.solidInkDark, PillHintPalette.solidFillDark) >= Self.minimumAA)
        #expect(Self.contrastRatio(PillHintPalette.solidInkLight, PillHintPalette.solidFillLight) >= Self.minimumAA)
    }

    @Test("the tinted surface is #8B97FF at 16% over near-black")
    func hintSurfaceBlend() {
        #expect(PillHintPalette.blend(0x8B97FF, alpha: 0.16, over: 0x0E0F14) == PillHintPalette.tintedSurface)
    }

    @Test("said, wrote, drop, success, warning and error clear AA on every surface")
    func semanticInksClearAA() {
        let inks: [(String, Theme.HexPair)] = [
            ("phosphor", Theme.Hex.phosphor),
            ("working", Theme.Hex.working),
            ("drop", Theme.Hex.drop),
            ("saidInk", Theme.Hex.saidInk),
            ("success", Theme.Hex.success),
            ("warning", Theme.Hex.warning),
            ("error", Theme.Hex.error),
        ]
        let surfaces: [(String, Theme.HexPair)] = [
            ("bgBase", Theme.Hex.bgBase),
            ("bgRaised", Theme.Hex.bgRaised),
            ("bgSunken", Theme.Hex.bgSunken),
        ]
        for ink in inks {
            for surface in surfaces {
                #expect(Self.contrastRatio(ink.1.light, surface.1.light) >= Self.minimumAA,
                        "\(ink.0) light on \(surface.0)")
                #expect(Self.contrastRatio(ink.1.dark, surface.1.dark) >= Self.minimumAA,
                        "\(ink.0) dark on \(surface.0)")
            }
        }
    }

    @Test("onPhosphor clears AA on the lime fill")
    func onPhosphorOnFill() {
        #expect(Self.contrastRatio(Theme.Hex.onPhosphor.light, Theme.Hex.phosphorFill.light) >= Self.minimumAA)
    }

    @Test("the site light drop and success hexes fail AA on the sunken surface")
    func siteStepsWereRequired() {
        #expect(Self.contrastRatio(0xA86A00, Hex.bgSunkenLight) < Self.minimumAA)
        #expect(Self.contrastRatio(0x17804F, Hex.bgSunkenLight) < Self.minimumAA)
        #expect(Self.contrastRatio(Theme.Hex.drop.light, Hex.bgSunkenLight) >= Self.minimumAA)
        #expect(Self.contrastRatio(Theme.Hex.success.light, Hex.bgSunkenLight) >= Self.minimumAA)
    }
}
