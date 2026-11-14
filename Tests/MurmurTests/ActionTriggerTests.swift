import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The double-tap trigger through the live event-tap handler, with synthetic events and no real
/// tap, microphone or app. Timestamps are set on the events, so nothing here sleeps.
@Suite("Voice actions: press a key twice")
@MainActor
struct ActionTriggerTests {
    private func flags(_ key: Int, _ value: CGEventFlags, at seconds: Double) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)!
        event.type = .flagsChanged
        event.flags = value
        event.timestamp = CGEventTimestamp(seconds * 1_000_000_000)
        return event
    }

    private func key(_ code: Int, _ value: CGEventFlags = [], at seconds: Double = 0) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.flags = value
        event.timestamp = CGEventTimestamp(seconds * 1_000_000_000)
        return event
    }

    @MainActor
    private struct Rig {
        final class Box { var events: [ActionHotkeyEvent] = []; var listening = false }

        let monitor = HotkeyMonitor()
        let chord = ActionHotkeyMonitor()
        let actions = Box()

        init() {
            monitor.chord = chord
            let box = actions
            chord.onEvent = { box.events.append($0) }
            chord.isHandsFreeListening = { box.listening }
        }
    }

    private func feed(_ rig: Rig, _ event: CGEvent, type: CGEventType = .flagsChanged) -> Bool {
        rig.monitor.handle(type: type, event: event)
    }

    private func tap(_ rig: Rig, _ code: Int, _ on: CGEventFlags, from start: Double, held: Double = 0.1) -> [Bool] {
        [feed(rig, flags(code, on, at: start)), feed(rig, flags(code, [], at: start + held))]
    }

    @Test("Control twice, bare, starts a hands-free action and swallows nothing")
    func controlTwice() {
        let rig = Rig()
        let swallowed = tap(rig, kVK_Control, .maskControl, from: 10) + tap(rig, kVK_Control, .maskControl, from: 10.3)
        #expect(rig.actions.events == [.doubleTapped])
        #expect(swallowed.allSatisfy { !$0 }, "before listening, nothing is swallowed")
    }

    @Test("the right Control key counts as Control")
    func rightControl() {
        let rig = Rig()
        _ = tap(rig, kVK_RightControl, .maskControl, from: 5) + tap(rig, kVK_RightControl, .maskControl, from: 5.3)
        #expect(rig.actions.events == [.doubleTapped])
    }

    @Test("Ctrl+C, Ctrl+A twice and a held Control never trigger")
    func guards() {
        let rig = Rig()
        // Ctrl+C: a key between the press and release.
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 1))
        _ = feed(rig, key(kVK_ANSI_C, .maskControl, at: 1.05), type: .keyDown)
        _ = feed(rig, flags(kVK_Control, [], at: 1.1))
        // Ctrl+A twice.
        for start in [2.0, 2.3] {
            _ = feed(rig, flags(kVK_Control, .maskControl, at: start))
            _ = feed(rig, key(kVK_ANSI_A, .maskControl, at: start + 0.05), type: .keyDown)
            _ = feed(rig, flags(kVK_Control, [], at: start + 0.1))
        }
        // A held Control, twice.
        _ = tap(rig, kVK_Control, .maskControl, from: 4, held: 1) + tap(rig, kVK_Control, .maskControl, from: 5.5, held: 1)
        // A three-key chord: Control, Shift, a letter.
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 8))
        _ = feed(rig, flags(kVK_Shift, [.maskControl, .maskShift], at: 8.02))
        _ = feed(rig, key(kVK_ANSI_K, [.maskControl, .maskShift], at: 8.05), type: .keyDown)
        _ = feed(rig, flags(kVK_Shift, .maskControl, at: 8.1))
        _ = feed(rig, flags(kVK_Control, [], at: 8.12))
        #expect(rig.actions.events.isEmpty)
    }

    @Test("Control tapped with Shift, Option or Command held is a shortcut, not a trigger")
    func otherModifierHeld() {
        let rig = Rig()
        for other in [CGEventFlags.maskShift, .maskAlternate, .maskCommand] {
            _ = feed(rig, flags(kVK_Control, [.maskControl, other], at: 1))
            _ = feed(rig, flags(kVK_Control, other, at: 1.1))
            _ = feed(rig, flags(kVK_Control, [.maskControl, other], at: 1.2))
            _ = feed(rig, flags(kVK_Control, other, at: 1.3))
        }
        #expect(rig.actions.events.isEmpty)
    }

    @Test("holding fn + control still works exactly as before and never reads as a double tap")
    func chordStillWorks() {
        let rig = Rig()
        for start in [1.0, 1.3] {
            _ = feed(rig, flags(kVK_Function, .maskSecondaryFn, at: start))
            _ = feed(rig, flags(kVK_Control, [.maskSecondaryFn, .maskControl], at: start + 0.02))
            _ = feed(rig, flags(kVK_Control, .maskSecondaryFn, at: start + 0.1))
            _ = feed(rig, flags(kVK_Function, [], at: start + 0.12))
        }
        #expect(rig.actions.events == [.pressed, .released, .pressed, .released])
    }

    @Test("while a hands-free action listens, one bare tap cancels it and the key itself is never swallowed")
    func cancelTapPassesThrough() {
        let rig = Rig()
        rig.actions.listening = true
        let swallowed = tap(rig, kVK_Control, .maskControl, from: 20)
        #expect(swallowed == [false, false], "a bare modifier tap does nothing in the front app, so it passes")
        #expect(rig.actions.events == [.tapCancelled])
    }

    @Test("a Control held past the tap time while listening passes both ways and cancels nothing")
    func heldControlWhileListening() {
        let rig = Rig()
        rig.actions.listening = true
        #expect(tap(rig, kVK_Control, .maskControl, from: 20, held: 1) == [false, false])
        #expect(rig.actions.events.isEmpty)
    }

    @Test("listening that ends before the key comes up leaves that release untouched")
    func releaseAfterListeningEnds() {
        let rig = Rig()
        rig.actions.listening = true
        #expect(feed(rig, flags(kVK_Control, .maskControl, at: 20)) == false)
        rig.actions.listening = false // Esc or the time-out ended it
        #expect(feed(rig, flags(kVK_Control, [], at: 20.1)) == false)
    }

    @Test("Caps Lock being on does not stop the double tap")
    func capsLockOn() {
        let rig = Rig()
        let caps = CGEventFlags.maskAlphaShift
        _ = tap(rig, kVK_Control, [.maskControl, caps], from: 10) + tap(rig, kVK_Control, [.maskControl, caps], from: 10.3)
        #expect(rig.actions.events == [.doubleTapped])
    }

    @Test("left and right of the same modifier overlapping is not a tap")
    func overlappingPair() {
        let rig = Rig()
        func overlap(from start: Double) {
            _ = feed(rig, flags(kVK_Control, .maskControl, at: start))
            _ = feed(rig, flags(kVK_RightControl, .maskControl, at: start + 0.02))
            _ = feed(rig, flags(kVK_Control, .maskControl, at: start + 0.05)) // left up, right still down
            _ = feed(rig, flags(kVK_RightControl, [], at: start + 0.08))
        }
        overlap(from: 1)
        overlap(from: 1.2)
        #expect(rig.actions.events.isEmpty, "an overlapping pair twice")
        // One real tap followed by an overlapping pair is not a double tap either.
        _ = tap(rig, kVK_Control, .maskControl, from: 5)
        overlap(from: 5.2)
        #expect(rig.actions.events.isEmpty)
        // While listening an overlapping pair does not cancel.
        rig.actions.listening = true
        overlap(from: 9)
        #expect(rig.actions.events.isEmpty)
        // And the keys still work as a clean single tap afterwards.
        _ = tap(rig, kVK_RightControl, .maskControl, from: 12)
        #expect(rig.actions.events == [.tapCancelled])
    }

    @Test("changing the action key mid-session keeps the session's key until listening ends")
    func sessionKeyIsKept() {
        let rig = Rig()
        rig.actions.listening = true
        rig.monitor.actionTrigger = .option // changed in Settings while listening
        _ = tap(rig, kVK_Option, .maskAlternate, from: 20)
        #expect(rig.actions.events.isEmpty, "the new key does not cancel the old session")
        _ = tap(rig, kVK_Control, .maskControl, from: 21)
        #expect(rig.actions.events == [.tapCancelled], "the key the pill named still does")
        rig.actions.listening = false
        _ = tap(rig, kVK_Option, .maskAlternate, from: 30) + tap(rig, kVK_Option, .maskAlternate, from: 30.3)
        #expect(rig.actions.events == [.tapCancelled, .doubleTapped], "the new choice applies once listening has ended")
    }

    @Test("a lost key-up cannot leave a half-finished tap behind")
    func lostKeyUp() {
        let rig = Rig()
        // The first press is real but its release is lost; the next Control-down arrives while that
        // same key is still recorded as down, so it starts over as a fresh press. That press is
        // held 0.35 s: a held Control, not a tap.
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 1.0))
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 1.15))
        _ = feed(rig, flags(kVK_Control, [], at: 1.5))
        // Before the fix the lost press and the 1.15 "release" read as one clean tap, and this tap
        // fired a double tap on top of it.
        _ = tap(rig, kVK_Control, .maskControl, from: 1.52, held: 0.1)
        #expect(rig.actions.events.isEmpty, "the leftovers of the lost press never pair with a real tap")
        // The state is whole again afterwards: a real double tap still works.
        _ = tap(rig, kVK_Control, .maskControl, from: 5) + tap(rig, kVK_Control, .maskControl, from: 5.3)
        #expect(rig.actions.events == [.doubleTapped])
    }

    @Test("after a lost key-up the next two real taps are a double tap, counted from the fresh press")
    func lostKeyUpThenTwoTaps() {
        let rig = Rig()
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 1.0)) // its release is lost
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 1.2)) // fresh press
        _ = feed(rig, flags(kVK_Control, [], at: 1.3))           // tap one (1.2 to 1.3)
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 1.5))
        _ = feed(rig, flags(kVK_Control, [], at: 1.6))           // tap two
        // Two clean taps were really made, 0.2 s apart; the lost press at 1.0 is not one of them.
        #expect(rig.actions.events == [.doubleTapped])
    }

    @Test("the other side of the pair still down is not an inconsistency")
    func pairStillDown() {
        let rig = Rig()
        rig.actions.listening = true
        // Right down, left down and up (right still down), right up: two keys, no tap, no cancel...
        _ = feed(rig, flags(kVK_RightControl, .maskControl, at: 1))
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 1.05))
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 1.1))
        _ = feed(rig, flags(kVK_RightControl, [], at: 1.15))
        #expect(rig.actions.events.isEmpty)
        // ...and the keys work as a clean tap afterwards.
        _ = tap(rig, kVK_RightControl, .maskControl, from: 3)
        #expect(rig.actions.events == [.tapCancelled])
    }

    @Test("two quick Control-clicks through the event tap's own mouse events are not a double tap")
    func mouseThroughTapCallback() {
        let rig = Rig()
        for start in [1.0, 1.25] {
            _ = feed(rig, flags(kVK_Control, .maskControl, at: start))
            let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
            #expect(feed(rig, click, type: .leftMouseDown) == false, "a click passes through untouched")
            _ = feed(rig, flags(kVK_Control, [], at: start + 0.1))
        }
        #expect(rig.actions.events.isEmpty)
        // Right and other buttons too.
        for (type, button) in [(CGEventType.rightMouseDown, CGMouseButton.right), (.otherMouseDown, .center)] {
            _ = feed(rig, flags(kVK_Control, .maskControl, at: 5))
            let click = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button)!
            #expect(feed(rig, click, type: type) == false)
            _ = feed(rig, flags(kVK_Control, [], at: 5.1))
            _ = tap(rig, kVK_Control, .maskControl, from: 5.3)
            #expect(rig.actions.events.isEmpty)
        }
    }

    @Test("the event tap asks for the three mouse-down types and nothing that streams")
    func tapMask() {
        let mask = HotkeyMonitor.tapEventMask
        for type in [CGEventType.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            #expect(mask & (1 << type.rawValue) != 0, "\(type)")
        }
        for type in [CGEventType.scrollWheel, .mouseMoved, .leftMouseDragged, .keyUp] {
            #expect(mask & (1 << type.rawValue) == 0, "\(type)")
        }
    }

    @Test("a mouse button or the scroll wheel while the key is down voids the tap")
    func mouseVoidsTap() {
        let rig = Rig()
        // Two quick Control-clicks.
        for start in [1.0, 1.25] {
            _ = feed(rig, flags(kVK_Control, .maskControl, at: start))
            rig.chord.observeMouse()
            _ = feed(rig, flags(kVK_Control, [], at: start + 0.1))
        }
        #expect(rig.actions.events.isEmpty)
        // A Control-scroll between two otherwise clean taps.
        _ = tap(rig, kVK_Control, .maskControl, from: 5)
        rig.chord.observeMouse()
        _ = tap(rig, kVK_Control, .maskControl, from: 5.25)
        #expect(rig.actions.events.isEmpty)
        // While listening, a Control-click does not cancel.
        rig.actions.listening = true
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 9))
        rig.chord.observeMouse()
        _ = feed(rig, flags(kVK_Control, [], at: 9.1))
        #expect(rig.actions.events.isEmpty)
    }

    @Test("while listening, Control used as a modifier is not swallowed and does not cancel")
    func listeningShortcutPasses() {
        let rig = Rig()
        rig.actions.listening = true
        #expect(feed(rig, flags(kVK_Control, [.maskControl, .maskShift], at: 3)) == false)
        #expect(feed(rig, flags(kVK_Control, .maskShift, at: 3.1)) == false)
        #expect(rig.actions.events.isEmpty)
    }

    @Test("when nothing is listening a lone Control tap, Return and Escape all pass through untouched")
    func idlePassThrough() {
        let rig = Rig()
        rig.monitor.pillKeyScope = { .none }
        var answers: [PillKey] = []
        rig.monitor.onPillKey = { answers.append($0) }
        #expect(tap(rig, kVK_Control, .maskControl, from: 1) == [false, false])
        #expect(feed(rig, key(kVK_Return), type: .keyDown) == false)
        #expect(feed(rig, key(kVK_Escape), type: .keyDown) == false)
        #expect(answers.isEmpty)
        #expect(rig.actions.events.isEmpty)
    }

    @Test("the chosen key decides: Option twice triggers, Control twice then does not")
    func chosenKey() {
        let rig = Rig()
        rig.monitor.actionTrigger = .option
        _ = tap(rig, kVK_Control, .maskControl, from: 1) + tap(rig, kVK_Control, .maskControl, from: 1.3)
        #expect(rig.actions.events.isEmpty)
        _ = tap(rig, kVK_Option, .maskAlternate, from: 5) + tap(rig, kVK_RightOption, .maskAlternate, from: 5.3)
        #expect(rig.actions.events == [.doubleTapped])
    }

    @Test("right Command twice triggers; left Command held makes it a shortcut")
    func rightCommand() {
        let rig = Rig()
        rig.monitor.actionTrigger = .rightCommand
        _ = tap(rig, kVK_RightCommand, .maskCommand, from: 1) + tap(rig, kVK_RightCommand, .maskCommand, from: 1.3)
        #expect(rig.actions.events == [.doubleTapped])
        let leftHeld = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        _ = feed(rig, flags(kVK_RightCommand, leftHeld, at: 9))
        _ = feed(rig, flags(kVK_RightCommand, CGEventFlags(rawValue: 0x08), at: 9.1))
        _ = feed(rig, flags(kVK_RightCommand, leftHeld, at: 9.2))
        _ = feed(rig, flags(kVK_RightCommand, CGEventFlags(rawValue: 0x08), at: 9.3))
        #expect(rig.actions.events == [.doubleTapped])
    }

    @Test("the tap being disabled and re-armed forgets a half-finished tap")
    func tapReset() {
        let rig = Rig()
        _ = feed(rig, flags(kVK_Control, .maskControl, at: 1))
        _ = rig.monitor.handle(type: .tapDisabledByTimeout, event: flags(kVK_Control, [], at: 1.05))
        _ = feed(rig, flags(kVK_Control, [], at: 1.1))
        _ = tap(rig, kVK_Control, .maskControl, from: 1.2)
        #expect(rig.actions.events.isEmpty)
    }

    // MARK: Which keys are offered

    @Test("Control is the default, fn and letters are never offered")
    func choices() {
        #expect(ActionTriggerKey.default == .control)
        #expect(Set(ActionTriggerKey.allCases.map(\.rawValue)) == ["control", "option", "rightCommand"])
    }

    @Test("a choice that is also the dictation key falls back to Control, and the picker leaves it out")
    func dictationKeyConflict() {
        #expect(ActionTriggerKey.effective(.option, dictation: .rightOption) == .control)
        #expect(ActionTriggerKey.effective(.rightCommand, dictation: .rightCommand) == .control)
        #expect(ActionTriggerKey.effective(.option, dictation: .fn) == .option)
        #expect(ActionTriggerKey.effective(.control, dictation: .controlOption) == .control)
        #expect(ActionTriggerKey.choices(dictation: .rightOption) == [.control, .rightCommand])
        #expect(ActionTriggerKey.choices(dictation: .fn) == ActionTriggerKey.allCases)
    }

    @Test("macOS Dictation's double press clashes only with the same key")
    func dictationClash() {
        let fn = CGEventFlags.maskSecondaryFn
        #expect(!Permissions.macDictationClashes(shortcut: fn, with: .control))
        #expect(Permissions.macDictationClashes(shortcut: .maskControl, with: .control))
        #expect(Permissions.macDictationClashes(shortcut: .maskAlternate, with: .option))
        #expect(!Permissions.macDictationClashes(shortcut: .maskAlternate, with: .control))
        #expect(!Permissions.macDictationClashes(shortcut: nil, with: .control))
    }

    @Test("the setting defaults to Control, remembers a choice, and ignores a stored value it does not know")
    func settingPersists() {
        let name = "hushy-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppSettings(defaults: defaults).actionTrigger == .control)
        let settings = AppSettings(defaults: defaults)
        settings.actionTrigger = .option
        #expect(AppSettings(defaults: defaults).actionTrigger == .option)
        defaults.set("fn", forKey: "actionTriggerKey")
        #expect(AppSettings(defaults: defaults).actionTrigger == .control)
    }

    // MARK: The controller

    @Test("a hands-free listening ends on a tap, ignores the chord's release, and times out with a notice")
    func handsFreeSession() throws {
        let hotkeys = ActionHotkeyMonitor()
        let pill = PillModel()
        let integrity = SpeechModelIntegrity(
            fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: "hushy-test-\(UUID().uuidString)")
        let controller = VoiceActionsController(
            hotkeys: hotkeys, pill: pill, speech: SpeechEngine(status: SpeechModelStatus(), integrity: integrity),
            modelStatus: SpeechModelStatus(), store: try Store(), calendarBackend: FakeCalendarBackend(),
            shortcutsBackend: FakeShortcutsBackend())
        #expect(!hotkeys.isHandsFreeListening())

        controller.beginListeningForTests(handsFree: true)
        #expect(hotkeys.isHandsFreeListening())
        #expect(pill.actionCancelKey == "control")
        hotkeys.onEvent?(.released) // a chord release is not the end of a hands-free session
        #expect(controller.isHandsFreeListening)
        hotkeys.onEvent?(.tapCancelled)
        #expect(!controller.isHandsFreeListening)
        #expect(pill.state == .idle)

        controller.beginListeningForTests(handsFree: true)
        controller.timeOutListening()
        #expect(!controller.isHandsFreeListening)
        #expect(pill.state == .error("Stopped listening"))

        // The held chord is untouched: a tap does not cancel it, and its release does end it.
        controller.beginListeningForTests(handsFree: false)
        #expect(!hotkeys.isHandsFreeListening())
        #expect(pill.actionCancelKey == nil)
        hotkeys.onEvent?(.tapCancelled)
        #expect(pill.state == .actionListening)
        controller.timeOutListening()
        #expect(pill.state == .actionListening, "the time-out is for hands-free sessions only")
        hotkeys.onEvent?(.released)
        #expect(pill.state != .actionListening)
    }

    @Test("the hands-free limit is a named constant of 20 seconds")
    func limit() {
        #expect(VoiceActionsController.handsFreeListenLimit == .seconds(20))
    }
}
