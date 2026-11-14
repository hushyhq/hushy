import CoreGraphics
import Foundation
import MurmurCore
import os

/// Events the action pipeline reacts to. Deliberately separate from `HotkeyEvent`
/// (`HotkeyMonitor`) — the product-owner decision is "hold fn+control together = Action mode for
/// one utterance; plain fn stays dictation", i.e. two independent chords with different
/// consequences (paste text vs. call EventKit/Shortcuts), not two states of one chord.
enum ActionHotkeyEvent: Equatable {
    case pressed
    case released
    /// The chosen key was double-tapped, bare: listen hands-free, no key held.
    case doubleTapped
    /// One bare tap of the chosen key while a hands-free action is listening: cancel it.
    case tapCancelled
}

/// The fn+control chord. Fed every `flagsChanged` by `HotkeyMonitor`'s one event tap
/// (`HotkeyMonitor.chord`), which sees the keys before it decides anything about dictation, so
/// the chord wins over dictation in either key order (QA 2026-09-28, P0 item 6).
///
/// It used to own a second, listen-only `CGEvent` tap of its own. That never worked in the real
/// app: with fn as the dictation key, `HotkeyMonitor` swallows the fn `flagsChanged` before any
/// later tap sees it (`FnCaptureDecider`), and when the fn-down did get through, dictation had
/// already started on it and `VoiceActionsController.begin` refused to run while dictation was
/// busy. One tap, one ordering.
///
/// The tap's thread drives it (`HotkeyMonitor`), while Settings and `VoiceActionsController` set it up
/// from the main actor, so its state is read and written under `lock`. `onEvent` is the main
/// actor's: the tap path queues events (`deferEvents`) and `HotkeyMonitor` delivers them there.
final class ActionHotkeyMonitor: @unchecked Sendable {
    /// The chord as readable key caps, for every hint that names it (Settings, the sidebar, the
    /// pill, Home, onboarding). "control" in words, never the ⌃ glyph alone: the founder read ⌃
    /// as an up arrow. Always fn+control, whatever the dictation key is set to.
    static let chordKeys = ["fn", "control"]
    /// The chord in a sentence: "fn + control".
    static let chordText = chordKeys.joined(separator: " + ")

    /// Recursive because a handler called on the main-thread path may read `trigger`.
    private let lock = NSRecursiveLock()
    var onEvent: ((ActionHotkeyEvent) -> Void)?
    var deferEvents: Bool {
        get { locked { _deferEvents } }
        set { locked { _deferEvents = newValue } }
    }
    private var _deferEvents = false
    private var pendingEvents: [ActionHotkeyEvent] = []

    /// The key pressed twice to start an action (`ActionTriggerKey`). Set by `HotkeyMonitor` from
    /// Settings, with the dictation key already taken into account. A change made while a
    /// hands-free action is listening waits: the session keeps the key its pill named (see
    /// `sessionTrigger`).
    var trigger: ActionTriggerKey {
        get { locked { _trigger } }
        set { locked { _trigger = newValue } }
    }
    private var _trigger = ActionTriggerKey.default
    /// The key the tap is judged on right now. It follows `trigger` whenever nothing is listening
    /// hands-free, and stays put while something is, so the key the pill names is the key that
    /// cancels.
    private var sessionTrigger = ActionTriggerKey.default
    /// Whether a hands-free action is listening right now. The tap cancelling it never touches the
    /// key: a bare modifier tap does nothing in the front app, so every trigger event passes. Asked
    /// on the tap's thread, so the answer must be safe to read from any thread.
    var isHandsFreeListening: () -> Bool {
        get { locked { _isHandsFreeListening } }
        set { locked { _isHandsFreeListening = newValue } }
    }
    private var _isHandsFreeListening: () -> Bool = { false }

    var isDown: Bool { locked { _isDown } }
    private var _isDown = false
    private var tap = TapRecogniser()
    /// The physical trigger keys (left and right of a pair) currently down, by key code. The flags
    /// only say that *a* Control is down; the codes say which, so left-down, right-down, left-up,
    /// right-up cannot pass as one clean tap.
    private var triggerKeysDown = Set<Int>()
    private let log = Logger(subsystem: "app.hushy", category: "action-hotkey")

    /// Whether `flags` hold the chord: fn and control together, whichever Control key.
    static func chordHeld(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskSecondaryFn) && flags.contains(.maskControl)
    }

    /// Whether this `flagsChanged` is the one that engages the chord (both keys now down, and
    /// they weren't before). Pure; `observe` is what moves the state.
    func engages(_ flags: CGEventFlags) -> Bool {
        locked { !_isDown && Self.chordHeld(flags) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Every `flagsChanged`'s flags, in order. Emits `.pressed` when both keys are down and
    /// `.released` when either goes up.
    func observe(_ flags: CGEventFlags) {
        locked {
            let down = Self.chordHeld(flags)
            guard down != _isDown else { return }
            _isDown = down
            log.debug("chord \(down ? "down" : "up", privacy: .public)")
            emit(down ? .pressed : .released)
        }
    }

    /// Every `flagsChanged` again, for the double tap: the key code says which modifier changed,
    /// the flags what is down, `timestamp` (seconds) when. Nothing is ever swallowed here. Only the
    /// trigger key's own state and the *fact* that another modifier changed are looked at.
    func observeTap(keyCode: Int, flags: CGEventFlags, timestamp: TimeInterval) {
        locked { observeTapLocked(keyCode: keyCode, flags: flags, timestamp: timestamp) }
    }

    private func observeTapLocked(keyCode: Int, flags: CGEventFlags, timestamp: TimeInterval) {
        let listening = _isHandsFreeListening()
        if !listening { sessionTrigger = _trigger }
        guard sessionTrigger.keyCodes.contains(keyCode) else {
            if !flags.contains(sessionTrigger.flag) { triggerKeysDown.removeAll() }
            _ = tap.feed(.otherModifier, isListening: false)
            return
        }
        guard flags.contains(sessionTrigger.flag) || triggerKeysDown.contains(keyCode) else { return }
        if flags.contains(sessionTrigger.flag), triggerKeysDown == [keyCode] {
            // A down for the one key already recorded as down: its release was lost. Whatever was
            // half-finished is stale; start over with this event as a fresh press.
            tap.reset()
            triggerKeysDown.removeAll()
        }
        let wasDown = !triggerKeysDown.isEmpty
        if triggerKeysDown.contains(keyCode) {
            triggerKeysDown.remove(keyCode)
        } else {
            triggerKeysDown.insert(keyCode)
        }
        if !flags.contains(sessionTrigger.flag) { triggerKeysDown.removeAll() }
        if triggerKeysDown.count > 1 {
            // The other side of the pair joined: that is two keys, not a tap.
            _ = tap.feed(.otherModifier, isListening: false)
            return
        }
        let down = !triggerKeysDown.isEmpty
        // A release while the other side is still down (or after it joined) is not a tap's end.
        guard down != wasDown else { return }
        let others = sessionTrigger.othersDown(in: flags)
        switch tap.feed(.trigger(isDown: down, othersDown: others, at: timestamp), isListening: listening) {
        case .doubleTap: emit(.doubleTapped)
        case .cancelTap: emit(.tapCancelled)
        case .none: break
        }
    }

    /// A mouse button went down (from the event tap) or the wheel moved (from the `NSEvent`
    /// monitors): only that fact, never where or on what. It
    /// voids a tap in progress, so two Control-clicks or a Control-scroll zoom are not a double tap.
    func observeMouse() {
        locked { _ = tap.feed(.otherKey, isListening: false) }
    }

    /// Any non-modifier key-down breaks a tap in progress (Ctrl+C is not a double tap).
    func observeKeyDown() {
        locked { _ = tap.feed(.otherKey, isListening: false) }
    }

    /// The tap was disabled and re-armed (events may have been lost): forget a held chord so a
    /// missed key-up can't leave an action listening forever, and any half-finished tap.
    func reset() {
        locked {
            tap.reset()
            triggerKeysDown.removeAll()
            guard _isDown else { return }
            _isDown = false
            emit(.released)
        }
    }

    private func emit(_ event: ActionHotkeyEvent) {
        if _deferEvents { pendingEvents.append(event) }
        else { onEvent?(event) }
    }

    /// The events queued while `deferEvents` was set, oldest first, for `HotkeyMonitor` to deliver.
    func takePendingEvents() -> [ActionHotkeyEvent] {
        locked {
            defer { pendingEvents.removeAll() }
            return pendingEvents
        }
    }

    /// One queued event, handed to `onEvent` on the main actor.
    @MainActor
    func deliver(_ event: ActionHotkeyEvent) {
        onEvent?(event)
    }
}
