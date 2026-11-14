import AppKit
import Carbon.HIToolbox
import CoreGraphics
import MurmurCore
import os

/// Which key (held) starts dictation.
enum TriggerKey: String, CaseIterable, Identifiable, Codable {
    case fn
    case rightOption
    case rightCommand
    case controlOption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fn: "fn (Globe)"
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .controlOption: "⌃ Control + ⌥ Option"
        }
    }

    var shortTitle: String {
        switch self {
        case .fn: "fn / Globe"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .controlOption: "Control + Option"
        }
    }

    var glyph: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        case .controlOption: "⌃⌥"
        }
    }
}

/// Events the dictation controller reacts to.
enum HotkeyEvent: Equatable {
    /// Trigger pressed: start listening in push-to-talk mode.
    case pressed
    /// Trigger released after holding.
    case released
    /// Hands-free latched (short solo tap or trigger + Space).
    case latched
    /// Trigger pressed while latched: stop and insert.
    case stopLatched
    /// Return (or ⌘Return) while hands-free: stop and paste. Hushy never presses Return after a
    /// paste on its own — paste-and-send was removed (founder decision 2026-09-28).
    case finishLatched
    /// Esc while recording or processing.
    case cancel
    /// Another key was pressed while holding the trigger (e.g. fn+arrow): abort silently.
    case interrupted
    /// The action chord (fn+control) engaged while the trigger was held: the hold belongs to the
    /// action now, so a push-to-talk recording started on it is dropped silently, however long
    /// it has run (unlike `interrupted`, which only drops a fresh one).
    case chordTaken
    /// Paste the last transcript (⌃⌘V).
    case pasteLast
    /// Copy the last transcript to the clipboard (⌃⌘C). Types nothing.
    case copyLast
    /// The restyle shortcut (`RestyleShortcut`): show the tone chips over the selected text.
    case restyleSelection
}

/// Global key monitoring through a Quartz event tap.
///
/// Requires Accessibility permission. The tap passes every event through except the few it
/// consumes while dictating (Space to latch, Esc to cancel, the ⌃⌘V and ⌃⌘C shortcuts), plus plain ⏎/esc
/// while the pill shows a row that asks a question (`PillKeyScope`).
///
/// The tap runs on its own thread (`EventTapThread`): every key and click on the Mac waits on its
/// callback, so it never waits on the main thread. Each event is timed from its own stamp
/// (`EventClock`), so a quick tap stays a tap however late anything reads it. The callback decides at
/// once whether to swallow the event; what the event meant reaches the main actor afterwards, in
/// order (`deliverPendingEvents`). The recognisers' state is shared by the tap thread and the main
/// actor (the controller sets `isDictationActive` and `isLatched`), so it is read and written under
/// `lock`, and no handler runs while the tap thread holds it.
final class HotkeyMonitor: @unchecked Sendable {
    /// Guards every field the tap thread reads. Recursive because on the main-thread path (`handle`) a
    /// handler may set `isLatched` from inside the call.
    private let lock = NSRecursiveLock()

    var trigger: TriggerKey {
        get { locked { _trigger } }
        set { locked { _trigger = newValue } }
    }
    /// Set by the controller so Esc / Space are only consumed while dictating.
    var isDictationActive: Bool {
        get { locked { _isDictationActive } }
        set { locked { _isDictationActive = newValue } }
    }
    var isLatched: Bool {
        get { locked { _isLatched } }
        set { locked { _isLatched = newValue } }
    }
    /// The handlers below are the main actor's: they are called on the main thread only.
    var onEvent: ((HotkeyEvent) -> Void)?
    var onTimedEvent: ((HotkeyEvent, Date) -> Void)?
    /// The dictation key going down or up, with the time the tap saw it. Set only by onboarding's
    /// key lesson (`KeyGesturePractice`), which needs the raw presses to tell a double-tap from a
    /// hold: the second tap of a double-tap is swallowed and has no `HotkeyEvent` of its own. A
    /// press that completes the action chord is not reported. Delivered after the tap returns.
    var onTriggerEdge: ((_ isDown: Bool, _ at: Date) -> Void)?
    /// What the pill's showing rows answer (read per key-down, so it is never stale), and where
    /// those answers go. Outside a dictation only; `.none` takes nothing (`PillKeyRouter`).
    var pillKeyScope: () -> PillKeyScope = { .none }
    /// Whether the pill's state could take a key at all (`PillState.keyScope` is not `.none`). The
    /// tap thread asks the main actor for `pillKeyScope` only while this holds, so ⏎ and esc never
    /// wait on the main thread while the pill asks nothing.
    var pillKeysPossible: Bool {
        get { locked { _pillKeysPossible } }
        set { locked { _pillKeysPossible = newValue } }
    }
    var onPillKey: ((PillKey) -> Void)?
    /// A ⏎, ⌘⏎ or keypad Enter went down and was passed to the app (so the person may have just
    /// sent a message). Told after the tap callback has returned, never from inside it: the key
    /// is never held up, and nothing about the event is read beyond its code and modifiers.
    var onReturnKey: (() -> Void)?
    /// The voice-action chord (fn+control), fed every `flagsChanged` this tap sees. It is read
    /// *before* the dictation decision so the chord wins in either key order: a fn-down that
    /// completes the chord never starts dictation, and a control-down that completes it while a
    /// push-to-talk dictation runs on the held fn drops that dictation (`HotkeyEvent.chordTaken`).
    var chord: ActionHotkeyMonitor? {
        get { locked { _chord } }
        set { locked { _chord = newValue; newValue?.trigger = _actionTrigger } }
    }
    /// The key pressed twice for a voice action, already reconciled with the dictation key.
    var actionTrigger: ActionTriggerKey {
        get { locked { _actionTrigger } }
        set { locked { _actionTrigger = newValue; _chord?.trigger = newValue } }
    }
    /// The chord that restyles the selected text. Taken only on the key-down itself: nothing is read until it is pressed.
    var restyleShortcut: RestyleShortcut {
        get { locked { _restyleShortcut } }
        set { locked { _restyleShortcut = newValue } }
    }
    /// Posts the synthetic fn-down that hands a fn combo back to macOS (`repostFnDownIfNeeded`).
    /// Replaceable so tests can count reposts without posting real events.
    var postSynthetic: (CGEvent) -> Void {
        get { locked { _postSynthetic } }
        set { locked { _postSynthetic = newValue } }
    }
    /// The clock of the main-thread path (`handle`), which tests drive by hand.
    var now: () -> Date = Date.init
    /// The clocks the tap path reads once per event, to date the event's stamp (`EventClock`).
    /// Replaced by tests that inject stamped events as if the tap had read them late.
    var tapClock: () -> EventClock.Reading {
        get { locked { _tapClock } }
        set { locked { _tapClock = newValue } }
    }
    static let doubleTapWindow: TimeInterval = 0.4
    /// The longest the tap thread waits for the main actor to say what the pill takes. Past it the
    /// key goes to the app, so a busy main thread delays ⏎ or esc by at most this, and only while a
    /// pill row asks a question.
    static let pillScopeWait: DispatchTimeInterval = .milliseconds(50)

    private var _trigger: TriggerKey = .fn
    private var _isDictationActive = false
    private var _isLatched = false
    private var _pillKeysPossible = true
    private var _chord: ActionHotkeyMonitor?
    private var _actionTrigger = ActionTriggerKey.default
    private var _restyleShortcut = RestyleShortcut.default
    private var _postSynthetic: (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }
    private var _tapClock: () -> EventClock.Reading = EventClock.Reading.now

    private var tap: CFMachPort?
    private var tapThread: EventTapThread?
    private var didLogTapFailure = false
    private var runLoopSource: CFRunLoopSource?
    private var triggerDown = false
    /// The held trigger is the chord's: no dictation event for it, and its release doesn't count
    /// toward a double-tap latch.
    private var chordHoldsTrigger = false
    private var triggerInterrupted = false
    private var stoppingLatchedPress = false
    private var mouseMonitors: [Any] = []
    private var lastTriggerDown: Date = .distantPast
    /// When a short tap last latched hands-free. A second tap inside `doubleTapWindow` is the
    /// other half of a double-click, the gesture people bring from other dictation apps: it stays
    /// in hands-free instead of ending a recording that has only just begun.
    private var tapLatchedAt: Date = .distantPast
    private var watchdog: Timer?
    private var deferringTapEffects = false
    private var recordedAt = Date.distantPast
    /// The clocks read for the event being handled, for the chord's stamp.
    private var reading = EventClock.Reading.now()
    /// What the pill takes for the event being handled, when the tap thread already asked.
    private var presetPillScope: PillKeyScope?
    /// What one recorded event meant, gathered while it is handled: signals first, then edges,
    /// then dictation events, then the chord's, the order they always reached the main actor in.
    private var pendingSignals: [TapOutput] = []
    private var pendingEdges: [TapOutput] = []
    private var pendingEvents: [TapOutput] = []
    /// Everything recorded and not yet delivered, oldest first.
    private var outbox: [TapOutput] = []
    private var drainScheduled = false

    private enum TapOutput {
        case pillKey(PillKey)
        case returnKey
        case edge(isDown: Bool, at: Date)
        case event(HotkeyEvent, at: Date)
        case action(ActionHotkeyEvent)
    }

    /// Only used when `trigger == .fn`. Decides whether a solo fn press/hold should be hidden
    /// from macOS (so it doesn't run the Globe key's action or start its own Dictation) while
    /// letting fn+combo (arrows, F-keys, Delete, E, ⌃…) behave normally. See
    /// `FnCaptureDecider`'s doc comment for the full design and sources.
    private var fnCapture = FnCaptureDecider.State()

    private let log = Logger(subsystem: "app.hushy", category: "hotkey")

    var isInstalled: Bool { installedTap != nil }
    private var installedTap: CFMachPort? { locked { tap } }

    static func shouldRecreateTap(accessibility: Permissions.Status, isInstalled: Bool) -> Bool {
        accessibility == .granted && !isInstalled
    }

    /// Whether Hushy is actively hiding a solo fn press from macOS right now (tap installed,
    /// `.defaultTap` so it can consume events, and fn is the configured trigger). When this is
    /// true, macOS never sees the bare fn `flagsChanged` that its Globe-key action and Dictation
    /// double-press both depend on — so those readiness warnings no longer apply. See
    /// `FnCaptureDecider` for why capturing the flagsChanged event is sufficient on its own.
    var isFnCaptureActive: Bool { trigger == .fn && isInstalled }

    /// The events the tap asks for.
    /// Mouse-downs are rare and the handler returns at once, so they cost the tap nothing; scroll
    /// and movement stream and are deliberately not asked for (see `startMouseObservers`).
    static let tapEventMask: CGEventMask =
        (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        | (1 << CGEventType.otherMouseDown.rawValue)

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Installs the tap on its own thread; returns false when Accessibility permission is missing.
    @MainActor
    @discardableResult
    func start() -> Bool {
        guard !isInstalled else { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.tapEventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
                return monitor.receive(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: context)
        else {
            if !didLogTapFailure {
                log.error("event tap failed: Accessibility trusted=\(AXIsProcessTrusted(), privacy: .public)")
                didLogTapFailure = true
            }
            return false
        }
        didLogTapFailure = false
        log.notice("event tap installed, trigger=\(self.trigger.rawValue, privacy: .public)")

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = EventTapThread()
        thread.start()
        // The process's first trip through the tap path costs 20-60 ms once (the runtime's first type
        // lookups, the logger; measured in `EventTapThreadTests`). A throwaway monitor pays it here,
        // so the first real key does not.
        thread.perform {
            guard let event = CGEvent(source: nil) else { return }
            _ = HotkeyMonitor().handleRecorded(type: .flagsChanged, event: event, at: Date())
        }
        if let source { thread.add(source) }
        locked {
            self.tap = tap
            runLoopSource = source
            tapThread = thread
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        startWatchdog()
        startMouseObservers()
        return true
    }

    /// The wheel moving voids a half-finished double tap (a Control-scroll zoom). Mouse buttons come
    /// through the tap itself (`tapEventMask`), in every app including Hushy's own. Scroll stays an
    /// observation outside the event path, so a scroll stream never waits on this tap: the global
    /// monitor sees other apps, the local one Hushy's own (and misses a scroll consumed by a nested
    /// tracking loop, a documented limit). Only the *fact* reaches the recogniser: no location,
    /// no window, no target.
    @MainActor
    private func startMouseObservers() {
        guard mouseMonitors.isEmpty else { return }
        let kinds: NSEvent.EventTypeMask = [.scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
            self?.observeMouse()
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            self?.observeMouse()
            return event
        }) { mouseMonitors.append(local) }
    }

    private func observeMouse() {
        locked { _chord?.observeMouse() }
    }

    @MainActor
    func stop() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        watchdog?.invalidate()
        watchdog = nil
        let (tap, source, thread) = locked { () -> (CFMachPort?, CFRunLoopSource?, EventTapThread?) in
            defer { self.tap = nil; runLoopSource = nil; tapThread = nil }
            return (self.tap, runLoopSource, tapThread)
        }
        if let source { thread?.remove(source) }
        if let tap { CFMachPortInvalidate(tap) }
        thread?.stop()
    }

    /// macOS disables slow or suspended taps (e.g. after sleep); re-arm within a second.
    @MainActor
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let tap = self?.installedTap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// The tap's callback, on the tap thread: the event is judged at once, timed from its own stamp,
    /// and what it meant goes to the main actor afterwards. A test seam as well: a stamped synthetic
    /// event fed here takes exactly the tap's path.
    func receive(type: CGEventType, event: CGEvent) -> Bool {
        let reading = tapClock()
        let time = EventClock.date(ofStamp: event.timestamp, at: reading)
        let scope = pillScopeForTap(type: type, event: event)
        return handleRecorded(type: type, event: event, at: time, reading: reading, pillScope: scope)
    }

    /// What the pill takes for this key-down, asked of the main actor without holding `lock` (the main
    /// thread may be waiting for it). Only ⏎, keypad Enter and esc can be pill keys, and only outside a
    /// dictation while a pill row asks something; any other event asks nothing.
    private func pillScopeForTap(type: CGEventType, event: CGEvent) -> PillKeyScope {
        guard type == .keyDown else { return .none }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape].contains(keyCode),
              locked({ !_isDictationActive && _pillKeysPossible }) else { return .none }
        if Thread.isMainThread { return MainActor.assumeIsolated { pillKeyScope() } }
        let answer = PillScopeAnswer()
        DispatchQueue.main.async { [weak self] in
            answer.set(MainActor.assumeIsolated { self?.pillKeyScope() ?? .none })
        }
        guard let scope = answer.wait(Self.pillScopeWait) else {
            log.error("pill key scope: main thread busy; the key goes to the app")
            return .none
        }
        return scope
    }

    /// Returns true when the event should be swallowed. The main-thread path: handlers run inside
    /// the call. Tests feed the real state machine synthetic `CGEvent`s through it without a tap.
    @discardableResult
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        locked {
            if !deferringTapEffects { reading = .now() }
            return classify(type: type, event: event)
        }
    }

    private func classify(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            log.error("event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Events may have been dropped while the tap was disabled — we could have missed a
            // fn-up (or the interrupting keyDown of a combo). Reset to a clean slate rather than
            // risk leaving fn's capture state stuck mid-hold, which would swallow a future fn-up
            // that doesn't belong to any held-down fn, or skip a repost that was still owed.
            let held = triggerDown
            let latched = _isLatched
            triggerDown = false
            chordHoldsTrigger = false
            triggerInterrupted = false
            stoppingLatchedPress = false
            fnCapture = FnCaptureDecider.State()
            _chord?.reset()
            // The key-up that would have ended the hold was dropped with the tap. Leaving
            // `triggerDown` clear without this event kept push-to-talk recording with the mic open.
            if held { emit(latched ? .stopLatched : .released) }
            return false
        case .flagsChanged:
            // The chord is judged on the flags before dictation acts on them, and told after, so
            // a dictation dropped by `chordTaken` is already idle when the chord's `.pressed`
            // reaches `VoiceActionsController` (which refuses to start while dictation is busy).
            let chordEngaging = _chord?.engages(event.flags) ?? false
            let consumed = handleFlags(event, chordEngaging: chordEngaging)
            _chord?.observe(event.flags)
            // The double tap sees the same event last, and never swallows it: a bare modifier
            // tap does nothing in the front app, so every trigger key event passes untouched.
            _chord?.observeTap(
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
                timestamp: EventClock.uptimeSeconds(ofStamp: event.timestamp, at: reading))
            return consumed
        case .keyDown:
            _chord?.observeKeyDown()
            if triggerDown,
               Int(event.getIntegerValueField(.keyboardEventKeycode)) != kVK_Space {
                triggerInterrupted = true
            }
            // A key the pill takes (⏎ finishes an action, esc discards it, …) never reaches the
            // app, so it must not hand a synthetic fn-down to macOS either: alone, that down and
            // the real up would read as a solo Globe press (emoji picker, input switch).
            if let key = pillKey(for: event) {
                if deferringTapEffects { pendingSignals.append(.pillKey(key)) } else { onPillKey?(key) }
                return true
            }
            repostFnDownIfNeeded(before: event)
            let consumed = handleKeyDown(event)
            if !consumed, Self.sendsMessage(
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) { signalReturnKey() }
            return consumed
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Only the fact that a button went down: it voids a half-finished double tap. Nothing
            // about the event is read, and it always passes through untouched.
            _chord?.observeMouse()
            return false
        default:
            return false
        }
    }

    /// The pill's answer to this key-down, if the showing row takes it (outside a dictation only).
    private func pillKey(for event: CGEvent) -> PillKey? {
        guard !_isDictationActive else { return nil }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let scope = presetPillScope ?? (Thread.isMainThread ? MainActor.assumeIsolated { pillKeyScope() } : .none)
        return PillKeyRouter.key(keyCode: keyCode, flags: event.flags, scope: scope)
    }

    /// Pure: the always-on shortcuts. ⌃⌘V is paste-last, ⌃⌘C is copy-last; both need exactly ⌃ and
    /// ⌘ (no ⇧ or ⌥), so plain ⌘C and the apps' own chords are never taken.
    static func globalShortcut(keyCode: Int, flags: CGEventFlags) -> HotkeyEvent? {
        guard flags.contains(.maskControl), flags.contains(.maskCommand),
              !flags.contains(.maskAlternate), !flags.contains(.maskShift) else { return nil }
        switch keyCode {
        case kVK_ANSI_V: return .pasteLast
        case kVK_ANSI_C: return .copyLast
        default: return nil
        }
    }

    /// Pure: whether a key-down is the one that sends a chat message: ⏎, keypad
    /// Enter or ⌘⏎, not held down (auto-repeat) and not with ⇧, ⌥ or ⌃ (a new line, or another shortcut).
    static func sendsMessage(keyCode: Int, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        guard keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter, !isRepeat else { return false }
        return flags.intersection([.maskShift, .maskAlternate, .maskControl]).isEmpty
    }

    /// Runs `onReturnKey` once the tap callback is done (the recorded path), so the callback
    /// returns at once and the event is neither delayed nor changed.
    private func signalReturnKey() {
        guard deferringTapEffects else { onReturnKey?(); return }
        pendingSignals.append(.returnKey)
    }

    /// Pure: whether a key-down finishes a hands-free dictation. ⏎, keypad Enter and ⌘⏎ alike —
    /// the modifier no longer means "and send" (`flags` only documents that it's ignored).
    static func finishesLatched(keyCode: Int, flags: CGEventFlags, isLatched: Bool) -> Bool {
        isLatched && (keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter)
    }

    /// Returns true when this flagsChanged event should be swallowed (not passed to macOS).
    /// `chordEngaging`: this event completes the action chord (see `chord`).
    @discardableResult
    private func handleFlags(_ event: CGEvent, chordEngaging: Bool = false) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isDown: Bool
        switch _trigger {
        case .fn:
            guard keyCode == kVK_Function else {
                // Control joined a held fn: the hold is the chord's now. A push-to-talk
                // dictation started on that fn is dropped so the action can begin.
                if chordEngaging, triggerDown, !chordHoldsTrigger {
                    chordHoldsTrigger = true
                    emit(.chordTaken)
                } else if triggerDown, !chordHoldsTrigger {
                    triggerInterrupted = true
                }
                return false
            }
            isDown = flags.contains(.maskSecondaryFn)
        case .rightOption:
            guard keyCode == kVK_RightOption else { return false }
            isDown = flags.contains(.maskAlternate)
        case .rightCommand:
            guard keyCode == kVK_RightCommand else { return false }
            isDown = flags.contains(.maskCommand)
        case .controlOption:
            let both = flags.contains(.maskControl) && flags.contains(.maskAlternate)
            guard [kVK_Control, kVK_Option, kVK_RightControl, kVK_RightOption].contains(keyCode) else { return false }
            isDown = both
        }
        guard isDown != triggerDown else { return false }
        triggerDown = isDown
        log.debug("trigger \(isDown ? "down" : "up", privacy: .public)")

        let now = deferringTapEffects ? recordedAt : now()
        if !(isDown && chordEngaging), !chordHoldsTrigger { reportEdge(isDown, at: now) }
        if isDown, chordEngaging {
            // fn completed the chord (control was already down): the action's, not dictation's.
            // Not a tap either, so it can't be half of a double-tap latch.
            chordHoldsTrigger = true
            lastTriggerDown = .distantPast
        } else if isDown {
            let otherModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            let triggerModifiers: CGEventFlags = switch _trigger {
            case .fn: []
            case .rightOption: .maskAlternate
            case .rightCommand: .maskCommand
            case .controlOption: [.maskControl, .maskAlternate]
            }
            triggerInterrupted = !flags.intersection(otherModifiers.subtracting(triggerModifiers)).isEmpty
            if _isLatched, now.timeIntervalSince(tapLatchedAt) < Self.doubleTapWindow {
                // Second click of a double-click: swallow this press and its release.
                stoppingLatchedPress = true
                tapLatchedAt = .distantPast
            } else if _isLatched {
                stoppingLatchedPress = true
                emit(.stopLatched)
            } else {
                emit(.pressed)
            }
            lastTriggerDown = now
        } else if chordHoldsTrigger {
            chordHoldsTrigger = false
        } else if stoppingLatchedPress {
            stoppingLatchedPress = false
        } else {
            if !_isLatched {
                if !triggerInterrupted, now.timeIntervalSince(lastTriggerDown) < DictationController.minimumHold {
                    tapLatchedAt = now
                    emit(.latched)
                } else {
                    emit(.released)
                }
            }
        }

        // Only fn has a system-level solo action to hide (Globe key action + Dictation
        // double-press); the other triggers have no equivalent macOS behavior to suppress, so
        // they're always passed through unchanged.
        guard _trigger == .fn else { return false }
        let action = isDown ? fnCapture.fnDown() : fnCapture.fnUp()
        switch action {
        case .swallow: return true
        case .pass, .passRelease: return false
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // ⌃⌘V pastes the last transcript and ⌃⌘C copies it, from anywhere.
        if let shortcut = Self.globalShortcut(keyCode: keyCode, flags: flags) {
            emit(shortcut)
            return true
        }
        if _restyleShortcut.matches(keyCode: keyCode, flags: flags,
                                   isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
            emit(.restyleSelection)
            return true
        }

        guard _isDictationActive else { return false }
        if keyCode == kVK_Escape {
            emit(.cancel)
            return true
        }
        // Hands-free: Return finishes instead of reaching the app (which could send a half-
        // written message). ⌘Return does the same — paste only — and is swallowed too, so it can't
        // send there either. Swallowed only while latched.
        if Self.finishesLatched(keyCode: keyCode, flags: flags, isLatched: _isLatched) {
            emit(.finishLatched)
            return true
        }
        if triggerDown, !_isLatched {
            if keyCode == kVK_Space {
                emit(.latched)
                return true
            }
            // fn+arrow, fn+F-key, ⌥+letter…: the user meant a shortcut, not dictation.
            triggerInterrupted = true
            emit(.interrupted)
        }
        return false
    }

    /// When fn is being swallowed and another key is about to be delivered, macOS/the frontmost
    /// app never saw fn go down — so a real fn combo (fn+Left, fn+F2, fn+Delete, fn+E…) would
    /// silently degrade to just the plain key. Post a synthetic fn-down `flagsChanged` first so
    /// the combo reaches the app exactly as if Hushy had never swallowed the original fn-down.
    /// The real fn-up (once the user releases fn) is then let through for real to balance it —
    /// see `FnCaptureDecider.Action.passRelease`.
    private func repostFnDownIfNeeded(before event: CGEvent) {
        guard _trigger == .fn, triggerDown, fnCapture.otherKeyPressed() else { return }
        guard let source = CGEventSource(event: event),
              let synthetic = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Function), keyDown: true)
        else { return }
        synthetic.type = .flagsChanged
        synthetic.flags = .maskSecondaryFn
        synthetic.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Function))
        _postSynthetic(synthetic)
    }

    private func reportEdge(_ isDown: Bool, at time: Date) {
        guard deferringTapEffects else { onTriggerEdge?(isDown, time); return }
        pendingEdges.append(.edge(isDown: isDown, at: time))
    }

    private func emit(_ event: HotkeyEvent) {
        guard deferringTapEffects else {
            if let onTimedEvent { onTimedEvent(event, now()) }
            else { onEvent?(event) }
            return
        }
        // The controller sets these when it gets the event; the tap needs them for the very next key.
        switch event {
        case .pressed: _isDictationActive = true
        case .latched: _isDictationActive = true; _isLatched = true
        case .stopLatched, .finishLatched, .cancel, .chordTaken: _isLatched = false
        default: break
        }
        pendingEvents.append(.event(event, at: recordedAt))
    }

    /// The tap path without the tap: `event` is judged as happening at `time`, and nothing it meant
    /// reaches a handler until `deliverPendingEvents` runs on the main actor (scheduled here).
    @discardableResult
    func handleRecorded(type: CGEventType, event: CGEvent, at time: Date,
                        reading: EventClock.Reading = .now(), pillScope: PillKeyScope? = nil) -> Bool {
        let (consumed, schedule) = locked { () -> (Bool, Bool) in
            recordedAt = time
            self.reading = reading
            presetPillScope = pillScope
            deferringTapEffects = true
            _chord?.deferEvents = true
            let consumed = classify(type: type, event: event)
            deferringTapEffects = false
            _chord?.deferEvents = false
            presetPillScope = nil
            let actions = (_chord?.takePendingEvents() ?? []).map(TapOutput.action)
            outbox += pendingSignals + pendingEdges + pendingEvents + actions
            pendingSignals.removeAll()
            pendingEdges.removeAll()
            pendingEvents.removeAll()
            guard !outbox.isEmpty, !drainScheduled else { return (consumed, false) }
            drainScheduled = true
            return (consumed, true)
        }
        if schedule {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.deliverPendingEvents() } }
        }
        return consumed
    }

    /// Hands everything recorded so far to the handlers, oldest first, with `lock` released so the
    /// tap thread never waits on a handler.
    @MainActor
    func deliverPendingEvents() {
        let (outputs, chord) = locked { () -> ([TapOutput], ActionHotkeyMonitor?) in
            defer { outbox.removeAll(); drainScheduled = false }
            return (outbox, _chord)
        }
        for output in outputs {
            switch output {
            case .pillKey(let key): onPillKey?(key)
            case .returnKey: onReturnKey?()
            case .edge(let isDown, let time): onTriggerEdge?(isDown, time)
            case .event(let event, let time):
                if let onTimedEvent { onTimedEvent(event, time) }
                else { onEvent?(event) }
            case .action(let event): chord?.deliver(event)
            }
        }
    }
}

/// The main actor's answer about the pill, handed to the tap thread waiting for it.
private final class PillScopeAnswer: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var scope: PillKeyScope = .none

    func set(_ scope: PillKeyScope) {
        self.scope = scope
        done.signal()
    }

    /// The answer, or nil when it did not come within `limit`.
    func wait(_ limit: DispatchTimeInterval) -> PillKeyScope? {
        done.wait(timeout: .now() + limit) == .success ? scope : nil
    }
}
