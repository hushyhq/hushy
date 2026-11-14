import Testing
@testable import MurmurCore

/// The double-tap recogniser is pure: every test feeds timestamps and events, none sleeps.
@Suite("Tap recogniser")
struct TapRecogniserTests {
    private let window = TapRecogniser.doubleTapWindow
    private let hold = TapRecogniser.maxTapHold

    private func down(_ time: Double, others: Bool = false) -> TapRecogniser.Input {
        .trigger(isDown: true, othersDown: others, at: time)
    }

    private func up(_ time: Double, others: Bool = false) -> TapRecogniser.Input {
        .trigger(isDown: false, othersDown: others, at: time)
    }

    private func run(_ inputs: [TapRecogniser.Input], listening: Bool = false) -> [TapRecogniser.Output] {
        var recogniser = TapRecogniser()
        return inputs.map { recogniser.feed($0, isListening: listening) }
    }

    @Test("the constants are what the doc says")
    func constants() {
        #expect(window == 0.4)
        #expect(hold == 0.3)
    }

    @Test("two quick bare taps are a double tap, recognised when the second is released")
    func doubleTap() {
        let outputs = run([down(0), up(0.1), down(0.3), up(0.4)])
        #expect(outputs == [.none, .none, .none, .doubleTap])
    }

    @Test("a second press just inside the window counts; just after it starts over")
    func windowEdge() {
        #expect(run([down(0), up(0.1), down(0.1 + window - 0.01), up(0.15 + window)]).last == .doubleTap)
        let late = run([down(0), up(0.1), down(0.1 + window + 0.01), up(0.2 + window)])
        #expect(late.last == TapRecogniser.Output.none)
    }

    @Test("a press that is too late is a fresh first tap, so the next tap completes a double")
    func lateThenQuick() {
        let outputs = run([down(0), up(0.1), down(2), up(2.1), down(2.2), up(2.3)])
        #expect(outputs.last == .doubleTap)
    }

    @Test("a held first press is not a tap")
    func heldFirst() {
        #expect(run([down(0), up(hold + 0.01), down(hold + 0.1), up(hold + 0.2)]).allSatisfy { $0 == .none })
    }

    @Test("a held second press is not a tap, so Control held as a modifier never triggers")
    func heldSecond() {
        #expect(run([down(0), up(0.1), down(0.2), up(0.2 + hold + 0.01)]).allSatisfy { $0 == .none })
    }

    @Test("Ctrl+C: another key between the press and release resets the tap")
    func shortcutKey() {
        let outputs = run([down(0), .otherKey, up(0.1), down(0.2), up(0.3)])
        #expect(outputs.allSatisfy { $0 == .none })
    }

    @Test("Ctrl+A twice is never a double tap")
    func ctrlATwice() {
        let outputs = run([down(0), .otherKey, up(0.1), down(0.2), .otherKey, up(0.3)])
        #expect(outputs.allSatisfy { $0 == .none })
    }

    @Test("another key between the two taps resets")
    func keyBetweenTaps() {
        #expect(run([down(0), up(0.1), .otherKey, down(0.2), up(0.3)]).allSatisfy { $0 == .none })
    }

    @Test("a tap with another modifier already down never starts")
    func otherModifierAtPress() {
        #expect(run([down(0, others: true), up(0.1, others: true), down(0.2, others: true), up(0.3)]).allSatisfy { $0 == .none })
    }

    @Test("a three-key chord: another modifier joining mid-tap resets")
    func threeKeyChord() {
        let outputs = run([down(0), .otherModifier, .otherKey, up(0.1), down(0.2), up(0.3)])
        #expect(outputs.allSatisfy { $0 == .none })
    }

    @Test("another modifier between the taps resets")
    func modifierBetweenTaps() {
        #expect(run([down(0), up(0.1), .otherModifier, down(0.2), up(0.3)]).allSatisfy { $0 == .none })
    }

    @Test("three quick taps give one double tap, then the third starts over")
    func tripleTap() {
        let outputs = run([down(0), up(0.1), down(0.2), up(0.3), down(0.4), up(0.5)])
        #expect(outputs.filter { $0 == .doubleTap }.count == 1)
    }

    @Test("while listening, one bare tap cancels and counts as nothing else")
    func cancelTap() {
        var recogniser = TapRecogniser()
        #expect(recogniser.feed(down(0), isListening: true) == .none)
        #expect(recogniser.feed(up(0.1), isListening: true) == .cancelTap)
        // The cancelling tap is not the first half of a new double tap.
        #expect(recogniser.feed(down(0.2), isListening: false) == .none)
        #expect(recogniser.feed(up(0.3), isListening: false) == .none)
    }

    @Test("while listening, a held key or a shortcut does not cancel")
    func noCancel() {
        #expect(run([down(0), up(hold + 0.01)], listening: true).allSatisfy { $0 == .none })
        #expect(run([down(0), .otherKey, up(0.1)], listening: true).allSatisfy { $0 == .none })
        #expect(run([down(0, others: true), up(0.1)], listening: true).allSatisfy { $0 == .none })
    }

    @Test("reset forgets a half-finished tap")
    func reset() {
        var recogniser = TapRecogniser()
        _ = recogniser.feed(down(0), isListening: false)
        _ = recogniser.feed(up(0.1), isListening: false)
        recogniser.reset()
        _ = recogniser.feed(down(0.2), isListening: false)
        #expect(recogniser.feed(up(0.3), isListening: false) == .none)
    }
}
