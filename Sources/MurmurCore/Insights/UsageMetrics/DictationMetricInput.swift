import Foundation

/// The facts about one finished dictation, as plain values, and the single place that turns them
/// into a `DictationMetricEvent`. It carries no text: the caller reduces the cleanup rejection
/// reason to a `ModelOutcome` and the transcript to a word count before building one.
public struct DictationMetricInput: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        /// Pasted into the focused app.
        case pasted
        /// Put on the clipboard instead of pasted.
        case copied
        /// Not pasted because a secure field had focus.
        case heldSecure
        /// No text field was focused.
        case noField
        /// Text was made but could not be delivered or copied; or transcription or cleanup produced nothing usable.
        case failed
        case cancelled
    }

    public let result: Result
    /// How the cleanup model fared; nil when cleanup never ran (failed or cancelled early).
    public let modelOutcome: ModelOutcome?
    public let backend: EffectiveCleanupBackend
    public let cleanupLevel: CleanupLevel
    public let mode: Mode?
    public let wordCount: Int
    public let audioSeconds: Double
    public let speechMilliseconds: Int?
    public let cleanupMilliseconds: Int?
    public let releaseToDeliveryMilliseconds: Int?
    /// Whether the model was already loaded for this dictation; nil when no model was asked.
    public let modelState: MetricsModelState?
    /// What the edit watcher later saw in the field. Unknown and not attempted until it reports.
    public let editObservation: DictationFeedback.EditObservation
    public let editCoverage: DictationFeedback.EditCoverage
    /// The tone the dictation ran with; nil when cleanup never ran.
    public let tone: MetricsTone?
    /// The kind of app it was pasted into; nil when unknown.
    public let appKind: MetricsAppKind?
    /// Words changed, once the edit watcher has found the dictation edited and measured it.
    public let editSize: MetricsEditSize?

    public init(
        result: Result, modelOutcome: ModelOutcome?, backend: EffectiveCleanupBackend, cleanupLevel: CleanupLevel,
        mode: Mode?, wordCount: Int, audioSeconds: Double, speechMilliseconds: Int?, cleanupMilliseconds: Int?,
        releaseToDeliveryMilliseconds: Int?, modelState: MetricsModelState? = nil,
        editObservation: DictationFeedback.EditObservation = .unknown,
        editCoverage: DictationFeedback.EditCoverage = .notAttempted, tone: MetricsTone? = nil,
        appKind: MetricsAppKind? = nil, editSize: MetricsEditSize? = nil
    ) {
        self.tone = tone
        self.appKind = appKind
        self.editSize = editSize
        self.modelState = modelState
        self.editObservation = editObservation
        self.editCoverage = editCoverage
        self.result = result
        self.modelOutcome = modelOutcome
        self.backend = backend
        self.cleanupLevel = cleanupLevel
        self.mode = mode
        self.wordCount = wordCount
        self.audioSeconds = audioSeconds
        self.speechMilliseconds = speechMilliseconds
        self.cleanupMilliseconds = cleanupMilliseconds
        self.releaseToDeliveryMilliseconds = releaseToDeliveryMilliseconds
    }

    /// The same dictation with the edit watcher's verdict. A verdict other than `.unknown` needs
    /// coverage `.observed` and the other way round (`DictationFeedback` enforces it in `event()`).
    public func withEdit(
        observation: DictationFeedback.EditObservation, coverage: DictationFeedback.EditCoverage,
        size: MetricsEditSize? = nil
    ) -> DictationMetricInput {
        DictationMetricInput(
            result: result, modelOutcome: modelOutcome, backend: backend, cleanupLevel: cleanupLevel, mode: mode,
            wordCount: wordCount, audioSeconds: audioSeconds, speechMilliseconds: speechMilliseconds,
            cleanupMilliseconds: cleanupMilliseconds, releaseToDeliveryMilliseconds: releaseToDeliveryMilliseconds,
            modelState: modelState, editObservation: observation, editCoverage: coverage, tone: tone,
            appKind: appKind, editSize: size)
    }

    /// Throws only if the facts contradict each other, which the call sites cannot produce.
    public func event() throws -> DictationMetricEvent {
        let delivered = result == .pasted
        let feedback = try DictationFeedback(
            delivery: Self.delivery(for: result), cleanupModelProfile: profile, fallbackReason: Self.fallback(for: modelOutcome),
            editObservation: editObservation, editCoverage: editCoverage,
            releaseToDeliveryMilliseconds: delivered ? releaseToDeliveryMilliseconds : nil)
        return DictationMetricEvent(
            feedback: feedback, cleanupLevel: cleanupLevel, modeKind: MetricsModeKind.kind(of: mode), wordCount: wordCount,
            audioMilliseconds: Int((max(0, audioSeconds) * 1_000).rounded()), speechMilliseconds: speechMilliseconds,
            cleanupMilliseconds: cleanupMilliseconds, modelState: modelState, tone: tone, appKind: appKind, editSize: editSize)
    }

    /// Which kind of cleanup shaped (or was meant to shape) the text. Never a model name or version.
    var profile: DictationFeedback.CleanupModelProfile {
        if modelOutcome == .unavailable { return .unavailable }
        switch backend {
        case .apple: return .appleSystem
        case .rules: return .rules
        case .local(let id): return ModelRegistry.entry(id: id)?.promptProfile == .compact ? .localFineTuned : .localUntuned
        }
    }

    static func delivery(for result: Result) -> DictationFeedback.Delivery {
        switch result {
        case .pasted: .succeeded
        case .copied: .copied
        case .heldSecure: .heldSecure
        case .noField: .noField
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    static func fallback(for outcome: ModelOutcome?) -> DictationFeedback.FallbackReason? {
        guard let outcome else { return nil }
        switch outcome {
        case .used: return nil
        case .notAsked: return .disabled
        case .unavailable: return .modelUnavailable
        case .rejectedByGuard: return .modelRejected
        case .skippedSlow, .breakerOpen, .timeout, .notResponding: return .modelTimedOut
        case .modelBusy: return .systemBusy
        case .thermalSerious: return .thermalPressure
        case .modelError, .refused, .releaseWindow, .prewarmLate: return .other
        }
    }
}

extension DictationMetricInput.Result {
    /// What happened to the text, from the delivery's own result. A copy is not a failure, and a
    /// refusal to paste into a password field is counted apart from both.
    public init(_ delivery: DeliveryResult) {
        switch delivery {
        case .pasted, .pastedReturnSkipped, .returnSent, .unknownConfirmed,
             .unknownConfirmedReturnSkipped, .unknownUnreadable, .unknownUnreadableReturnSkipped,
             .unknownCancelled: self = .pasted
        case .copied, .unknownNotLanded: self = .copied
        case .heldForSecureField: self = .heldSecure
        case .noField(let copied): self = copied ? .copied : .noField
        case .dispatchFailed(let copied): self = copied ? .copied : .failed
        case .returnWithheld: self = .failed
        case .cancelled: self = .cancelled
        }
    }
}
