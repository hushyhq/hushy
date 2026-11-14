import Foundation
import Synchronization
import os

/// Whether a dictation is in progress (recording or being cleaned). Background model work asks it before each
/// call and waits while it is busy, so one local model can serve both without a summary delaying a dictation.
public final class ForegroundActivity: Sendable {
    private let busy = Mutex(false)

    public init() {}

    public var isBusy: Bool { busy.withLock { $0 } }

    public func set(busy value: Bool) { busy.withLock { $0 = value } }

    /// Returns once no dictation is in progress, or when the task is cancelled.
    public func waitUntilIdle(pollInterval: Duration = .milliseconds(250)) async {
        await waitUntilQuiet(for: .zero, pollInterval: pollInterval)
    }

    /// Returns once no dictation has been in progress for `quiet` in a row, or when the task is cancelled.
    public func waitUntilQuiet(for quiet: Duration, pollInterval: Duration = .milliseconds(250)) async {
        var idleSince: ContinuousClock.Instant?
        while true {
            if isBusy {
                idleSince = nil
            } else {
                let since = idleSince ?? .now
                idleSince = since
                if ContinuousClock.now - since >= quiet { return }
            }
            do { try await Task.sleep(for: pollInterval) } catch { return }
        }
    }
}

/// A summary call that was stopped because a dictation started. Not a failure: the caller waits for the dictation to
/// end (`yieldToForeground`) and asks again.
public struct ForegroundPreempted: Error, Sendable {}

/// The model note and meeting summaries call (`LanguageModels.meeting`).
///
/// - **Which model.** While cleanup runs on the local 4B (`ModelTierPolicy.meetingUsesCleanupModel`), summaries use
///   that same loaded instance (`shared`, the cleanup backend), so memory stays at one copy of the model. Otherwise
///   they use Apple FM, as before.
/// - **Fallback.** A call that fails on the 4B goes to Apple FM inside `shared`'s own chain. `NoteSummarizer` also
///   reruns a whole summary on `appleFallback` when a piece or the merge still ended extractive (a 3,000-word piece
///   does not fit Apple FM's window, so a per-call fallback alone cannot save it).
/// - **Dictation first, always.** `yieldToForeground` holds each summary call back while a dictation is in progress,
///   and a call already running on the shared model is cancelled the moment a dictation starts (the MLX decoder checks
///   for cancellation between tokens and prefill chunks), then asked again once the dictation is over. A dictation waits
///   for the decoder to reach its next check, never for a call to finish. Calls go to `shared` marked
///   `LanguageModelOptions.isBackground`, so a cut-short call leaves nothing of itself running (no prefix rebuilt for the
///   next attempt) for the dictation to wait behind. A summary never runs to the end over a
///   dictation: after each cut-short call it waits for a longer quiet spell first (`quietPeriod`), so dictations that
///   keep coming delay the summary instead of the other way round, for at most `NoteSummarizer.Configuration
///   .dictationYieldLimit` over the whole summary; past it the summary runs again on Apple FM, which the 4B's
///   dictations do not wait on. While a summary call holds the shared model,
///   `ModelHealth` does not count a dictation's timeout or slow probe against the model.
public final class MeetingLanguageModel: LanguageModel {
    public enum Route: Equatable, Sendable {
        /// The cleanup model already in memory (the local 4B).
        case sharedLocal
        case apple
    }

    private let shared: any LanguageModel
    private let apple: any LanguageModel
    private let activity: ForegroundActivity
    private let pollInterval: Duration
    private let preemptInterval: Duration
    private let health: ModelHealth
    private let quietAfterPreemption: Duration
    private let respondBegins: (@Sendable () -> Void)?
    private let routeState = Mutex(Route.apple)
    /// Calls in a row that a dictation cut short; sets how long the next one waits for quiet (`quietPeriod`).
    private let preemptionStreak = Mutex(0)
    static let longestQuiet: Duration = .seconds(30)
    private static let log = Logger(subsystem: "app.hushy", category: "cleanup-model")

    /// - Parameter quietAfterPreemption: how long without a dictation a summary waits for after one call was cut
    ///   short; it doubles with each cut-short call in a row, up to `longestQuiet`.
    /// - Parameter respondBegins: tests only. Runs as a call to the shared model begins, after the summarizer's wait.
    public init(
        shared: any LanguageModel, apple: any LanguageModel, activity: ForegroundActivity, health: ModelHealth = .shared,
        pollInterval: Duration = .milliseconds(250), preemptInterval: Duration = .milliseconds(50),
        quietAfterPreemption: Duration = .seconds(2), respondBegins: (@Sendable () -> Void)? = nil
    ) {
        self.shared = shared
        self.apple = apple
        self.activity = activity
        self.health = health
        self.pollInterval = pollInterval
        self.preemptInterval = preemptInterval
        self.quietAfterPreemption = quietAfterPreemption
        self.respondBegins = respondBegins
    }

    /// No wait before the first call; after `streak` cut-short calls in a row, `base` doubled each time, capped.
    static func quietPeriod(afterPreemptions streak: Int, base: Duration) -> Duration {
        guard streak > 0 else { return .zero }
        return min(base * (1 << min(streak - 1, 16)), max(base, longestQuiet))
    }

    public var route: Route { routeState.withLock { $0 } }

    /// Called whenever the cleanup backend changes.
    public func route(for backend: EffectiveCleanupBackend) {
        let next: Route = ModelTierPolicy.meetingUsesCleanupModel(backend) ? .sharedLocal : .apple
        let changed = routeState.withLock { state -> Bool in
            defer { state = next }
            return state != next
        }
        if changed {
            Self.log.notice("meeting summaries use \(next == .sharedLocal ? "the cleanup model (local 4B)" : "apple", privacy: .public)")
        }
    }

    private var active: any LanguageModel { route == .sharedLocal ? shared : apple }

    /// Apple FM for a whole-summary rerun; nil when summaries already run on it.
    public var appleFallback: (any LanguageModel)? { route == .sharedLocal ? apple : nil }

    public var identifier: String { "meeting>\(active.identifier)" }
    public var availability: LanguageModelAvailability { active.availability }
    public var contextTokens: Int { active.contextTokens }
    public func supportsLanguage(_ languageCode: String) -> Bool { active.supportsLanguage(languageCode) }

    // Summaries never warm anything, and their calls are `isBackground`, which the MLX engine keeps out of the prefix
    // cache (`PrefixPolicy.background`), so no summary prompt evicts a dictation prompt from the shared model.
    public func prewarm(instructions: String) {}
    public func prefixCache(instructions: String) async {}
    public func warmForDictation(instructions: String) async {}

    public func yieldToForeground() async {
        guard route == .sharedLocal else { return }
        await waitForQuiet()
    }

    private func waitForQuiet() async {
        let quiet = Self.quietPeriod(afterPreemptions: preemptionStreak.withLock { $0 }, base: quietAfterPreemption)
        await activity.waitUntilQuiet(for: quiet, pollInterval: pollInterval)
    }

    public func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard route == .sharedLocal else {
            return try await apple.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
        }
        respondBegins?()
        // The summarizer waits for quiet in `yieldToForeground`, where the wait counts against its yield limit. A call
        // never waits here, so no wait can pass as a call's own time: a dictation that began since is a cut-short call,
        // and the summarizer yields again.
        if activity.isBusy { throw cutShort() }
        let model = shared, activity = activity, interval = preemptInterval
        var background = options
        background.isBackground = true
        let answer: String? = try await health.backgroundCall {
            try await withThrowingTaskGroup(of: String?.self) { [background] group in
                group.addTask { try await model.respond(instructions: instructions, prompt: prompt, schema: schema, options: background) }
                group.addTask {
                    while !activity.isBusy { try await Task.sleep(for: interval) }
                    return nil
                }
                defer { group.cancelAll() }
                // The answer, or nil when a dictation started first (leaving the scope cancels the call and waits for it to stop).
                return try await group.next() ?? nil
            }
        }
        guard let answer else { throw cutShort() }
        preemptionStreak.withLock { $0 = 0 }
        return answer
    }

    private func cutShort() -> ForegroundPreempted {
        let streak = preemptionStreak.withLock { state -> Int in state += 1; return state }
        Self.log.notice("meeting summary call gave way to a dictation (\(streak) in a row)")
        return ForegroundPreempted()
    }
}
