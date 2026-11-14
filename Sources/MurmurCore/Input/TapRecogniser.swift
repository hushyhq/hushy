import Foundation

/// Recognises a bare double tap of one modifier key (Control twice, say), and a bare single tap
/// while a voice action is listening. A small pure state machine: it is fed timestamps and the
/// few facts about key events it needs, and reads no clock, so its tests run without sleeping.
///
/// What counts as a tap: the trigger key goes down with no other modifier held and comes up again
/// within `maxTapHold`, and nothing else was pressed in between. A double tap is two such taps,
/// the second key-down arriving within `doubleTapWindow` of the first release. It is recognised
/// when the second tap is released, not when it goes down, so a Control that turns into a
/// shortcut (Ctrl+C, Ctrl+A, a held Control, a three-key chord) can never have fired already.
///
/// Only the trigger key and the *fact* that some other key or modifier changed are ever seen:
/// which other key it was is not part of the input, so nothing typed can be read, stored or
/// logged through here.
public struct TapRecogniser: Sendable, Equatable {
    /// The longest gap from the first release to the second press. Dictation's own latch uses 0.5 s;
    /// 0.4 s is a deliberate double press without catching two separate Control uses.
    public static let doubleTapWindow: TimeInterval = 0.4
    /// The longest a key may stay down and still be a tap. A longer press is a held modifier.
    public static let maxTapHold: TimeInterval = 0.3

    public enum Input: Sendable, Equatable {
        /// The trigger key changed. `othersDown`: any other modifier is down with it.
        case trigger(isDown: Bool, othersDown: Bool, at: TimeInterval)
        /// Some other modifier key changed.
        case otherModifier
        /// Some non-modifier key went down.
        case otherKey
    }

    public enum Output: Sendable, Equatable {
        case none
        /// Two clean taps, and nothing was listening.
        case doubleTap
        /// One clean tap while a voice action was listening: cancel it.
        case cancelTap
    }

    private enum Phase: Equatable {
        case idle
        case firstDown(TimeInterval)
        case firstUp(TimeInterval)
        case secondDown(TimeInterval)
    }

    private var phase = Phase.idle

    public init() {}

    /// Forget any half-finished tap (the event tap was re-armed and events may have been lost).
    public mutating func reset() { phase = .idle }

    public mutating func feed(_ input: Input, isListening: Bool) -> Output {
        switch input {
        case .otherModifier, .otherKey:
            phase = .idle
            return .none
        case .trigger(let isDown, let othersDown, let time):
            guard !othersDown else {
                phase = .idle
                return .none
            }
            return isDown ? pressed(at: time, isListening: isListening) : released(at: time, isListening: isListening)
        }
    }

    private mutating func pressed(at time: TimeInterval, isListening: Bool) -> Output {
        if case .firstUp(let up) = phase, !isListening, time - up <= Self.doubleTapWindow {
            phase = .secondDown(time)
        } else {
            phase = .firstDown(time)
        }
        return .none
    }

    private mutating func released(at time: TimeInterval, isListening: Bool) -> Output {
        let before = phase
        phase = .idle
        switch before {
        case .firstDown(let down) where time - down <= Self.maxTapHold:
            if isListening { return .cancelTap }
            phase = .firstUp(time)
            return .none
        case .secondDown(let down) where time - down <= Self.maxTapHold:
            return isListening ? .cancelTap : .doubleTap
        default:
            return .none
        }
    }
}
