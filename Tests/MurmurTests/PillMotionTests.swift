import SwiftUI
import Testing
@testable import Murmur

/// The pill's motion language (`PillMotion`): one set of values, read by role.
@Suite("Pill — one motion language")
struct PillMotionTests {
    private let motion = PillMotion.standard
    private let spatial: [PillMotion.Role] = [.open, .morph, .close, .rise, .fall, .pop]

    @Test("the pill shares the windows' values where the gesture is the same")
    func oneFamilyWithTheWindows() {
        #expect(motion.animation(.morph) == Theme.snappy)
        #expect(motion.animation(.rise) == Theme.settle)
        #expect(motion.animation(.pop) == Theme.Motion.pop)
        #expect(motion.animation(.cool) == Theme.Motion.cool)
        #expect(motion.animation(.fade) == Theme.Motion.fade)
        #expect(motion.animation(.hover) == Theme.Motion.hover)
    }

    @Test("every role has a value, and the spatial ones are exactly the six that move")
    func rolesAreComplete() {
        #expect(Set(PillMotion.Role.allCases.filter(\.isSpatial)) == Set(spatial))
        for role in PillMotion.Role.allCases { _ = motion.animation(role) }
    }

    @Test("under Reduce Motion every spatial role, and the trailing glow, is the one fade")
    func reduceMotionFades() {
        for role in spatial + [.cool] {
            #expect(motion.animation(role, reduceMotion: true) == Theme.Motion.fade, "\(role)")
        }
        #expect(motion.animation(.fade, reduceMotion: true) == Theme.Motion.fade)
        #expect(motion.animation(.hover, reduceMotion: true) == Theme.Motion.hover)
    }

    @Test("the ✓ draws in 180 ms, and the other one-off values are named here once")
    @MainActor
    func namedOneOffs() {
        #expect(motion.animation(.draw) == .easeOut(duration: 0.18))
        #expect(motion.animation(.draw, reduceMotion: true) == .easeOut(duration: 0.18), "a stroke is not travel; the ✓ view shows it drawn")
        #expect(motion.snapDuration == 0.18)
        #expect(motion.shakeStep == 0.05 && motion.shakeDistance == 4)
        #expect(motion.hintDelay == PillKeyHintModifier.delay)
        #expect(PillHoverRing.fade == .milliseconds(120))
    }

    @Test("leaving is quicker than arriving")
    func exitsAreShorter() {
        #expect(motion.close.response < motion.open.response)
        #expect(motion.fall.response < motion.rise.response)
        #expect(motion.open.response < motion.rise.response, "the key's answer is quicker than a card's travel")
    }

    @Test("only success overshoots, and nothing a person waits on is longer than 450 ms")
    func restraint() {
        for spring in [motion.open, motion.morph, motion.close, motion.rise, motion.fall] {
            #expect(spring.damping >= 0.8)
            #expect(spring.response <= 0.45)
        }
        #expect(motion.close.damping >= 0.9)
        #expect(motion.fall.damping >= 0.9)
        #expect(motion.pop.damping < 0.7)
        #expect(motion.fadeDuration <= 0.2)
        #expect(motion.hoverDuration <= motion.fadeDuration)
    }

    @Test("a change of state plays the role of what is happening")
    func rolesForStateChanges() {
        let card = PillState.noField(.offerCopy)
        #expect(PillMotion.role(from: .idle, to: .listening) == .open)
        #expect(PillMotion.role(from: .idle, to: .handsFree(startedAt: .distantPast)) == .open)
        #expect(PillMotion.role(from: .listening, to: .handsFree(startedAt: .distantPast)) == .morph)
        #expect(PillMotion.role(from: .listening, to: .processing()) == .morph)
        #expect(PillMotion.role(from: .processing(), to: .done(words: 4)) == .morph)
        #expect(PillMotion.role(from: .done(words: 4), to: .idle) == .close)
        #expect(PillMotion.role(from: .listening, to: .idle) == .close)
        #expect(PillMotion.role(from: .processing(), to: card) == .rise)
        #expect(PillMotion.role(from: .idle, to: card) == .rise)
        #expect(PillMotion.role(from: card, to: .idle) == .fall)
        #expect(PillMotion.role(from: card, to: .noField(.copied)) == .morph)
        #expect(PillMotion.role(from: card, to: .listening) == .fall)
    }

    @Test("breathing stays between its floor and full, and repeats")
    func breathing() {
        for step in 0..<240 {
            let value = motion.breathe(at: Double(step) * 0.05)
            #expect(value >= motion.breatheFloor - 1e-9 && value <= 1 + 1e-9)
        }
        #expect(abs(motion.breathe(at: 0.7) - motion.breathe(at: 0.7 + motion.breathePeriod)) < 1e-9)
        #expect(motion.breatheFloor > 0.3, "never close to invisible")
    }

    @Test("a shrinking panel waits for the slowest exit, and less under Reduce Motion")
    func shrinkWait() {
        #expect(motion.shrinkDelay(reduceMotion: false) >= .seconds(motion.fall.response))
        #expect(motion.shrinkDelay(reduceMotion: true) < motion.shrinkDelay(reduceMotion: false))
    }

    @Test("the app runs at full speed; a slowed copy slows every role and the panel's wait with it")
    func slowMotion() {
        #expect(motion.speed == 1)
        var slow = motion
        slow.speed = 0.25
        #expect(slow.animation(.open) == motion.animation(.open).speed(0.25))
        #expect(slow.animation(.fade) == motion.animation(.fade).speed(0.25))
        #expect(slow.shrinkDelay(reduceMotion: false) == motion.shrinkDelay(reduceMotion: false) * 4)
    }

    @Test("the old timings are one spring in every direction, and never skip the dots")
    func legacy() {
        let old = PillMotion.legacy
        for role in [PillMotion.Role.open, .morph, .close, .rise, .fall] {
            #expect(old.animation(role) == Theme.settle)
        }
        #expect(old.directDoneWindow == 0)
        #expect(old.shrinkDelay(reduceMotion: false) == .milliseconds(600))
    }
}
