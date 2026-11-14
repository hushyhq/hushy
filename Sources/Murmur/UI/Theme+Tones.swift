import AppKit
import MurmurCore
import SwiftUI

/// Each tone has its own quiet ink, so a lane, the chip dragged into it and its drop well read as one thing at a
/// glance (docs/design: "colour is meaning"). Inks are glyph, stroke and small-label colours, at least 4.5:1 on all
/// three surfaces in both themes (`ToneInkContrastTests`); their washes are the same ink at low opacity.
/// Refined keeps the house olive-lime because it is the default way Hushy writes; As spoken is graphite, the ink of
/// words left untouched. Purple stays the model's alone, so no tone uses it.
extension Theme {
    enum ToneInk {
        static let refined = Hex.phosphor
        static let professional = HexPair(light: 0x2F5FA8, dark: 0x8DB4F2)
        static let casual = HexPair(light: 0xA8501F, dark: 0xF0A274)
        static let prompt = HexPair(light: 0x0C716B, dark: 0x63D2C8)
        static let asSpoken = HexPair(light: 0x5E6358, dark: 0x98A0AC)

        static func pair(for lane: ToneLane) -> HexPair {
            switch lane {
            case .refined: refined
            case .professional: professional
            case .casual: casual
            case .prompt: prompt
            case .asSpoken: asSpoken
            }
        }
    }

    /// The inset ground under chips, fields and miniatures. On dark, `bgSunken` is near black and reads as a hole, so
    /// wells sit one step down from the card instead.
    static func well(_ scheme: ColorScheme) -> Color { scheme == .dark ? bgBase : bgSunken }

    static func ink(_ pair: HexPair) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? pair.dark : pair.light)
        })
    }
}

extension ToneLane {
    /// The lane's ink: its glyph, its drop well's edge, and the edge of a chip lifted over it.
    var ink: Color { Theme.ink(Theme.ToneInk.pair(for: self)) }

    /// A wash of the lane's ink for fills behind its glyph and under a drag.
    func wash(_ scheme: ColorScheme, strong: Bool = false) -> Color {
        ink.opacity(scheme == .dark ? (strong ? 0.20 : 0.13) : (strong ? 0.14 : 0.09))
    }
}

/// The two-curve motion vocabulary applied to the Voice & style surfaces: a spring for anything that moves in
/// space, a short ease for tints. Under Reduce Motion movement becomes a cross-fade in place.
extension Theme.Motion {
    /// A chip or card rising under the pointer: quick and critically damped, so it never wobbles at rest.
    static let lift = Animation.spring(response: 0.24, dampingFraction: 0.86)
    /// A chip picked up: a little overshoot, because a drag carries momentum.
    static let pickUp = Animation.spring(response: 0.3, dampingFraction: 0.72)
}
