import SwiftUI

/// The pill's one motion language: every duration, curve and spring the capsule, its rows, its
/// cards and its hints use, defined here once and read by role.
///
/// A role says what is happening, not which numbers to use: the pill *opens* when a dictation
/// starts, *morphs* between states while it is open, *closes* back to its resting mark, and the
/// things that open from it *rise* and *fall*. Leaving is always quicker than arriving, nothing
/// overshoots but success (`pop`), and under Reduce Motion every spatial role becomes the one
/// short `fade`.
///
/// The values that match the app's windows are the same numbers `Theme.Motion` holds
/// (`morph` is `snappy`, `rise` is `settle`, `pop`, `cool`, `fade` and `hover` are their
/// namesakes), so the pill and the windows move as one family. `PillMotionTests` pins that.
struct PillMotion: Equatable, Sendable {
    struct Spring: Equatable, Sendable {
        var response: Double
        var damping: Double
    }

    enum Role: CaseIterable, Sendable {
        /// The resting mark becomes a live capsule (key down, a tap on the idle pill).
        case open
        /// One open state becomes another: listening to writing, writing to done.
        case morph
        /// Back to the resting mark.
        case close
        /// A card, banner or hint opens from the capsule.
        case rise
        /// The same things leave.
        case fall
        /// Success only: the ✓. The one overshoot.
        case pop
        /// Opacity only. Also what every spatial role becomes under Reduce Motion.
        case fade
        /// Hover rings and tints.
        case hover
        /// The glow fading behind a state that has already changed (live to rest).
        case cool
        /// The ✓'s stroke drawing itself.
        case draw

        /// Roles that move or resize something, and so turn into `fade` under Reduce Motion.
        var isSpatial: Bool {
            switch self {
            case .open, .morph, .close, .rise, .fall, .pop: true
            case .fade, .hover, .cool, .draw: false
            }
        }
    }

    var open: Spring
    var morph: Spring
    var close: Spring
    var rise: Spring
    var fall: Spring
    var pop: Spring
    /// Seconds.
    var fadeDuration: Double
    var hoverDuration: Double
    var coolDuration: Double
    /// How long the ✓'s stroke takes to draw.
    var drawDuration: Double = 0.18
    /// The panel's own slide to an edge when a dragged pill is let go (an AppKit frame animation).
    var snapDuration: Double = 0.18
    /// The error shake: this far to each side, this long per step.
    var shakeDistance: Double = 4
    var shakeStep: Double = 0.05
    /// One slow rise and fall of opacity, for something that is live but has nothing to show
    /// (an open microphone in silence, a wait that is stuck on one sentence).
    var breathePeriod: Double
    /// The lowest opacity `breathe` reaches; it peaks at 1.
    var breatheFloor: Double
    /// How long the pointer rests on a control before its hint appears.
    var hintDelay: Double
    /// A wait shorter than this never shows the writing dots: the bars go straight to the ✓.
    var directDoneWindow: Double
    /// How long a shrinking panel keeps its larger frame while the content animates down inside
    /// it (`PillPanel.setState`). Longer than the slowest exit takes to land.
    var shrinkWait: Duration
    var reducedShrinkWait: Duration
    /// 1 in the app. The preview plays the same motion slowed down (0.5, 0.25).
    var speed: Double = 1

    /// The pill's motion.
    static let standard = PillMotion(
        open: Spring(response: 0.22, damping: 0.80),
        morph: Spring(response: 0.28, damping: 0.82),
        close: Spring(response: 0.20, damping: 0.92),
        rise: Spring(response: 0.45, damping: 0.90),
        fall: Spring(response: 0.30, damping: 0.95),
        pop: Spring(response: 0.32, damping: 0.62),
        fadeDuration: 0.16, hoverDuration: 0.12, coolDuration: 0.6,
        breathePeriod: 2.4, breatheFloor: 0.55,
        hintDelay: 0.25, directDoneWindow: 0.25,
        shrinkWait: .milliseconds(450), reducedShrinkWait: .milliseconds(200))

    /// The timings the pill had before this language existed: one 0.45 s spring for every state
    /// change, in either direction. Kept only so the preview can play old against new.
    static let legacy = PillMotion(
        open: Spring(response: 0.45, damping: 0.90),
        morph: Spring(response: 0.45, damping: 0.90),
        close: Spring(response: 0.45, damping: 0.90),
        rise: Spring(response: 0.45, damping: 0.90),
        fall: Spring(response: 0.45, damping: 0.90),
        pop: Spring(response: 0.32, damping: 0.62),
        fadeDuration: 0.16, hoverDuration: 0.12, coolDuration: 0.6,
        breathePeriod: 2.4, breatheFloor: 0.55,
        hintDelay: 0.25, directDoneWindow: 0,
        shrinkWait: .milliseconds(600), reducedShrinkWait: .milliseconds(200))

    /// The animation for a role. Under Reduce Motion a spatial role, and the trailing glow, is the
    /// plain fade: the content changes in place instead of travelling.
    func animation(_ role: Role, reduceMotion: Bool = false) -> Animation {
        let base = reduceMotion && (role.isSpatial || role == .cool) ? fade : unreduced(role)
        return speed == 1 ? base : base.speed(speed)
    }

    private var fade: Animation { .easeOut(duration: fadeDuration) }

    private func unreduced(_ role: Role) -> Animation {
        switch role {
        case .open: spring(open)
        case .morph: spring(morph)
        case .close: spring(close)
        case .rise: spring(rise)
        case .fall: spring(fall)
        case .pop: spring(pop)
        case .fade: fade
        case .hover: .easeOut(duration: hoverDuration)
        case .cool: .timingCurve(0.05, 0.7, 0.1, 1, duration: coolDuration)
        case .draw: .easeOut(duration: drawDuration)
        }
    }

    private func spring(_ spring: Spring) -> Animation {
        .spring(response: spring.response, dampingFraction: spring.damping)
    }

    /// How long a shrinking panel waits before its frame follows the content.
    func shrinkDelay(reduceMotion: Bool) -> Duration {
        let wait = reduceMotion ? reducedShrinkWait : shrinkWait
        return speed == 1 ? wait : wait / speed
    }

    /// One step of the error shake.
    var shake: Animation {
        .linear(duration: shakeStep / speed)
    }

    /// The panel's slide to an edge, in seconds, at this motion's speed.
    var snapSeconds: Double {
        snapDuration / speed
    }

    /// The opacity of something breathing at `time` seconds: between `breatheFloor` and 1.
    func breathe(at time: TimeInterval) -> Double {
        let wave = 0.5 + 0.5 * sin(time / breathePeriod * 2 * .pi)
        return breatheFloor + (1 - breatheFloor) * wave
    }

    /// Which role a change of state plays. A card arriving or leaving decides first (it travels
    /// furthest), then leaving for idle, then arriving from it; everything else is a morph.
    static func role(from old: PillState, to new: PillState) -> Role {
        if new.opensCard, !old.opensCard { return .rise }
        if old.opensCard, !new.opensCard { return .fall }
        if new == .idle { return .close }
        if old == .idle { return .open }
        return .morph
    }
}

extension PillState {
    /// Dictation's own listening states, drawn with the large bars the writing dots fold out of.
    var showsDictationBars: Bool {
        switch self {
        case .listening, .handsFree: true
        default: false
        }
    }

    /// States that stack a card on the capsule (the not-pasted card, the answer card, a confirm
    /// card with more than one row).
    var opensCard: Bool {
        switch self {
        case .noField, .answer: true
        case .actionConfirm(let card): card.rows.count > 1   // `ActionConfirmationCard.Layout.stacked`
        default: false
        }
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// The pill's timings: `.standard` in the app. The preview swaps in `.legacy`, or a slowed copy.
    @Entry var pillMotion: PillMotion = .standard
    /// Preview only: forces Reduce Motion on or off for the pill. `nil` follows the Mac's setting.
    @Entry var pillReduceMotionOverride: Bool? = nil
}

/// Whether the pill should hold still: the Mac's Reduce Motion setting, unless the preview
/// overrides it (`pillReduceMotionOverride`).
@propertyWrapper
struct PillReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.pillReduceMotionOverride) private var override

    var wrappedValue: Bool { override ?? system }
}
