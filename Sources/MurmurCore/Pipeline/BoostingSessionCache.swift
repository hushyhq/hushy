import Foundation

/// Where vocabulary boosting stood when one dictation asked for it. The log marker is
/// content-free (a state and a duration, never terms or text).
public enum BoostingReadiness: Sendable, Equatable {
    /// The session was already built for this vocabulary: no wait.
    case warm
    /// Not ready inside the wait bound: this dictation went out unboosted; the load carries on.
    case coldSkipped
    /// Finished while this dictation waited (inside the bound); it cost that long.
    case loaded(ms: Int)
    /// The models could not be loaded at all (missing, offline, corrupt): unboosted.
    case unavailable

    public var logMarker: String {
        switch self {
        case .warm: "boosting=warm"
        case .coldSkipped: "boosting=cold-skipped"
        case .loaded(let ms): "boosting=loaded-in \(ms) ms"
        case .unavailable: "boosting=unavailable"
        }
    }
}

/// Holds the vocabulary-boosting session so a dictation never waits seconds on a model load.
///
/// The expensive part is loading the CTC models (CoreML compile on first use, ~12 s measured);
/// building a session from loaded models for a given vocabulary is the cheap part. So the
/// models are loaded once and kept, and a vocabulary change rebuilds only the session. Anyone
/// can start the work ahead of time (`warm`); a dictation asks `session(for:waitingUpTo:)`,
/// which waits at most the bound and otherwise answers "skip" while the load carries on in the
/// background. Generic over the model and session types so the state machine is testable
/// without FluidAudio.
public actor BoostingSessionCache<Models: Sendable, Session: Sendable> {
    public typealias LoadModels = @Sendable () async -> Models?
    public typealias BuildSession = @Sendable (Models, VocabularyContext) async -> Session?

    private let loadModels: LoadModels
    private let buildSession: BuildSession

    private var models: Models?
    private var modelsTask: Task<Models?, Never>?
    private var session: Session?
    private var sessionVocabulary: VocabularyContext?
    private var buildTask: Task<Session?, Never>?
    private var buildVocabulary: VocabularyContext?

    public init(loadModels: @escaping LoadModels, buildSession: @escaping BuildSession) {
        self.loadModels = loadModels
        self.buildSession = buildSession
    }

    /// Starts building the session for `vocabulary` in the background if it isn't built (or
    /// being built) already. Returns immediately.
    public func warm(_ vocabulary: VocabularyContext) {
        _ = startBuildIfNeeded(for: vocabulary)
    }

    /// The session for exactly `vocabulary`, waiting at most `bound` for it. Never hands out a
    /// session built for different terms. A `bound` of zero means "use it only if it's ready".
    /// Whatever happens, an unfinished load keeps running for the next caller.
    public func session(for vocabulary: VocabularyContext, waitingUpTo bound: Duration) async
        -> (session: Session?, readiness: BoostingReadiness) {
        guard let task = startBuildIfNeeded(for: vocabulary) else { return (session, .warm) }
        guard bound > .zero else { return (nil, .coldSkipped) }
        let started = ContinuousClock.now
        guard let outcome = await Self.race(task, against: bound) else { return (nil, .coldSkipped) }
        guard let built = outcome else { return (nil, .unavailable) }
        let elapsed = ContinuousClock.now - started
        let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return (built, .loaded(ms: ms))
    }

    /// The session for exactly `vocabulary` if it is built already. Never starts or waits for a build, so asking
    /// early (at the key release, before the recogniser pass) cannot change what `session(for:waitingUpTo:)` decides.
    public func readySession(for vocabulary: VocabularyContext) -> Session? {
        sessionVocabulary == vocabulary ? session : nil
    }

    /// The loaded models, if the (slow) load has finished. Lets a caller that can use the models
    /// without a session (streaming) take them or skip, and lets a dictation pick its wait bound.
    public var loadedModels: Models? { models }

    /// Resolves once every load started so far has finished, or after `bound` at the latest, so
    /// a load that never finishes cannot park the caller forever. For callers that must have the
    /// result (and for tests); a dictation must use `session(for:waitingUpTo:)` instead.
    public func waitUntilIdle(upTo bound: Duration = .seconds(60)) async {
        let deadline = ContinuousClock.now + bound
        while let task = buildTask {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, await Self.race(task, against: remaining) != nil else { return }
        }
    }

    // MARK: - Internals

    /// Returns the in-flight (or newly started) build for `vocabulary`, or nil when the session
    /// for it is already in place.
    private func startBuildIfNeeded(for vocabulary: VocabularyContext) -> Task<Session?, Never>? {
        if session != nil, sessionVocabulary == vocabulary { return nil }
        if let buildTask, buildVocabulary == vocabulary { return buildTask }
        let task = Task { await self.build(vocabulary) }
        buildTask = task
        buildVocabulary = vocabulary
        return task
    }

    private func build(_ vocabulary: VocabularyContext) async -> Session? {
        guard let models = await resolveModels() else {
            finishBuild(vocabulary, with: nil)
            return nil
        }
        let built = await buildSession(models, vocabulary)
        finishBuild(vocabulary, with: built)
        return built
    }

    /// Records a finished build, unless a newer vocabulary has taken its place meanwhile.
    private func finishBuild(_ vocabulary: VocabularyContext, with built: Session?) {
        guard buildVocabulary == vocabulary else { return }
        buildTask = nil
        buildVocabulary = nil
        guard let built else { return }
        session = built
        sessionVocabulary = vocabulary
    }

    private func resolveModels() async -> Models? {
        if let models { return models }
        if let modelsTask { return await modelsTask.value }
        let task = Task { await self.loadModels() }
        modelsTask = task
        let loaded = await task.value
        modelsTask = nil
        if let loaded { models = loaded }
        return loaded
    }

    /// First of "the load finished" and "the bound elapsed". Nil = timed out; for the session
    /// build, `.some(nil)` = the load finished without a session. Leaving the race never cancels the load itself.
    /// Deliberately not a task group: a group only returns once every child has finished, and a
    /// child waiting on `task.value` ignores cancellation, so the caller would sit out the whole
    /// load (the ~13 s this type exists to avoid).
    private static func race<Value: Sendable>(_ task: Task<Value, Never>, against bound: Duration) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let once = RaceResume(continuation)
            Task { once.resume(.some(await task.value)) }
            Task {
                try? await Task.sleep(for: bound)
                once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever of two racing tasks gets there first. Shared
/// with `FallbackModelLoader`'s bounded wait.
final class RaceResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        let taken = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}
