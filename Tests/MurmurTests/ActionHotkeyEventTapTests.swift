import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import Murmur

/// Feeds the same `HotkeyMonitor.handle` method the installed Quartz callback calls. No tap,
/// Accessibility permission or founder app is needed, but the real ordering and pill-key route
/// run instead of testing the pure key router in isolation.
@Suite("Voice-action chord through the live event-tap handler")
@MainActor
struct ActionHotkeyEventTapTests {
    private func flags(_ key: Int, _ value: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)!
        event.type = .flagsChanged
        event.flags = value
        return event
    }

    private func key(_ code: Int, _ value: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.flags = value
        return event
    }

    @Test("control then fn starts an action without starting dictation")
    func controlFirst() {
        let monitor = HotkeyMonitor()
        let chord = ActionHotkeyMonitor()
        monitor.chord = chord
        var dictation: [HotkeyEvent] = []
        var actions: [ActionHotkeyEvent] = []
        monitor.onEvent = { dictation.append($0) }
        chord.onEvent = { actions.append($0) }
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Control, .maskControl))
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Function, [.maskControl, .maskSecondaryFn]))
        #expect(dictation.isEmpty)
        #expect(actions == [.pressed])
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Function, .maskControl))
        #expect(dictation.isEmpty)
        #expect(actions == [.pressed, .released])
    }

    @Test("fn then control transfers the hold from dictation to action")
    func fnFirst() {
        let monitor = HotkeyMonitor()
        let chord = ActionHotkeyMonitor()
        monitor.chord = chord
        var dictation: [HotkeyEvent] = []
        var actions: [ActionHotkeyEvent] = []
        monitor.onEvent = { dictation.append($0) }
        chord.onEvent = { actions.append($0) }
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Function, .maskSecondaryFn))
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Control, [.maskSecondaryFn, .maskControl]))
        #expect(dictation == [.pressed, .chordTaken])
        #expect(actions == [.pressed])
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Control, .maskSecondaryFn))
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Function, []))
        #expect(dictation == [.pressed, .chordTaken], "no stray release may paste dictation")
        #expect(actions == [.pressed, .released])
    }

    @Test("Return and Escape are swallowed by the tap while an action is listening")
    func livePillKeys() {
        let monitor = HotkeyMonitor()
        let pill = PillModel()
        pill.state = .actionListening
        monitor.pillKeyScope = { pill.keyScope(now: Date(), ownTextFieldFocused: false) }
        var answers: [PillKey] = []
        monitor.onPillKey = { answers.append($0) }
        var reposts = 0
        monitor.postSynthetic = { _ in reposts += 1 }
        #expect(monitor.handle(type: .keyDown, event: key(kVK_Return, [.maskSecondaryFn, .maskControl])))
        #expect(monitor.handle(type: .keyDown, event: key(kVK_Escape, [.maskSecondaryFn, .maskControl])))
        #expect(answers == [.confirm, .dismiss])
        #expect(reposts == 0)
    }
}
