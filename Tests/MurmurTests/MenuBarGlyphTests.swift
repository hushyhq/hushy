import AppKit
import Testing
@testable import Murmur

/// The menu-bar glyph is the Wave-H as a monochrome template (handbook design/brand). macOS tints
/// template images for light and dark menu bars, so `isTemplate` and the 18×16 pt canvas are the
/// contract; the two states must also differ, or "listening" would be invisible.
@Suite("Menu-bar glyph")
struct MenuBarGlyphTests {
    @Test("is an 18×16 pt template image in both states")
    func templateCanvas() {
        for active in [false, true] {
            let image = MenuBarGlyph.image(active: active)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 16))
        }
    }

    @Test("listening renders differently from resting")
    func statesDiffer() {
        let resting = MenuBarGlyph.image(active: false).tiffRepresentation
        let listening = MenuBarGlyph.image(active: true).tiffRepresentation
        #expect(resting != nil)
        #expect(resting != listening)
        let attention = MenuBarGlyph.image(active: false, needsAttention: true).tiffRepresentation
        #expect(attention != nil)
        #expect(attention != resting)
    }
}
