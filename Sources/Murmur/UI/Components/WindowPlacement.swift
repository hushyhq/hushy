import AppKit
import SwiftUI

/// Where Hushy's secondary windows go: centred on the main window (founder test 2026-09-28,
/// P0 12 — the plans/Settings window opened from the sidebar landed wherever macOS put it, not
/// on the app). Sheets (`.sheet`) already hang off the main window; the Quick Look panel
/// centres itself the same way (`DictationQuickLook.place`). This covers the Settings scene,
/// which SwiftUI positions on its own, and growing the main window for the Assistant pane.
///
/// The frame arithmetic is pure (`centeredOrigin`, `grownFrame`) so it's unit-tested
/// (`AppShellPlacementTests`); the AppKit calls around it are thin.
@MainActor
enum WindowPlacement {
    /// The origin that centres a `size` window over `parent`, kept inside `screen` (the
    /// screen's visible frame) so a small parent near an edge never pushes the window off it.
    /// With no screen given, the centred origin is returned as is.
    nonisolated static func centeredOrigin(size: CGSize, over parent: CGRect, within screen: CGRect?) -> CGPoint {
        var origin = CGPoint(x: parent.midX - size.width / 2, y: parent.midY - size.height / 2)
        guard let screen else { return origin }
        origin.x = min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width))
        origin.y = min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height))
        return origin
    }

    /// `frame` widened to `width` **about its own centre** — never narrower than it is, and
    /// never off the visible `screen`.
    ///
    /// The centre is the anchor on purpose (founder test 2026-09-28, P0 12/14): the app centres
    /// its windows, and a window that keeps its centre when it grows for the Assistant pane
    /// doesn't slide across the screen, doesn't cover new ground on one side only, and leaves
    /// whatever was centred on it (the Settings/plans window) centred. Two constraints, in this
    /// order:
    /// 1. **Fit the pane.** A screen narrower than `width` gets the screen's width.
    /// 2. **Stay on screen.** If growing symmetrically would push a frame partly off the
    ///    visible screen, it is shifted back on by exactly that overhang — a window that fits
    ///    beats a centred one that doesn't. Only then does the centre move, and only by the
    ///    shortfall.
    nonisolated static func grownFrame(_ frame: CGRect, toWidth width: CGFloat, within screen: CGRect?) -> CGRect {
        var target = max(width, frame.width)
        if let screen { target = min(target, screen.width) }
        var grown = CGRect(x: frame.midX - target / 2, y: frame.minY, width: target, height: frame.height)
        if let screen {
            grown.origin.x = min(max(grown.minX, screen.minX), screen.maxX - target)
        }
        return grown
    }

    /// The visible main window, if any.
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" && $0.isVisible }
            ?? NSApp.windows.first { $0.identifier?.rawValue == "main" }
    }

    /// The Settings scene's window: remembered by `CenteredOnMainWindow` when `SettingsView`
    /// first appears, and otherwise found by SwiftUI's identifier for that scene.
    static var settingsWindow: NSWindow? {
        get { rememberedSettingsWindow ?? NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") ?? false } }
        set { rememberedSettingsWindow = newValue }
    }
    private static weak var rememberedSettingsWindow: NSWindow?

    /// Moves `window` to the centre of `parent`, or of its screen when there is no parent
    /// (the menu bar item with the main window closed, say).
    static func center(_ window: NSWindow, over parent: NSWindow?) {
        guard let parent, parent !== window else {
            window.center()
            return
        }
        let screen = (parent.screen ?? window.screen)?.visibleFrame
        window.setFrameOrigin(centeredOrigin(size: window.frame.size, over: parent.frame, within: screen))
    }

    /// Widens `window` to `width` about its centre — the window keeps its place on screen while
    /// the Assistant pane's room is made, shifted only if it would leave the visible screen —
    /// animated, within its screen. Never shrinks: closing the pane leaves the frame alone.
    static func grow(_ window: NSWindow, toWidth width: CGFloat) {
        let frame = grownFrame(window.frame, toWidth: width, within: window.screen?.visibleFrame)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: true)
    }
}

/// Attach as a `.background` to a scene's root view: the first time SwiftUI puts it in a
/// window, that window is centred on the main window and remembered as the Settings window.
/// Every way of opening Settings (⌘,, the app menu, the gear, the sidebar profile) then lands in the
/// same place, without each caller having to know about windows.
struct CenteredOnMainWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacementView { PlacementView() }
    func updateNSView(_ nsView: PlacementView, context: Context) {}

    final class PlacementView: NSView {
        private weak var placedIn: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== placedIn else { return }
            placedIn = window
            WindowPlacement.settingsWindow = window
            // The frame is final only after SwiftUI's first layout pass.
            DispatchQueue.main.async {
                WindowPlacement.center(window, over: WindowPlacement.mainWindow)
            }
        }
    }
}
