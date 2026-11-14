import Foundation

/// What the fallback recogniser did for a result the drift guard flagged. The raw value is the
/// word the log carries (a state, never text).
public enum DriftFallbackOutcome: String, Sendable, Equatable {
    /// The fallback's result replaced the first recogniser's.
    case used
    /// The fallback ran and its result was not accepted: the first recogniser's result stands.
    case rejected
    /// The fallback was not loaded inside the wait bound: the first recogniser's result goes out
    /// as it is, and the load carries on for the next dictation.
    case notReady = "not_ready"
    /// The fallback could not be loaded, or failed on this audio: the first result stands.
    case failed

    /// The fallback recogniser transcribed the audio, whether or not its text was then used.
    public var ranFallback: Bool { self == .used || self == .rejected }
}

/// The step after the drift guard flags a result: ask the fallback recogniser, but never hold a
/// dictation for a model load. Generic over the model and result types so the waiting and the
/// choice can be tested without a recogniser.
public enum DriftFallbackStep {
    public struct Answer<Result: Sendable>: Sendable {
        /// What the dictation uses: the fallback's result when `outcome` is `.used`, else the first.
        public let result: Result
        public let outcome: DriftFallbackOutcome
        /// The error's own description when `outcome` is `.failed`.
        public let failure: String?
    }

    /// `primary` is the flagged result. Waits at most `bound` for the fallback model; with it,
    /// re-transcribes and keeps the fallback's result only when `accepts` says so.
    public static func run<Model: Sendable, Result: Sendable>(
        primary: Result,
        loader: FallbackModelLoader<Model>,
        waitingUpTo bound: Duration,
        transcribe: @Sendable (Model) async throws -> Result,
        accepts: @Sendable (_ primary: Result, _ fallback: Result) -> Bool
    ) async -> Answer<Result> {
        do {
            guard let model = try await loader.get(waitingUpTo: bound) else {
                return Answer(result: primary, outcome: .notReady, failure: nil)
            }
            let recovered = try await transcribe(model)
            return accepts(primary, recovered)
                ? Answer(result: recovered, outcome: .used, failure: nil)
                : Answer(result: primary, outcome: .rejected, failure: nil)
        } catch {
            return Answer(result: primary, outcome: .failed, failure: error.localizedDescription)
        }
    }
}
