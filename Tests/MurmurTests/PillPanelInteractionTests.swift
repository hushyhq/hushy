import AppKit
import MurmurCore
import Testing
@testable import Murmur

/// The real `PillPanel` + `PillView`, parked far off every screen, driven by synthetic mouse events
/// sent straight to the window (`sendEvent`) — nothing reaches the window server or the real
/// screen. Checks that taps and drags reach the SwiftUI gestures and that the click-through gate
/// opens only over drawn shapes and stays latched through a press.
@Suite("Pill panel — taps, drags and click-through, headless", .serialized)
@MainActor
struct PillPanelInteractionTests {
    private static let offscreen = NSPoint(x: -30_000, y: -30_000)
    /// A display parked far off every real screen: drags, drop spots and snaps all happen here,
    /// so nothing ever appears on the founder's screen and no real defaults are written.
    static let fakeDisplay = PillDisplay(
        id: 424_242, frame: CGRect(x: -30_000, y: -30_000, width: 1440, height: 900),
        visible: CGRect(x: -30_000, y: -30_000, width: 1440, height: 900), topLimit: -30_000 + 900)

    /// Injected at init: the fake display, a pointer on it, throwaway defaults — the panel never
    /// reads or writes `.standard` and never lands on a real display.
    ///
    /// Its notification centres are the panel's own, not the app's: a real app switch on the Mac, or another
    /// test posting "resigned active", must not be able to end a drag this test is in the middle of.
    static func fakeEnvironment(
        idleTimeout: TimeInterval = 2, buttonDown: Bool = false, buttonChecked: @escaping @MainActor () -> Void = {}
    ) -> PillPanelEnvironment {
        PillPanelEnvironment(
            displays: { [fakeDisplay] },
            pointerLocation: { NSPoint(x: -30_000 + 720, y: -30_000 + 400) },
            anchorDefaults: UserDefaults(suiteName: "app.hushy.tests.pill.\(UUID().uuidString)")!,
            isMouseButtonDown: { buttonChecked(); return buttonDown },
            dragIdleTimeout: idleTimeout,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter())
    }

    private func makePanel(
        _ state: PillState = .idle, anchor: PillAnchor = .bottom, environment: PillPanelEnvironment? = nil
    ) -> (PillPanel, PillModel) {
        _ = NSApplication.shared
        let model = PillModel()
        model.showWhenIdle = true
        model.state = state
        let panel = PillPanel(model: model, environment: environment ?? Self.fakeEnvironment())
        model.anchor = anchor
        let size = PillPanel.size(for: state, anchor: anchor)
        panel.setFrame(NSRect(origin: Self.offscreen, size: size), display: false)
        // Ordered in far off every screen: SwiftUI only hit-tests a window that is on the
        // window list. Nothing is visible and no event goes through the window server.
        panel.orderFrontRegardless()
        panel.setFrame(NSRect(origin: Self.offscreen, size: size), display: false)
        panel.setInteractive(state.isInteractive)
        settle(panel)
        return (panel, model)
    }

    private func settle(_ panel: PillPanel, _ seconds: Double = 0.25) {
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins the main run loop in short slices until `done()` holds, for at most `limit` seconds. Used where a
    /// timer or an animation has to finish: a fixed pause is shorter than the work whenever the Mac is busy, and
    /// a condition is the same answer on a quiet machine and a loaded one.
    private func settle(_ panel: PillPanel, until done: () -> Bool, limit: Double = 20) {
        let end = Date().addingTimeInterval(limit)
        while !done() && Date() < end { settle(panel, 0.02) }
    }

    /// The first drawn shape's centre, in window coordinates (origin bottom-left).
    private func capsuleCentre(_ panel: PillPanel, _ model: PillModel) throws -> NSPoint {
        let rect = try #require(model.hitRegions.last)
        return NSPoint(x: rect.midX, y: panel.frame.height - rect.midY)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, to panel: PillPanel) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1) else { return }
        panel.sendEvent(event)
    }

    @Test("the resting capsule reports its drawn frame: bottom-centre, 40×10 (design v3 idle)")
    func restingRegion() throws {
        let (panel, model) = makePanel()
        let rect = try #require(model.hitRegions.first)
        #expect(rect == CGRect(x: 120, y: 94, width: 40, height: 10))
        panel.close()
    }

    @Test("a tap on the idle capsule reaches onTapIdle, first time")
    func tapDictates() throws {
        let (panel, model) = makePanel()
        var taps = 0
        model.onTapIdle = { taps += 1 }
        let point = try capsuleCentre(panel, model)
        send(.leftMouseDown, at: point, to: panel)
        send(.leftMouseUp, at: point, to: panel)
        settle(panel, 0.1)
        #expect(taps == 1)
        panel.close()
    }

    @Test("a drag on the capsule reaches onDragChanged and onDragEnded")
    func dragMoves() throws {
        let (panel, model) = makePanel()
        var changed = 0
        var ended = 0
        model.onDragChanged = { changed += 1 }
        model.onDragEnded = { ended += 1 }
        let start = try capsuleCentre(panel, model)
        send(.leftMouseDown, at: start, to: panel)
        for step in 1...6 {
            send(.leftMouseDragged, at: NSPoint(x: start.x + CGFloat(step) * 5, y: start.y + CGFloat(step) * 3), to: panel)
        }
        send(.leftMouseUp, at: NSPoint(x: start.x + 30, y: start.y + 18), to: panel)
        settle(panel, 0.1)
        #expect(changed > 0)
        #expect(ended == 1)
        panel.close()
    }

    @Test("a release ends the drag and snaps even when SwiftUI never calls onEnded")
    func releaseEndsDragWithoutOnEnded() throws {
        // Live: moving the panel under a DragGesture can cancel it without onEnded, which left the
        // pill wherever it was dropped instead of snapping to an edge centre.
        let (panel, model) = makePanel()
        let point = try capsuleCentre(panel, model)
        panel.dragChanged()
        #expect(panel.dragStart != nil)
        send(.leftMouseUp, at: point, to: panel)
        #expect(panel.dragStart == nil)
        panel.close()
    }

    @Test("the gate stays latched from mouse-down to mouse-up, then closes if the pointer is away")
    func pressLatch() throws {
        let (panel, model) = makePanel()
        let point = try capsuleCentre(panel, model)
        send(.leftMouseDown, at: point, to: panel)
        #expect(!panel.ignoresMouseEvents)
        model.hitRegions = [] // a region change mid-press (hover growing, a hint appearing)
        #expect(!panel.ignoresMouseEvents, "never closes while a button is held")
        send(.leftMouseUp, at: point, to: panel)
        // The real pointer is nowhere near a panel parked off-screen, so the release closes it.
        #expect(panel.ignoresMouseEvents)
        panel.close()
    }

    @Test("clicks outside the drawn shapes pass through; over a shape they are taken")
    func clickThrough() throws {
        let (panel, model) = makePanel()
        let capsule = PillHitTest.screenRect(try #require(model.hitRegions.first), inWindow: panel.frame)
        panel.updateMouseGate(at: NSPoint(x: panel.frame.minX + 10, y: panel.frame.maxY - 10))
        #expect(panel.ignoresMouseEvents, "empty panel corner")
        panel.updateMouseGate(at: NSPoint(x: capsule.midX, y: capsule.midY))
        #expect(!panel.ignoresMouseEvents)
        panel.setInteractive(false)
        #expect(panel.ignoresMouseEvents, "processing/listening take no clicks")
        panel.close()
    }

    @Test("hovering the resting capsule opens the gate and it stays open while the pill grows (no flap)",
          arguments: [0.5, 0.0, 1.0]) // centre, bottom edge, top edge of the resting capsule
    func hoverGrowthDoesNotFlap(heightFraction: Double) throws {
        let (panel, model) = makePanel()
        let capsule = PillHitTest.screenRect(try #require(model.hitRegions.first), inWindow: panel.frame)
        let pointer = NSPoint(x: capsule.midX, y: capsule.minY + capsule.height * heightFraction)
        panel.pointerLocation = { pointer }
        panel.updateMouseGate()
        #expect(!panel.ignoresMouseEvents)
        model.isHovered = true // what SwiftUI's onHover does next: the capsule grows, the hint appears
        settle(panel, 0.5)
        #expect(model.hitRegions.count >= 2, "grown capsule + hint label: \(model.hitRegions)")
        #expect(!panel.ignoresMouseEvents, "the gate must not close under a still pointer")
        #expect(model.isHovered, "and must not end the hover it just caused")
        let grown = model.hitRegions.map { PillHitTest.screenRect($0, inWindow: panel.frame) }
        #expect(grown.contains { $0.insetBy(dx: -4, dy: -4).contains(pointer) },
                "the grown shapes still cover the pointer: \(grown) vs \(pointer)")
        panel.close()
    }

    @Test("hands-free ✕ and ✓ both work")
    func handsFreeButtons() throws {
        let (panel, model) = makePanel(.handsFree(startedAt: Date()))
        var cancels = 0
        var stops = 0
        model.onCancel = { cancels += 1 }
        model.onStop = { stops += 1 }
        let capsule = try #require(model.hitRegions.last)
        let y = panel.frame.height - capsule.midY
        for (x, type) in [(capsule.minX + 20, NSEvent.EventType.leftMouseDown), (capsule.minX + 20, .leftMouseUp),
                          (capsule.maxX - 20, .leftMouseDown), (capsule.maxX - 20, .leftMouseUp)] {
            send(type, at: NSPoint(x: x, y: y), to: panel)
            settle(panel, 0.05)
        }
        #expect(cancels == 1)
        #expect(stops == 1)
        panel.close()
    }

    @Test("recording capsules stay compact and centred as the timer advances")
    func compactRecordingRegions() throws {
        let start = Date()
        let (handsFree, handsFreeModel) = makePanel(.handsFree(startedAt: start))
        let handsFreeRegion = try #require(handsFreeModel.hitRegions.last)
        #expect(handsFreeRegion.width < 232)
        #expect(abs(handsFreeRegion.midX - handsFree.frame.width / 2) <= 0.5)
        #expect(handsFreeRegion.height == 30)

        // Same digit count, same width: nine minutes in is as wide as the first second.
        let (later, laterModel) = makePanel(.handsFree(startedAt: start.addingTimeInterval(-540)))
        let laterRegion = try #require(laterModel.hitRegions.last)
        #expect(laterRegion.width == handsFreeRegion.width)
        #expect(abs(laterRegion.midX - later.frame.width / 2) <= 0.5)

        let (note, noteModel) = makePanel(.recordingNote(startedAt: start))
        let noteRegion = try #require(noteModel.hitRegions.last)
        let (laterNote, laterNoteModel) = makePanel(.recordingNote(startedAt: start.addingTimeInterval(-540)))
        #expect(laterNoteModel.hitRegions.last?.width == noteRegion.width)
        #expect(abs(noteRegion.midX - note.frame.width / 2) <= 0.5)

        handsFree.close()
        later.close()
        note.close()
        laterNote.close()
    }

    @Test("listening, hands-free and processing keep the same screen centre")
    func recordingTransitionCentre() throws {
        let (panel, model) = makePanel(.listening)
        panel.reposition()
        settle(panel)
        let centre = panel.frame.midX
        #expect(abs((model.hitRegions.last?.midX ?? 0) - panel.frame.width / 2) <= 0.5)

        let handsFree = PillState.handsFree(startedAt: Date())
        model.state = handsFree
        panel.setState(handsFree)
        settle(panel)
        #expect(panel.frame.midX == centre)
        #expect(panel.frame.width == PillPanel.centredWidth, "one width at the bottom edge: the panel never moves sideways")
        #expect(abs((model.hitRegions.last?.midX ?? 0) - panel.frame.width / 2) <= 0.5)

        let processing = PillState.processing()
        model.state = processing
        panel.setState(processing)
        settle(panel)
        #expect(panel.frame.midX == centre)
        panel.finishPendingResize()
        settle(panel)
        #expect(panel.frame.midX == centre)
        #expect(abs((model.hitRegions.last?.midX ?? 0) - panel.frame.width / 2) <= 0.5)
        panel.close()
    }

    // MARK: Drop spots while dragging

    @Test("dragging shows the four drop spots on the display under the pointer; the drop removes them")
    func dropSpotsDuringDrag() throws {
        let (panel, model) = makePanel()
        model.onDragChanged = { panel.dragChanged() }
        model.onDragEnded = { panel.dragEnded() }
        let start = try capsuleCentre(panel, model)
        send(.leftMouseDown, at: start, to: panel)
        for step in 1...6 {
            send(.leftMouseDragged, at: NSPoint(x: start.x + CGFloat(step) * 6, y: start.y + CGFloat(step) * 4), to: panel)
        }
        let overlay = try #require(panel.dropTargets, "created on drag")
        #expect(overlay.panel.ignoresMouseEvents, "click-through")
        #expect(overlay.panel.level.rawValue < panel.level.rawValue, "below the pill")
        #expect(overlay.panel.frame == Self.fakeDisplay.frame, "the display under the pointer only")
        #expect(overlay.model.targets.count == 4)
        #expect(overlay.model.highlighted == .bottom, "pointer near the bottom-centre")
        #expect(overlay.panel.isVisible)
        send(.leftMouseUp, at: start, to: panel)
        #expect(panel.dropTargets == nil, "gone on drop")
        settle(panel, 0.35)
        #expect(!overlay.panel.isVisible, "faded out and closed")
        panel.close()
    }

    @Test("the highlighted spot follows the pointer and is where the release snaps")
    func highlightFollowsPointer() throws {
        let (panel, model) = makePanel()
        let display = Self.fakeDisplay
        panel.pointerLocation = { NSPoint(x: display.frame.maxX - 30, y: display.frame.midY + 40) }
        panel.dragChanged()
        #expect(panel.dropTargets?.model.highlighted == .right)
        panel.dragEnded()
        #expect(model.anchor == .right)
        #expect(panel.dropTargets == nil)
        panel.close()
    }

    // MARK: The vertical pill at a side edge

    @Test("at the right edge the resting capsule stands vertical: 10×40")
    func verticalRestingCapsule() throws {
        let (panel, model) = makePanel(.idle, anchor: .right)
        let rect = try #require(model.hitRegions.last)
        #expect(rect.size == CGSize(width: 10, height: 40))
        #expect(rect.maxX <= panel.frame.width - PillGeometry.sideShadowPad + 0.5, "hugs the right edge")
        panel.close()
    }

    @Test("right edge: a tap on the vertical capsule dictates, first time")
    func verticalTap() throws {
        let (panel, model) = makePanel(.idle, anchor: .right)
        var taps = 0
        model.onTapIdle = { taps += 1 }
        let point = try capsuleCentre(panel, model)
        send(.leftMouseDown, at: point, to: panel)
        send(.leftMouseUp, at: point, to: panel)
        settle(panel, 0.1)
        #expect(taps == 1)
        panel.close()
    }

    @Test("right edge: hands-free stands vertical with ✕ on top and ✓ at the bottom, both work")
    func verticalHandsFree() throws {
        let (panel, model) = makePanel(.handsFree(startedAt: Date()), anchor: .right)
        var cancels = 0
        var stops = 0
        model.onCancel = { cancels += 1 }
        model.onStop = { stops += 1 }
        let capsule = try #require(model.hitRegions.last)
        #expect(capsule.height > capsule.width, "vertical")
        let x = capsule.midX
        let top = panel.frame.height - (capsule.minY + 20)
        let bottom = panel.frame.height - (capsule.maxY - 20)
        for (y, type) in [(top, NSEvent.EventType.leftMouseDown), (top, .leftMouseUp),
                          (bottom, .leftMouseDown), (bottom, .leftMouseUp)] {
            send(type, at: NSPoint(x: x, y: y), to: panel)
            settle(panel, 0.05)
        }
        #expect(cancels == 1)
        #expect(stops == 1)
        panel.close()
    }

    @Test("right edge: dragging the vertical capsule reaches the drag callbacks and snaps")
    func verticalDrag() throws {
        let (panel, model) = makePanel(.idle, anchor: .right)
        var changed = 0
        model.onDragChanged = { changed += 1; panel.dragChanged() }
        model.onDragEnded = { panel.dragEnded() }
        let start = try capsuleCentre(panel, model)
        send(.leftMouseDown, at: start, to: panel)
        for step in 1...6 {
            send(.leftMouseDragged, at: NSPoint(x: start.x - CGFloat(step) * 6, y: start.y), to: panel)
        }
        #expect(changed > 0)
        #expect(panel.dropTargets != nil)
        send(.leftMouseUp, at: start, to: panel)
        #expect(panel.dragStart == nil)
        #expect(panel.dropTargets == nil)
        panel.close()
    }

    @Test("while dragging the pill is its resting capsule — no hover, no hints — turned for the edge it nears")
    func dragShowsRestingCapsule() throws {
        let (panel, model) = makePanel()
        model.isHovered = true
        settle(panel, 0.2)
        let display = Self.fakeDisplay
        panel.pointerLocation = { NSPoint(x: display.frame.midX, y: display.frame.minY + 120) }
        panel.dragChanged()
        settle(panel, 0.3)
        #expect(model.isDragging)
        #expect(model.dragAnchor == .bottom)
        #expect(model.hitRegions.count == 1, "no hint label while dragging: \(model.hitRegions)")
        #expect(model.hitRegions.last?.size == CGSize(width: 40, height: 10))
        panel.pointerLocation = { NSPoint(x: display.frame.maxX - 40, y: display.frame.midY) }
        panel.dragChanged()
        settle(panel, 0.3)
        #expect(model.dragAnchor == .right)
        #expect(model.hitRegions.last?.size == CGSize(width: 10, height: 40), "morphs vertical near a side edge")
        panel.dragEnded()
        #expect(!model.isDragging)
        #expect(model.dragAnchor == nil)
        panel.close()
    }

    // MARK: Isolation from the real Mac

    @Test("constructing, dragging and snapping never touch .standard or a real display")
    func neverTouchesRealDefaultsOrDisplays() throws {
        let keys = [PillAnchorStore.key, PillAnchorStore.legacyKey]
        let before = keys.map { UserDefaults.standard.object(forKey: $0) as? Data }
        _ = NSApplication.shared
        let model = PillModel()
        let panel = PillPanel(model: model, environment: Self.fakeEnvironment())
        #expect(Self.fakeDisplay.frame.contains(panel.frame), "placed on the fake display at init")
        for screen in NSScreen.screens {
            #expect(!screen.frame.intersects(panel.frame), "never on a real display")
        }
        panel.pointerLocation = { NSPoint(x: Self.fakeDisplay.frame.maxX - 30, y: Self.fakeDisplay.frame.midY) }
        panel.dragChanged()
        panel.dragEnded()
        #expect(keys.map { UserDefaults.standard.object(forKey: $0) as? Data } == before)
        panel.close()
    }

    // MARK: The drop spots never outlive a drag

    private func startDrag(_ panel: PillPanel) throws -> PillDropTargetsOverlay {
        panel.dragChanged()
        return try #require(panel.dropTargets)
    }

    private func expectGone(_ overlay: PillDropTargetsOverlay, from panel: PillPanel) {
        #expect(panel.dropTargets == nil)
        #expect(panel.dragStart == nil)
        #expect(!panel.model.isDragging)
        settle(panel, until: { !overlay.panel.isVisible })
        #expect(!overlay.panel.isVisible)
    }

    @Test("closing the pill mid-drag removes the drop spots")
    func closeMidDrag() throws {
        let (panel, _) = makePanel()
        let overlay = try startDrag(panel)
        panel.close()
        expectGone(overlay, from: panel)
    }

    @Test("a mouse-up delivered to another app ends the drag and removes the drop spots")
    func mouseUpElsewhere() throws {
        let (panel, _) = makePanel()
        let overlay = try startDrag(panel)
        panel.mouseUpElsewhere()
        expectGone(overlay, from: panel)
        panel.close()
    }

    @Test("switching apps or Hushy resigning active mid-drag cancels it", arguments: [0, 1])
    func deactivationMidDrag(which: Int) throws {
        let (panel, model) = makePanel()
        let overlay = try startDrag(panel)
        if which == 0 {
            panel.environment.workspaceNotificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                                                       object: NSWorkspace.shared)
        } else {
            panel.environment.notificationCenter.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        }
        expectGone(overlay, from: panel)
        #expect(model.anchor == .bottom, "cancelled: back to its saved edge, nothing saved")
        panel.close()
    }

    @Test("the pill's state changing mid-drag (a dictation starts) cancels it")
    func stateChangeMidDrag() throws {
        let (panel, _) = makePanel()
        let overlay = try startDrag(panel)
        panel.setState(.listening)
        expectGone(overlay, from: panel)
        panel.close()
    }

    @Test("no drag event for the idle timeout with the button up: the drag ends and the spots go")
    func idleTimeout() throws {
        let (panel, _) = makePanel(environment: Self.fakeEnvironment(idleTimeout: 0.2, buttonDown: false))
        let overlay = try startDrag(panel)
        settle(panel, until: { panel.dropTargets == nil })
        expectGone(overlay, from: panel)
        panel.close()
    }

    @Test("holding still with the button down keeps the drag (the timeout re-arms)")
    func idleTimeoutButtonHeld() throws {
        let checks = ButtonChecks()
        let (panel, _) = makePanel(environment: Self.fakeEnvironment(
            idleTimeout: 0.2, buttonDown: true, buttonChecked: { checks.count += 1 }))
        _ = try startDrag(panel)
        // The timer has fired twice, so it re-armed once and is still holding the drag (not a fixed pause).
        settle(panel, until: { checks.count >= 2 })
        #expect(checks.count >= 2)
        #expect(panel.dropTargets != nil)
        #expect(panel.dragStart != nil)
        panel.close()
    }
}

/// How many times the pill asked whether the mouse button was down.
@MainActor
private final class ButtonChecks {
    var count = 0
}
