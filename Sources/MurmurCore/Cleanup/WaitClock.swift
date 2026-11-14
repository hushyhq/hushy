import Foundation
import Synchronization

/// How long a dictation may keep waiting on the model after the key is released.
///
/// Two limits, whichever comes first:
/// - an outer deadline (`SmartCleaner.defaultDictationCeiling`, counted from the release, but never earlier than
///   the floor: a recording whose transcription used up the 20 s still gets `SmartCleaner.deadlineFloor` of model
///   time, so the real bound is the later of the two), and
/// - a no-progress limit: the wait ends when no group has been answered for `noProgress`. Every answer
///   that arrives restarts that clock, so a model that is slow but working is never cut off by it,
///   while a model that is not answering costs the person at most `noProgress` after the release.
///
/// An answer here means the model replied (its text was used, or a guard rejected it). A timeout, a
/// busy system or an error is not progress.
final class WaitClock: Sendable {
    private struct State {
        var lastProgress: ContinuousClock.Instant
    }

    private let state: Mutex<State>
    private let outer: ContinuousClock.Instant
    private let noProgress: Duration
    /// The model always gets at least until here (the floor), whatever the clocks above say.
    private let floor: ContinuousClock.Instant

    /// - Parameters:
    ///   - origin: when the wait started counting (the key release, or now when unknown).
    ///   - outer: the absolute deadline.
    ///   - floor: the earliest the wait may end.
    init(origin: ContinuousClock.Instant, outer: ContinuousClock.Instant, noProgress: Duration, floor: ContinuousClock.Instant) {
        self.state = Mutex(State(lastProgress: origin))
        self.outer = outer
        self.noProgress = noProgress
        self.floor = floor
    }

    /// The instant the wait ends, as things stand now.
    var instant: ContinuousClock.Instant {
        let last = state.withLock { $0.lastProgress }
        return min(outer, max(last.advanced(by: noProgress), floor))
    }

    /// The model answered a group just now: the no-progress clock starts again.
    func markProgress() {
        let now = ContinuousClock.now
        state.withLock { $0.lastProgress = max($0.lastProgress, now) }
    }

    /// Whether this outcome means the model answered.
    static func isAnswer(usedModel: Bool, rejection: String?) -> Bool {
        switch ModelOutcome(usedModel: usedModel, rejection: rejection) {
        case .used, .rejectedByGuard: true
        default: false
        }
    }
}
