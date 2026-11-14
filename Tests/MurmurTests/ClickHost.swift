import AppKit
import SwiftUI

/// A real view in a real window parked far off every screen, with real mouse events sent straight
/// to that window. Nothing goes through the window server, so a test using this cannot click or
/// show anything on the Mac.
@MainActor
struct ClickHost {
    let window: NSWindow
    let size: NSSize

    private static let offscreen = NSPoint(x: -30_000, y: -30_000)

    init(_ view: some View, size: NSSize) {
        _ = NSApplication.shared
        self.size = size
        window = NSWindow(contentRect: NSRect(origin: Self.offscreen, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        // On the window list, far off every screen: SwiftUI hit-tests only a window that is ordered in.
        window.orderFrontRegardless()
        settle()
    }

    func settle(_ seconds: Double = 0.2) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// A press and release at a point given from the content's top-left.
    func click(_ point: CGPoint, settling: Double = 0.05) {
        let location = NSPoint(x: point.x, y: size.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            window.sendEvent(event)
        }
        if settling > 0 { settle(settling) }
    }

    /// Where a point given from the content's top-left is on the (far-off) screen.
    func screenPoint(_ point: CGPoint) -> NSPoint {
        NSPoint(x: window.frame.minX + point.x, y: window.frame.minY + size.height - point.y)
    }

    /// What the content draws now, to tell whether a change was drawn.
    func picture() -> Data? {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.tiffRepresentation
    }

    func close() { window.close() }
}
