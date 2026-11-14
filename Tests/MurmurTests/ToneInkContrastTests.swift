import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Each tone's ink (`Theme.ToneInk`) is drawn as a glyph, an edge and small text on the card, the page and the well, in
/// both themes; it must clear WCAG AA (4.5:1) on all three.
@Suite("Tone inks contrast (WCAG)")
struct ToneInkContrastTests {
    private static func luminance(_ hex: UInt32) -> Double {
        func channel(_ byte: UInt32) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    private static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test("every tone ink reads at AA on the raised, base and sunken surfaces", arguments: ToneLane.allCases)
    func inkContrast(lane: ToneLane) {
        let ink = Theme.ToneInk.pair(for: lane)
        for surface in [Theme.Hex.bgRaised, Theme.Hex.bgBase, Theme.Hex.bgSunken] {
            #expect(Self.ratio(ink.light, surface.light) >= 4.5, "\(lane) light on \(String(surface.light, radix: 16))")
            #expect(Self.ratio(ink.dark, surface.dark) >= 4.5, "\(lane) dark on \(String(surface.dark, radix: 16))")
        }
    }

    @Test("no two tones share an ink")
    func distinctInks() {
        let inks = ToneLane.allCases.map { Theme.ToneInk.pair(for: $0) }
        #expect(Set(inks.map(\.light)).count == inks.count)
        #expect(Set(inks.map(\.dark)).count == inks.count)
    }
}
