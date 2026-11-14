import Foundation
import Testing
@testable import Murmur

/// Text must be readable: every text token on every surface, in both themes, at WCAG AA (4.5:1).
/// The founder's onboarding test found the dim token at about 3:1 carrying real sentences. This
/// reads the same `Theme.Hex` pairs the app's colours are built from, so a value that drifts
/// fails here.
@Suite("Theme text contrast (WCAG AA)")
struct ThemeTextContrastTests {
    static let minimumAA = 4.5

    struct Case: CustomTestStringConvertible, Sendable {
        let text: String
        let surface: String
        let theme: String
        let ratio: Double
        var testDescription: String { "\(text) on \(surface), \(theme)" }
    }

    static let texts: [(String, Theme.HexPair)] = [
        ("textPrimary", Theme.Hex.textPrimary),
        ("textSecondary", Theme.Hex.textSecondary),
        ("textTertiary", Theme.Hex.textTertiary),
    ]
    static let surfaces: [(String, Theme.HexPair)] = [
        ("bgBase", Theme.Hex.bgBase),
        ("bgRaised", Theme.Hex.bgRaised),
        ("bgSunken", Theme.Hex.bgSunken),
    ]

    /// Every text token on every surface, in both themes.
    static let cases: [Case] = texts.flatMap { text in
        surfaces.flatMap { surface in
            [
                Case(text: text.0, surface: surface.0, theme: "light",
                     ratio: contrastRatio(text.1.light, surface.1.light)),
                Case(text: text.0, surface: surface.0, theme: "dark",
                     ratio: contrastRatio(text.1.dark, surface.1.dark)),
            ]
        }
    }

    @Test("text clears 4.5:1", arguments: cases)
    func clearsAA(_ item: Case) {
        #expect(item.ratio >= Self.minimumAA, "\(item.testDescription) is \(item.ratio)")
    }

    @Test("the hierarchy holds: primary is stronger than secondary, secondary at least tertiary")
    func hierarchyOrder() {
        for surface in Self.surfaces {
            for theme in ["light", "dark"] {
                func ratio(_ pair: Theme.HexPair, _ background: Theme.HexPair) -> Double {
                    theme == "light" ? Self.contrastRatio(pair.light, background.light)
                                     : Self.contrastRatio(pair.dark, background.dark)
                }
                let primary = ratio(Theme.Hex.textPrimary, surface.1)
                let secondary = ratio(Theme.Hex.textSecondary, surface.1)
                let tertiary = ratio(Theme.Hex.textTertiary, surface.1)
                #expect(primary > secondary, "primary vs secondary on \(surface.0), \(theme)")
                #expect(secondary >= tertiary, "secondary vs tertiary on \(surface.0), \(theme)")
            }
        }
    }

    @Test("the old dim value is what failed")
    func oldValueFailed() {
        #expect(Self.contrastRatio(0x8D9284, Theme.Hex.bgRaised.light) < Self.minimumAA)
        #expect(Self.contrastRatio(0x5E6571, Theme.Hex.bgRaised.dark) < Self.minimumAA)
    }

    // MARK: WCAG relative luminance / contrast ratio

    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ byte: UInt32) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
