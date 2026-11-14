import CoreGraphics
import Testing
@testable import Murmur

@Suite("App shell placement")
struct AppShellPlacementTests {
    @Test("Settings centres over the main window and stays on the visible screen")
    func settingsCenter() {
        let parent = CGRect(x: 100, y: 100, width: 1320, height: 880)
        let size = CGSize(width: 780, height: 640)
        #expect(WindowPlacement.centeredOrigin(size: size, over: parent, within: nil) == CGPoint(x: 370, y: 220))
        let visible = CGRect(x: 0, y: 0, width: 1280, height: 800)
        #expect(WindowPlacement.centeredOrigin(size: size, over: parent, within: visible) == CGPoint(x: 370, y: 160))
    }

    @Test("Assistant stays beside a readable section; opening it grows only narrow windows")
    func assistantRoom() {
        #expect(AssistantPane.hasRoom(windowWidth: 1320, sidebarCollapsed: false))
        #expect(!AssistantPane.hasRoom(windowWidth: 960, sidebarCollapsed: false))
        let requested = AssistantPane.windowWidthWithRoom(sidebarCollapsed: false)
        #expect(requested == 1188)
        #expect(AssistantPane.hasRoom(windowWidth: requested, sidebarCollapsed: false))

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Opening the Assistant grows a narrow window about the centre of the frame it grew
        // from: the window keeps its mid-point (and its bottom edge), so it doesn't slide
        // sideways and whatever is centred on it — the Settings/plans window — stays centred.
        let frame = CGRect(x: 200, y: 80, width: 960, height: 700)
        let grown = WindowPlacement.grownFrame(frame, toWidth: requested, within: screen)
        #expect(grown.width == requested)
        #expect(grown.midX == frame.midX)
        #expect(grown.minY == frame.minY)

        // Only narrow windows grow: one that already fits is left exactly where it is.
        let wide = CGRect(x: 60, y: 80, width: 1320, height: 700)
        #expect(WindowPlacement.grownFrame(wide, toWidth: requested, within: screen) == wide)

        // Growing this frame about its centre would start at 580 − 594 = −14, off the screen.
        // Staying visible wins over centring: the frame is shifted back on by that overhang.
        let edge = CGRect(x: 100, y: 80, width: 960, height: 700)
        let clamped = WindowPlacement.grownFrame(edge, toWidth: requested, within: screen)
        #expect(clamped.width == requested)
        #expect(clamped.minX == screen.minX)
        #expect(clamped.midX - edge.midX == 14)
    }
}
