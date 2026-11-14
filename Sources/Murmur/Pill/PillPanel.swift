import AppKit
import os
import MurmurCore
import SwiftUI

/// A borderless, non-activating panel that floats above every app and Space without
/// ever taking focus away from the text field the user is dictating into.
@MainActor
final class PillPanel: NSPanel {
    private static let log = Logger(subsystem: "app.hushy", category: "pill")
    /// Tall enough to fit the ✕/✓ hover hints ("Cancel", "Done") above the
    /// pill without clipping — the pill itself stays anchored to the bottom of this frame.
    static let size = NSSize(width: 280, height: 104)
    /// One-line outcome rows ("Copied · moved to another field  ⌘ V to paste" is ~310 pt) need
    /// more width than the idle pill, never more height.
    static let rowSize = NSSize(width: 360, height: 104)
    /// States with hover hints on their buttons: wide enough for the roomiest hint (15 pt, with a
    /// key cap) to sit over either button, clamped inside, without clipping. The extra width is
    /// click-through (only drawn shapes take the pointer).
    static let hintSize = NSSize(width: 420, height: 104)
    /// A dictation failure is one line with ✕ (and, when the audio is kept, a button): the longest
    /// is wider than the other rows, never taller.
    static let failureSize = NSSize(width: 500, height: 104)
    /// Room beside the 440 pt confirm card for its shadow.
    private static let confirmShadowMargin: CGFloat = 12
    /// Each stacked confirm row adds this much height (max 3 rows).
    static let confirmRowHeight: CGFloat = 52

    /// The panel for a pill state. Every dictation outcome is a one-line row at the pill's height
    /// (a little wider than idle, so the longest reason isn't clipped); a single action is the
    /// capsule itself (wider, same height); only 2–3 stacked confirm rows grow it, 52 pt each
    /// (UI round 2026-09-28 §1).
    /// A vertical capsule at a side edge needs height, not width (✕, bars, ✓ stacked).
    static let verticalHeight: CGFloat = 200

    /// The one width the panel has at the bottom and top edges, whatever it shows: the widest any
    /// state needs there (`failureSize`, and the cards with their shadow).
    ///
    /// The pill is centred in its panel at those edges. A panel that changes width moves its left
    /// edge on the display at once, while the content inside is still laid out for the old width
    /// and catches up a frame, or a whole state-change animation, later: a row was seen to start
    /// well left of centre and slide in, and the resting pill to sit a few points right after a
    /// row closed (2026-10-12). With one width the panel never moves sideways, so nothing inside
    /// it can be seen to. The extra width is click-through (`PillHitTest`), as it always was.
    static let centredWidth: CGFloat = 500

    /// The frame the panel takes for a state: what the state needs (`size(for:anchor:)`), at the
    /// one centred width when the pill rests on the bottom or top edge. At a side edge the panel
    /// and its content hug that edge together, so a change of width moves nothing.
    static func frameSize(for state: PillState, anchor: PillAnchor) -> NSSize {
        let needed = size(for: state, anchor: anchor)
        return anchor.isSide ? needed : NSSize(width: max(needed.width, centredWidth), height: needed.height)
    }

    /// The room a state needs: its rows, cards and hints. The panel's frame is `frameSize`.
    static func size(for state: PillState, anchor: PillAnchor = .bottom) -> NSSize {
        let base = horizontalSize(for: state)
        guard anchor.isSide, PillLayout.canStandVertical(state) else { return base }
        return NSSize(width: base.width, height: max(base.height, verticalHeight))
    }

    private static func horizontalSize(for state: PillState) -> NSSize {
        switch state {
        case .copied, .held, .error, .actionDone, .voiceEdit: return rowSize
        case .failed, .nameOffer, .restyle: return failureSize
        // "Pasted · quick cleanup only" and "Pasted · Return not pressed" are wider than the idle panel.
        case .done(_, _, asHeard: true, _, _), .done(_, _, _, notSent: true, _): return rowSize
        case .handsFree, .recordingNote, .actionListening: return hintSize
        case .actionConfirm: break
        case .answer(let card):
            // The answer card stacks on the capsule like the multi-row confirm card; its height
            // follows the answer (`estimatedHeight` reserves room; the card lays itself out).
            return NSSize(width: AnswerCard.width + 2 * confirmShadowMargin, height: size.height + card.estimatedHeight)
        case .noField(let mode):
            return NSSize(width: NoFieldCard.width + 2 * confirmShadowMargin,
                          height: size.height + NoFieldCard.panelHeight(for: mode))
        default: return size
        }
        guard case .actionConfirm(let card) = state else { return size }
        let width = ActionConfirmationCard.width + 2 * confirmShadowMargin
        let rows = min(card.rows.count, 3)
        guard rows > 1 else { return NSSize(width: width, height: size.height) }
        return NSSize(width: width, height: size.height + confirmRowHeight * CGFloat(rows))
    }
    private var moveObserver: Any?
    private var activationObserver: Any?
    private var spaceObserver: Any?
    private var mouseMonitors: [Any] = []
    let model: PillModel
    /// Displays, pointer, defaults… from the Mac, or injected by the harness (at init).
    let environment: PillPanelEnvironment
    /// The per-display anchors (`PillAnchorStore`); migrated from a free-form position once.
    var prefs: PillAnchorPrefs
    /// The current state's panel size (`size(for:)`).
    /// The state the panel is sized for; the size also depends on the anchor (a vertical pill
    /// at a side edge needs height).
    private(set) var currentState: PillState = .idle
    var currentSize: NSSize { Self.frameSize(for: currentState, anchor: model.anchor) }
    /// The size a shrinking panel keeps until the content has animated down into the smaller
    /// state (`setState`), else nil. A panel frame can't animate with the SwiftUI content, so
    /// shrinking it at once clipped the old content mid-animation.
    private var heldSize: NSSize?
    private var shrinkTask: Task<Void, Never>?
    /// The size the panel is actually laid out at: the current size, or the held larger one.
    var layoutSize: NSSize {
        guard let held = heldSize else { return currentSize }
        return Self.larger(held, currentSize)
    }
    /// A shrink is waiting for the content to settle.
    var hasPendingResize: Bool { heldSize != nil }

    private static func larger(_ a: NSSize, _ b: NSSize) -> NSSize {
        NSSize(width: max(a.width, b.width), height: max(a.height, b.height))
    }
    /// The drop spots, only while a drag is in progress (`PillDropTargetsOverlay`).
    private(set) var dropTargets: PillDropTargetsOverlay?
    /// Ends a drag that stops getting events (`PillPanelEnvironment.dragIdleTimeout`).
    private var dragIdleTimer: Timer?
    private var dragCancelObservers: [(NotificationCenter, Any)] = []

    /// The display under a point, else the first one.
    func displayAt(_ point: NSPoint) -> PillDisplay? {
        let displays = environment.displays()
        return displays.first { $0.frame.contains(point) } ?? displays.first
    }

    var anchorDefaults: UserDefaults { environment.anchorDefaults }
    /// The state has a control (`PillState.isInteractive`); clicks are still taken only over
    /// drawn shapes (`PillHitTest`).
    private var wantsMouse = false
    /// Open/closed with a press latch and hysteresis (`PillMouseGate`, pure and tested).
    private(set) var gate = PillMouseGate()
    /// Where the pointer is (screen points). Injectable so the headless harness can hover.
    var pointerLocation: @MainActor () -> NSPoint
    var dragStart: (mouse: NSPoint, origin: CGPoint)?

    init(model: PillModel, environment: PillPanelEnvironment = .live) {
        self.model = model
        self.environment = environment
        prefs = PillAnchorStore.load(from: environment.anchorDefaults)
        pointerLocation = environment.pointerLocation
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isFloatingPanel = true
        // `.statusBar` can still be covered by another app's own always-on-top window (reported:
        // our pill gets covered by the app being dictated into when our main window is frontmost
        // elsewhere). `.popUpMenu` sits well above regular app windows and the menu bar/status
        // items, but below `.screenSaver`, so it never blocks the lock screen or screen saver —
        // the right trade-off for a control that must always be reachable but must never fight
        // the OS for the very top of the stack.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true

        let host = PillHostingView(rootView: PillView(model: model))
        host.sizingOptions = []
        contentView = host
        model.onHitRegionsChange = { [weak self] in self?.regionsChanged() }
        installMouseMonitors()
        observeDragCancellers()
        reposition()
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        // Re-assert topmost placement whenever the app becomes active or the user switches
        // Spaces — both are moments another window (including our own) can otherwise end up
        // stacked above the pill despite its window level.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.orderFrontRegardless() }
        }
        spaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared, queue: .main
        ) { [weak self] _ in
            // A full-screen Space can hide the menu bar and Dock: re-place against its frame.
            MainActor.assumeIsolated {
                self?.reposition()
                self?.orderFrontRegardless()
            }
        }
    }


    /// Never, but for the one moment the person has opened a word to correct its spelling: the
    /// spelling field needs the keyboard, and gives it back when the row closes (`syncKeyboard`).
    override var canBecomeKey: Bool { environment.allowsKeyboard && model.isEditingName }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        keyboardLeft()
    }

    /// Grows the panel for a confirm card, shrinks it back so it never blocks clicks.
    func setState(_ state: PillState) {
        // A dictation (or any state change) starting mid-drag cancels the drag.
        if dragStart != nil, state != currentState { cancelDrag() }
        let before = layoutSize
        currentState = state
        // Growing is immediate (the new content needs the room at once). Shrinking waits: the
        // content animates down inside the old frame, then the frame follows in one step, so
        // action-done → idle reads as one smooth size change, like dictation's Done.
        let wanted = Self.larger(before, currentSize)
        shrinkTask?.cancel()
        shrinkTask = nil
        heldSize = wanted == currentSize ? nil : wanted
        if heldSize != nil { scheduleShrink() }
        guard layoutSize != before else { return }
        reposition()
    }

    private func scheduleShrink() {
        let delay = model.motion.shrinkDelay(reduceMotion: reduceMotion)
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.finishPendingResize()
        }
    }

    /// Whether the pill holds still: the Mac's Reduce Motion setting, unless the preview overrides it.
    var reduceMotion: Bool {
        model.reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Lands the waiting shrink now (its timer, or a test, calls this).
    func finishPendingResize() {
        shrinkTask?.cancel()
        shrinkTask = nil
        guard heldSize != nil else { return }
        heldSize = nil
        reposition()
    }

    /// Shows or moves the drop spots for the display under `pointer`.
    func showDropTargets(at pointer: NSPoint) {
        guard let display = displayAt(pointer) else { return }
        if dropTargets == nil { dropTargets = PillDropTargetsOverlay(pillLevel: level) }
        dropTargets?.update(display: display, pointer: pointer)
    }

    func hideDropTargets() {
        dropTargets?.dismiss()
        dropTargets = nil
    }

    /// Whether the state has anything to click. Even then, only drawn shapes take the pointer.
    func setInteractive(_ interactive: Bool) {
        if interactive != wantsMouse { Self.log.info("pill interactive=\(interactive, privacy: .public)") }
        wantsMouse = interactive
        updateMouseGate()
    }

    // MARK: Click-through

    /// Takes the pointer only over the capsule, rows, cards, banners and a showing tooltip; the
    /// rest of the (larger, transparent) panel lets clicks reach the app underneath. A hit-test
    /// override can't do this — a view returning nil still swallows the click — so the window
    /// itself ignores the mouse until the pointer is over a shape (DECISIONS 2026-09-28).
    func updateMouseGate(at point: NSPoint? = nil) {
        let point = point ?? pointerLocation()
        gate.isDragging = dragStart != nil
        gate.pointerMoved(to: point, regions: model.hitRegions, inWindow: frame, interactive: wantsMouse)
        applyGate(reason: "move")
        // While ignoring the mouse the window never sees the pointer leave, so end the hover
        // here — only on a real pointer move, never because the shapes changed under it.
        if !gate.isOpen, model.isHovered { model.isHovered = false }
        if !gate.isOpen, model.isPointerOverCard { model.isPointerOverCard = false }
    }

    /// The drawn shapes changed (hover growing, a hint or row appearing): may open, never closes.
    private func regionsChanged() {
        gate.regionsChanged(pointer: pointerLocation(), regions: model.hitRegions, inWindow: frame,
                            interactive: wantsMouse)
        applyGate(reason: "regions")
    }

    private func applyGate(reason: StaticString) {
        guard ignoresMouseEvents == gate.isOpen else { return }
        ignoresMouseEvents = !gate.isOpen
        let shapes = model.hitRegions.map { PillHitTest.screenRect($0, inWindow: frame) }
        Self.log.info("""
            mouse gate \(self.gate.isOpen ? "open" : "closed", privacy: .public) on \(String(describing: reason), privacy: .public) \
            interactive=\(self.wantsMouse, privacy: .public) pointer=\(String(describing: self.pointerLocation()), privacy: .public) \
            shapes=\(String(describing: shapes), privacy: .public)
            """)
    }

    /// Latches the gate open from mouse-down to mouse-up, so a region change or state change
    /// mid-press can't swallow the release (a tap that never ends, a drag that never starts).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            // Diagnostics for the founder's live test: every press/release, the view it hits and
            // the gate, so a click that never reaches a SwiftUI gesture shows where it stopped.
            let hit = contentView?.hitTest(event.locationInWindow).map { String(describing: type(of: $0)) } ?? "nil"
            Self.log.info("""
                pill \(event.type == .leftMouseDown ? "down" : "up", privacy: .public) at \
                \(event.locationInWindow.debugDescription, privacy: .public) hit=\(hit, privacy: .public) \
                ignores=\(self.ignoresMouseEvents, privacy: .public) gate=\(self.gate.isOpen, privacy: .public)
                """)
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            gate.mouseDown()
            applyGate(reason: "down")
        default:
            break
        }
        super.sendEvent(event)
        switch event.type {
        case .leftMouseUp, .rightMouseUp:
            // SwiftUI can cancel a DragGesture without calling onEnded when the window moves
            // under it (the pill's own drag moves the panel), so the release that ends a drag
            // snaps here. dragEnded() clears dragStart, so a late onEnded is a harmless no-op.
            if event.type == .leftMouseUp, dragStart != nil {
                Self.log.info("pill drag ended by mouse-up; snapping")
                dragEnded()
            }
            gate.isDragging = dragStart != nil
            gate.mouseUp(at: pointerLocation(), regions: model.hitRegions, inWindow: frame, interactive: wantsMouse)
            applyGate(reason: "up")
        default:
            break
        }
    }

    /// Pointer moves anywhere (global: over other apps; local: over our own windows). Mouse
    /// monitors need no permission; they only read the position.
    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask.union(.leftMouseUp), handler: { [weak self] event in
            MainActor.assumeIsolated {
                // A release delivered to another app still ends our drag.
                if event.type == .leftMouseUp { self?.mouseUpElsewhere() }
                self?.updateMouseGate()
            }
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouseGate() }
            return event
        }) { mouseMonitors.append(local) }
    }

    // MARK: Drags that end without a release here

    /// Closing the pill never leaves its drop spots behind.
    override func close() {
        cancelDrag(reposition: false)
        super.close()
    }

    /// App switch / Hushy resigning active mid-drag: cancel it.
    private func observeDragCancellers() {
        let cancel: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelDrag() }
        }
        let workspace = environment.workspaceNotificationCenter
        let center = environment.notificationCenter
        dragCancelObservers = [
            (workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                              object: nil, queue: .main, using: cancel)),
            (center, center.addObserver(forName: NSApplication.didResignActiveNotification,
                                        object: nil, queue: .main, using: cancel)),
        ]
    }

    /// The release went to another app (the pointer outran the panel): end the drag there.
    func mouseUpElsewhere() {
        guard dragStart != nil else { return }
        dragEnded()
    }

    /// Ends a drag without snapping: back to the saved edge, drop spots gone.
    func cancelDrag(reposition shouldReposition: Bool = true) {
        guard dragStart != nil || dropTargets != nil else { return }
        dragStart = nil
        stopDragIdleTimer()
        hideDropTargets()
        model.isDragging = false
        model.dragAnchor = nil
        if shouldReposition { reposition() }
    }

    /// Re-armed on every drag event; if none arrives in time and the button is up, the drag ends.
    func armDragIdleTimer() {
        stopDragIdleTimer()
        let timer = Timer(timeInterval: environment.dragIdleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dragStart != nil else { return }
                if self.environment.isMouseButtonDown() { self.armDragIdleTimer() } else { self.dragEnded() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragIdleTimer = timer
    }

    func stopDragIdleTimer() {
        dragIdleTimer?.invalidate()
        dragIdleTimer = nil
    }
}

/// The pill's SwiftUI host. A non-activating panel that never becomes key must still act on the
/// first click (tap to dictate, ✕/✓), not spend it on activation.
final class PillHostingView: NSHostingView<PillView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
