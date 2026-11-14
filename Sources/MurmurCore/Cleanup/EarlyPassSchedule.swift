import Foundation

/// When the recogniser may take another pass over a recording that is still going, so its closed sentence groups can
/// be cleaned before the key release (`EarlyCleanupQueue`).
///
/// A pass re-reads the whole recording so far, which is what makes its text match the pass after the release. That
/// costs more the longer the recording is, so:
/// - nothing runs before `first` seconds: a dictation that short is one model call and has no closed group to clean;
/// - passes are at least `gap` seconds apart, and `stretch` × the recording's length apart once that is longer, so a
///   long recording is not re-read every two seconds;
/// - never two at once.
public struct EarlyPassSchedule: Sendable, Equatable {
    public static let defaultFirst = 10.0
    public static let defaultGap = 2.0
    public static let defaultStretch = 0.1

    public let first: Double
    public let gap: Double
    public let stretch: Double
    public private(set) var isRunning = false
    /// Passes started so far.
    public private(set) var passes = 0
    private var nextStart: Double

    public init(
        first: Double = EarlyPassSchedule.defaultFirst, gap: Double = EarlyPassSchedule.defaultGap,
        stretch: Double = EarlyPassSchedule.defaultStretch
    ) {
        self.first = first
        self.gap = gap
        self.stretch = stretch
        self.nextStart = first
    }

    /// Whether a pass over the `seconds` recorded so far should start now. When it says yes the pass counts as
    /// running until `finished()`.
    public mutating func start(at seconds: Double) -> Bool {
        guard !isRunning, seconds >= nextStart else { return false }
        isRunning = true
        passes += 1
        nextStart = seconds + max(gap, stretch * seconds)
        return true
    }

    public mutating func finished() {
        isRunning = false
    }
}
