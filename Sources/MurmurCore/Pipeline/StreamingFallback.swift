import Foundation

/// The pure decision `DictationController.process` applies to decide whether to use a streamed
/// transcript or fall back to whole-utterance transcription — pulled out as its own type so the
/// rule itself ("if nothing was finalized by release, fall back automatically") is unit-testable
/// without needing a real `SpeechEngine`/`StreamingDictationSession` (both require a loaded
/// Parakeet model and cannot be faked cheaply in a unit test).
///
/// The rule: a dictation only ever used streaming if a `StreamingDictationSession` was actually
/// started for it (long enough to pass `StreamingDictationSession.activationThreshold`) *and*
/// that session produced a non-nil, non-empty result once asked to finish. Every other case —
/// streaming never activated (short dictation), or it activated but `stop()` returned `nil`
/// (FluidAudio failed, or nothing was ever confirmed before release) — must fall back to
/// whole-utterance transcription automatically, so a dictation can never come back with no text
/// just because streaming didn't pan out. This mirrors (and is used directly by)
/// `DictationController.process`'s `if let streamingSession = ..., let streamed = await
/// streamingSession.stop(...) { … } else { … whole-utterance … }` branch.
///
/// Since 2026-10-12 the app has no streamed transcript to choose: what runs while speaking (`EarlyCleanupSession`)
/// only cleans groups ahead and the text always comes from one pass over the whole recording. Nothing in the app
/// calls this any more; it is kept with its tests until someone decides to remove it.
public enum StreamingFallback {
    /// Measured 2026-09-26 (DECISIONS.md, "streaming for all dictations"): a single
    /// whole-utterance pass at release is both faster (120 s: ~0.4 s vs ~0.8 s) and more
    /// accurate (120 s WER 4.4% vs 7.2%) than the streamed transcript. So the *final* text
    /// always comes from the whole-utterance pass; streaming still runs during recording, but
    /// only to clean finished sentence groups early (SmartCleaner.prewarmGroup), which is where
    /// the real latency was.
    public static let finalTextFromWholeUtterance = true

    /// Which transcription source `DictationController.process` should use.
    public enum Source: Sendable, Equatable {
        /// Use `streamed`'s text/confidences as-is; no whole-utterance call is made.
        case streamed(TranscriptionResult)
        /// No usable streamed result — run (or already ran) whole-utterance transcription.
        case wholeUtterance
    }

    /// - Parameters:
    ///   - streamingActivated: whether a `StreamingDictationSession` was started for this
    ///     recording at all (i.e. it ran long enough to pass `activationThreshold`). A
    ///     recording that never activated streaming has no session to ask, and always falls
    ///     back — this is the common case for ordinary short dictations, which must behave
    ///     identically to how they did before streaming existed.
    ///   - streamedResult: the result of calling `stop(tail:cancelled:)` on the session, if one
    ///     was activated. `nil` covers every failure mode `stop` can return `nil` for: FluidAudio
    ///     failed outright, or the session never confirmed any text at all before release (a
    ///     recording that crossed the activation threshold but the user then released almost
    ///     immediately after, before a single window could be confirmed).
    public static func decide(
        streamingActivated: Bool, streamedResult: TranscriptionResult?, preferWholeUtterance: Bool = false
    ) -> Source {
        guard !preferWholeUtterance, streamingActivated, let streamedResult else { return .wholeUtterance }
        return .streamed(streamedResult)
    }
}
