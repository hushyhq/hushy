import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Murmur

/// Onboarding's key lesson: the recognizer on timings, the monitor's raw edges, and the step's words.
@Suite("Key lesson")
@MainActor
struct KeyGesturePracticeTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func fed(_ edges: [(Bool, TimeInterval)]) -> (KeyGesturePractice, [KeyGesturePractice.Gesture]) {
        var lesson = KeyGesturePractice()
        var completed: [KeyGesturePractice.Gesture] = []
        for (down, time) in edges {
            if let gesture = lesson.edge(isDown: down, at: at(time)) { completed.append(gesture) }
        }
        return (lesson, completed)
    }

    @Test("two quick taps are a double-tap; one tap is not")
    func doubleTap() {
        let (one, none) = fed([(true, 0), (false, 0.1)])
        #expect(none.isEmpty)
        #expect(!one.hasDoubleTapped)
        let (two, done) = fed([(true, 0), (false, 0.1), (true, 0.3), (false, 0.4)])
        #expect(done == [.doubleTap])
        #expect(two.hasDoubleTapped)
        #expect(two.latest == .doubleTap)
    }

    @Test("the double-tap uses the monitor's own window and tap length")
    func thresholds() {
        let window = KeyGesturePractice.doubleTapWindow
        #expect(window == HotkeyMonitor.doubleTapWindow)
        #expect(KeyGesturePractice.tapLimit == DictationController.minimumHold)
        let (_, inside) = fed([(true, 0), (false, 0.1), (true, 0.09 + window), (false, 0.2 + window)])
        #expect(inside == [.doubleTap])
        let (_, late) = fed([(true, 0), (false, 0.1), (true, 0.15 + window), (false, 0.2 + window)])
        #expect(late.isEmpty, "a second tap after the window is a new first tap")
        let (_, slowFirst) = fed([(true, 0), (false, 0.3), (true, 0.4), (false, 0.45)])
        #expect(slowFirst.isEmpty, "a first press over the tap length is not a tap")
    }

    @Test("a hold of half a second or more is a hold; a shorter one asks for longer")
    func hold() {
        let (held, done) = fed([(true, 0), (false, 0.6)])
        #expect(done == [.hold])
        #expect(held.hasHeld)
        let (brief, none) = fed([(true, 0), (false, 0.35)])
        #expect(none.isEmpty)
        #expect(brief.heldTooBriefly)
        #expect(!brief.hasHeld)
    }

    @Test("a repeated edge (a dropped event) is ignored, and the key reads down only while down")
    func repeatedEdges() {
        var lesson = KeyGesturePractice()
        lesson.edge(isDown: true, at: at(0))
        #expect(lesson.isDown)
        lesson.edge(isDown: true, at: at(0.05))
        lesson.edge(isDown: false, at: at(0.1))
        #expect(!lesson.isDown)
        lesson.edge(isDown: false, at: at(0.15))
        lesson.edge(isDown: true, at: at(0.3))
        #expect(lesson.edge(isDown: false, at: at(0.35)) == .doubleTap)
    }

    @Test("the monitor reports each fn edge, and not a press that completes the action chord")
    func monitorEdges() {
        let monitor = HotkeyMonitor()
        monitor.chord = ActionHotkeyMonitor()
        var edges: [Bool] = []
        monitor.onTriggerEdge = { isDown, _ in edges.append(isDown) }
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Function, .maskSecondaryFn))
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Function, []))
        #expect(edges == [true, false])
        edges.removeAll()
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Control, .maskControl))
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Function, [.maskControl, .maskSecondaryFn]))
        _ = monitor.handle(type: .flagsChanged, event: flags(kVK_Function, .maskControl))
        #expect(edges.isEmpty, "fn held for the voice-action chord is not a dictation key press")
    }

    @Test("recorded taps deliver their edges after the tap returns")
    func deferredEdges() {
        let monitor = HotkeyMonitor()
        var edges: [Bool] = []
        monitor.onTriggerEdge = { isDown, _ in edges.append(isDown) }
        monitor.handleRecorded(type: .flagsChanged, event: flags(kVK_Function, .maskSecondaryFn), at: at(0))
        #expect(edges.isEmpty)
        monitor.deliverPendingEvents()
        #expect(edges == [true])
    }

    @Test("each state has one title and one short line, and the blocked state says why")
    func copy() {
        let waiting = OnboardingKeyCopy.state(KeyGesturePractice(), canSeeKeys: true, glyph: "fn")
        #expect(waiting.title == "Double-tap fn")
        let tapped = OnboardingKeyCopy.state(KeyGesturePractice(learned: [.doubleTap]), canSeeKeys: true, glyph: "fn")
        #expect(tapped.title == "Now hold fn")
        let both = OnboardingKeyCopy.state(KeyGesturePractice(learned: [.doubleTap, .hold]), canSeeKeys: true, glyph: "fn")
        #expect(both.line.contains("Enter to paste"))
        let blocked = OnboardingKeyCopy.state(KeyGesturePractice(), canSeeKeys: false, glyph: "fn")
        #expect(blocked.line.contains("Accessibility"))
        for line in [waiting, tapped, both, blocked].map(\.line) {
            #expect(!line.contains("\u{2014}") && !line.contains("!"), "the app's voice: no em dashes or exclamation marks")
            #expect(line.split(separator: " ").count <= 14, "one short line")
        }
    }

    private func flags(_ key: Int, _ value: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)!
        event.type = .flagsChanged
        event.flags = value
        return event
    }
}
