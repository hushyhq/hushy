import Foundation

/// Onboarding's key lesson, as a value: the raw presses of the dictation key (`HotkeyMonitor.onTriggerEdge`)
/// in, the gestures the person has shown out. Pure, so a test can feed it timings.
///
/// The thresholds are the app's own, so passing the lesson means the real gesture works:
/// - a **tap** is a press shorter than `DictationController.minimumHold`, the length under which
///   the monitor treats a press as a tap that latches hands-free;
/// - a **double-tap** is a second tap whose press starts within `HotkeyMonitor.doubleTapWindow` of
///   the first tap's release, the window the monitor uses to keep hands-free on;
/// - a **hold** is a press of at least `holdLesson`. Dictation starts listening from
///   `minimumHold`, but a lesson that passed on a quarter-second twitch would teach nothing.
struct KeyGesturePractice: Equatable {
    enum Gesture: Equatable, Hashable { case doubleTap, hold }

    /// The same numbers as `DictationController.minimumHold` and `HotkeyMonitor.doubleTapWindow`
    /// (main-actor statics, so not readable here); `KeyGesturePracticeTests` pins them equal.
    static let tapLimit: TimeInterval = 0.25
    static let doubleTapWindow: TimeInterval = 0.4
    static let holdLesson: TimeInterval = 0.5

    /// The key is down right now (the key cap is lit while it is).
    private(set) var isDown = false
    private(set) var learned: Set<Gesture> = []
    /// The gesture the latest release completed, for the moment of feedback; nil after any other release.
    private(set) var latest: Gesture?
    /// A press that was long enough to listen but too short for the lesson.
    private(set) var heldTooBriefly = false
    private var downAt: Date?
    private var lastTapUpAt: Date?
    private var pressIsSecondTap = false

    init(learned: Set<Gesture> = [], isDown: Bool = false) {
        self.learned = learned
        self.isDown = isDown
    }

    var hasDoubleTapped: Bool { learned.contains(.doubleTap) }
    var hasHeld: Bool { learned.contains(.hold) }

    /// Feeds one edge. Returns the gesture this edge completed, if any. Repeated edges in the same
    /// direction (a dropped event) are ignored rather than counted.
    @discardableResult
    mutating func edge(isDown down: Bool, at time: Date) -> Gesture? {
        guard down != isDown else { return nil }
        isDown = down
        if down {
            pressIsSecondTap = lastTapUpAt.map { time.timeIntervalSince($0) <= Self.doubleTapWindow } ?? false
            downAt = time
            return nil
        }
        defer { downAt = nil }
        guard let downAt else { return nil }
        let held = time.timeIntervalSince(downAt)
        latest = nil
        heldTooBriefly = false
        if held < Self.tapLimit {
            if pressIsSecondTap {
                lastTapUpAt = nil
                return complete(.doubleTap)
            }
            lastTapUpAt = time
            return nil
        }
        lastTapUpAt = nil
        if held >= Self.holdLesson { return complete(.hold) }
        heldTooBriefly = true
        return nil
    }

    private mutating func complete(_ gesture: Gesture) -> Gesture {
        learned.insert(gesture)
        latest = gesture
        return gesture
    }
}
