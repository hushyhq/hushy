import CoreGraphics
import Testing
@testable import Murmur

@Suite("Paste glow geometry")
struct PasteGlowTests {
    /// A 1440×900 primary display, and a second one to its right whose top is 180 pt lower.
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let second = CGRect(x: 1440, y: -180, width: 1920, height: 1080)

    @Test("an Accessibility frame is flipped to AppKit coordinates and given its outset")
    func flips() {
        let field = CGRect(x: 100, y: 200, width: 400, height: 30)
        let frame = PasteGlowGeometry.windowFrame(axFrame: field, screens: [primary])
        #expect(frame == CGRect(x: 96, y: 900 - 230 - 4, width: 408, height: 38))
    }

    @Test("a field on the second display is placed on that display")
    func secondDisplay() {
        // Top-left global y 400 on the second display: AppKit y = 900 − 400 − 40 = 460, inside it.
        let field = CGRect(x: 1600, y: 400, width: 300, height: 40)
        let frame = PasteGlowGeometry.windowFrame(axFrame: field, screens: [primary, second])
        #expect(frame?.minX == 1596)
        #expect(frame.map { second.intersects($0) } == true)
    }

    @Test("nothing is drawn for a frame that cannot be the field the person is looking at", arguments: [
        CGRect(x: 10, y: 10, width: 4, height: 30),        // too thin to see
        CGRect(x: 5000, y: 5000, width: 300, height: 40),  // off every display
        CGRect(x: 0, y: 25, width: 1440, height: 875),     // a whole window or page
    ])
    func rejects(_ field: CGRect) {
        #expect(PasteGlowGeometry.windowFrame(axFrame: field, screens: [primary]) == nil)
    }

    @Test("nothing is drawn when no display is known")
    func noScreens() {
        #expect(PasteGlowGeometry.windowFrame(axFrame: CGRect(x: 0, y: 0, width: 100, height: 30), screens: []) == nil)
    }

    @Test("the glow lasts about 800 ms, in faster than out")
    func timing() {
        #expect(abs(PasteGlowTiming.total - 0.8) < 0.001)
        #expect(PasteGlowTiming.fadeIn < PasteGlowTiming.fadeOut)
    }

    @Test("a tall text view's ring corner is capped")
    func corner() {
        #expect(PasteGlowGeometry.cornerRadius(for: CGRect(x: 0, y: 0, width: 600, height: 400)) == 10)
        #expect(PasteGlowGeometry.cornerRadius(for: CGRect(x: 0, y: 0, width: 200, height: 12)) == 5)
    }
}
