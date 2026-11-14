import Carbon.HIToolbox
import CoreGraphics
import MurmurCore
import Testing
@testable import Murmur

@Suite("Dictation key tap state machine")
@MainActor
struct DictationTapTests {
    private func event(_ code: Int, _ flags: CGEventFlags, type: CGEventType = .flagsChanged) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.type = type
        event.flags = flags
        return event
    }

    @Test("a disabled tap releases a held key once and accepts the next hold",
          arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
    func disabledTapReleases(type: CGEventType) {
        let monitor = HotkeyMonitor()
        var events: [HotkeyEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
        monitor.handle(type: type, event: event(kVK_Function, []))
        monitor.handle(type: type, event: event(kVK_Function, []))
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
        #expect(events == [.pressed, .released])
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
        #expect(events == [.pressed, .released, .pressed])
    }

    @Test("a disable during a hands-free double tap stops, while an unheld latch stays")
    func disabledTapWhileLatched() {
        let monitor = HotkeyMonitor()
        var now = Date(timeIntervalSince1970: 100)
        var events: [HotkeyEvent] = []
        monitor.now = { now }
        monitor.onEvent = {
            events.append($0)
            if $0 == .latched { monitor.isLatched = true }
            if $0 == .stopLatched { monitor.isLatched = false }
        }
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
        now.addTimeInterval(0.07)
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
        monitor.handle(type: .tapDisabledByTimeout, event: event(kVK_Function, []))
        #expect(events == [.pressed, .latched])
        now.addTimeInterval(0.08)
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
        monitor.handle(type: .tapDisabledByUserInput, event: event(kVK_Function, []))
        #expect(events == [.pressed, .latched, .stopLatched])
    }

    @Test("onboarding practice completes after double-tap and Enter, tap and tap, or hold")
    func onboardingCompletionGestures() {
        for gesture in ["double-enter", "tap-tap", "hold"] {
            let monitor = HotkeyMonitor()
            var now = Date(timeIntervalSince1970: 100)
            let started = now
            monitor.now = { now }
            var completions = 0
            monitor.onEvent = { event in
                if event == .latched { monitor.isLatched = true; monitor.isDictationActive = true }
                if event == .pressed { monitor.isDictationActive = true }
                if [.finishLatched, .stopLatched, .released].contains(event) {
                    monitor.isLatched = false
                    monitor.isDictationActive = false
                    completions += 1
                }
            }
            func tap(after gap: TimeInterval = 0.1) {
                now.addTimeInterval(gap)
                monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
                now.addTimeInterval(0.07)
                monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
            }
            switch gesture {
            case "double-enter":
                tap()
                tap(after: 0.08)
                monitor.handle(type: .keyDown, event: event(kVK_Return, [], type: .keyDown))
            case "tap-tap":
                tap()
                tap(after: 0.5)
            default:
                monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
                now.addTimeInterval(0.5)
                monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
            }
            #expect(completions == 1, "\(gesture)")
            let saved = Dictation(createdAt: now, rawText: "Hello", text: "Hello", durationSeconds: 1)
            #expect(OnboardingCopy.practiceCompleted(saved, since: started), "\(gesture)")
        }
    }

    @Test("a short tap latches; the next tap stops exactly once")
    func tapThenTap() {
        let monitor = HotkeyMonitor()
        var now = Date(timeIntervalSince1970: 100)
        monitor.now = { now }
        var events: [HotkeyEvent] = []
        monitor.onEvent = { event in
            events.append(event)
            if event == .latched { monitor.isLatched = true }
            if event == .stopLatched { monitor.isLatched = false }
        }
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
        now.addTimeInterval(0.1)
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
        #expect(events == [.pressed, .latched])
        now.addTimeInterval(1.0)
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
        now.addTimeInterval(0.1)
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
        #expect(events == [.pressed, .latched, .stopLatched])
    }

    @Test("a double-click stays in hands-free; the tap after it stops exactly once")
    func doubleClickLatches() {
        let monitor = HotkeyMonitor()
        var now = Date(timeIntervalSince1970: 100)
        monitor.now = { now }
        var events: [HotkeyEvent] = []
        monitor.onEvent = { event in
            events.append(event)
            if event == .latched { monitor.isLatched = true }
            if event == .stopLatched { monitor.isLatched = false }
        }
        func tap(after gap: TimeInterval) {
            now.addTimeInterval(gap)
            monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
            now.addTimeInterval(0.07)
            monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
        }
        tap(after: 0)
        tap(after: 0.08)   // the second click, about 150 ms after the first press
        #expect(events == [.pressed, .latched])
        // A third quick tap is a real stop: only one click is ever absorbed.
        tap(after: 0.1)
        #expect(events == [.pressed, .latched, .stopLatched])
    }

    @Test("a tap just outside the double-click window stops hands-free")
    func slowSecondTapStops() {
        let monitor = HotkeyMonitor()
        var now = Date(timeIntervalSince1970: 100)
        monitor.now = { now }
        var events: [HotkeyEvent] = []
        monitor.onEvent = { event in
            events.append(event)
            if event == .latched { monitor.isLatched = true }
            if event == .stopLatched { monitor.isLatched = false }
        }
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
        now.addTimeInterval(0.1)
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
        now.addTimeInterval(HotkeyMonitor.doubleTapWindow + 0.01)
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
        #expect(events == [.pressed, .latched, .stopLatched])
    }

    @Test("a hold, including a very long hold, releases without latching")
    func holds() {
        for duration in [0.5, 3600] as [TimeInterval] {
            let monitor = HotkeyMonitor()
            var now = Date(timeIntervalSince1970: 100)
            monitor.now = { now }
            var events: [HotkeyEvent] = []
            monitor.onEvent = { events.append($0) }
            monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
            now.addTimeInterval(duration)
            monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
            #expect(events == [.pressed, .released])
        }
    }

    @Test("a key chord in flight cannot turn into a tap")
    func chord() {
        let monitor = HotkeyMonitor()
        monitor.chord = ActionHotkeyMonitor()
        var now = Date(timeIntervalSince1970: 100)
        monitor.now = { now }
        var events: [HotkeyEvent] = []
        // The controller's part: a press starts a recording, an interruption discards it.
        monitor.onEvent = { event in
            events.append(event)
            if event == .pressed { monitor.isDictationActive = true }
            if event == .interrupted { monitor.isDictationActive = false }
        }
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
        now.addTimeInterval(0.05)
        monitor.handle(type: .keyDown, event: event(kVK_ANSI_A, .maskSecondaryFn, type: .keyDown))
        now.addTimeInterval(0.05)
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
        #expect(events == [.pressed, .interrupted, .released])
    }

    @Test("a stop press cannot restart dictation when finishing completes before key up")
    func stopWhileFinishing() {
        let monitor = HotkeyMonitor()
        var now = Date(timeIntervalSince1970: 100)
        monitor.now = { now }
        monitor.isLatched = true
        monitor.isDictationActive = true
        var events: [HotkeyEvent] = []
        monitor.onEvent = { event in
            events.append(event)
            if event == .stopLatched {
                monitor.isLatched = false
                monitor.isDictationActive = false
            }
        }
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn))
        now.addTimeInterval(0.1)
        monitor.handle(type: .flagsChanged, event: event(kVK_Function, []))
        #expect(events == [.stopLatched])
    }

    @Test("recorded release queues after press and keeps capture timestamps")
    func recordedReleaseBeforeStartWorkFinishes() {
        let monitor = HotkeyMonitor()
        var delivered: [(HotkeyEvent, Date)] = []
        var recording = false
        var completed = 0
        monitor.onTimedEvent = { event, time in
            delivered.append((event, time))
            if event == .pressed { recording = true }
            if event == .released, recording { completed += 1; recording = false }
        }
        let down = Date(timeIntervalSince1970: 100)
        monitor.handleRecorded(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn), at: down)
        monitor.handleRecorded(type: .flagsChanged, event: event(kVK_Function, []), at: down.addingTimeInterval(0.5))
        #expect(delivered.isEmpty)
        monitor.deliverPendingEvents()
        #expect(delivered.map(\.0) == [.pressed, .released])
        #expect(delivered.map(\.1) == [down, down.addingTimeInterval(0.5)])
        #expect(completed == 1)
    }

    @Test("recorded short tap and double tap use capture times")
    func recordedDoubleTap() {
        let monitor = HotkeyMonitor()
        var events: [HotkeyEvent] = []
        monitor.onTimedEvent = { event, _ in events.append(event) }
        let start = Date(timeIntervalSince1970: 100)
        for (offset, down) in [(0.0, true), (0.08, false), (0.15, true), (0.22, false)] {
            monitor.handleRecorded(type: .flagsChanged,
                                   event: event(kVK_Function, down ? .maskSecondaryFn : []),
                                   at: start.addingTimeInterval(offset))
        }
        monitor.deliverPendingEvents()
        #expect(events == [.pressed, .latched])
    }

    @Test("recorded minimum hold distinguishes a tap from a hold")
    func recordedMinimumHold() {
        for (duration, ending) in [(0.24, HotkeyEvent.latched), (0.26, .released)] {
            let monitor = HotkeyMonitor()
            var events: [HotkeyEvent] = []
            monitor.onTimedEvent = { event, _ in events.append(event) }
            let start = Date(timeIntervalSince1970: 100)
            monitor.handleRecorded(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn), at: start)
            monitor.handleRecorded(type: .flagsChanged, event: event(kVK_Function, []), at: start.addingTimeInterval(duration))
            monitor.deliverPendingEvents()
            #expect(events == [.pressed, ending])
        }
    }

    @Test("recorded interrupted key discards a fresh hold")
    func recordedInterruptedKey() {
        let monitor = HotkeyMonitor()
        var events: [HotkeyEvent] = []
        monitor.onTimedEvent = { event, _ in events.append(event) }
        let start = Date(timeIntervalSince1970: 100)
        monitor.handleRecorded(type: .flagsChanged, event: event(kVK_Function, .maskSecondaryFn), at: start)
        monitor.handleRecorded(type: .keyDown,
                               event: event(kVK_ANSI_A, .maskSecondaryFn, type: .keyDown),
                               at: start.addingTimeInterval(0.1))
        monitor.handleRecorded(type: .flagsChanged, event: event(kVK_Function, []), at: start.addingTimeInterval(0.2))
        monitor.deliverPendingEvents()
        #expect(events == [.pressed, .interrupted, .released])
    }
}
