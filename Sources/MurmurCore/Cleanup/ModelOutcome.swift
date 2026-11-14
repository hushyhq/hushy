import Foundation

/// Why the on-device model did or didn't shape a dictation, as one word for the log line and the
/// pill (2026-09-27: "model=false rejection=timeout or model error" couldn't tell a slow model
/// from a broken one, or either from a guard doing its job).
public enum ModelOutcome: String, Sendable, CaseIterable {
    /// The model's answer was pasted.
    case used
    /// Cleanup is off, or the rules draft is empty.
    case notAsked = "not-asked"
    /// `ModelHealth` (or `ModelPace`, for a very long draft) predicted the call would miss its
    /// budget, so it wasn't made.
    case skippedSlow = "skipped-slow"
    /// Consecutive timeouts opened `ModelHealth`'s breaker.
    case breakerOpen = "breaker-open"
    /// The call used its whole budget without answering.
    case timeout
    /// The call failed quickly (an error, not a slow model).
    case modelError = "model-error"
    /// The system wouldn't run the model right now (Apple: critical memory pressure,
    /// `ModelManagerError` 1013 / `SensitiveContentAnalysisML` 15). Transient, not slow.
    case modelBusy = "model-busy"
    /// The model's safety layer declined this text (guardrail violation or refusal).
    case refused
    /// A long dictation's group reached after the release window for model calls.
    case releaseWindow = "release-window"
    /// A streaming prewarm for this group was still running when release stopped waiting.
    case prewarmLate = "prewarm-late"
    /// Earlier calls were abandoned at their deadline and are still stuck, so no new call was started.
    case notResponding = "not-responding"
    /// No model on this Mac (Apple Intelligence off, unsupported language…).
    case unavailable
    /// The Mac is in a serious or critical thermal state.
    case thermalSerious = "thermal-serious"
    /// The model answered, but a guard or the ranker kept the rules text.
    case rejectedByGuard = "rejected-by-guard"

    public init(usedModel: Bool, rejection: String?) {
        guard !usedModel else { self = .used; return }
        guard let rejection else { self = .notAsked; return }
        self = switch rejection {
        case ModelHealth.SkipReason.skippedSlow.rawValue, "too long for model budget": .skippedSlow
        case ModelHealth.SkipReason.breakerOpen.rawValue: .breakerOpen
        case "timeout": .timeout
        case "model error": .modelError
        case "model busy": .modelBusy
        case "model refused": .refused
        case "release-window": .releaseWindow
        case "prewarm-late": .prewarmLate
        case "model not responding": .notResponding
        case "model unavailable": .unavailable
        case "thermal-serious": .thermalSerious
        default: .rejectedByGuard
        }
    }

    /// The model was wanted but no answer came (in time, or at all), so the rules text stands in
    /// for it and the pill says "as heard".
    public var isSpeedFallback: Bool {
        switch self {
        case .skippedSlow, .breakerOpen, .timeout, .modelError, .modelBusy, .refused, .releaseWindow, .prewarmLate, .thermalSerious, .notResponding: true
        case .used, .notAsked, .unavailable, .rejectedByGuard: false
        }
    }

    /// `why=` value for log lines: the outcome, plus the name of the guard that rejected it. Never the
    /// guard's own reason, which can quote the speaker's words (see `GuardCode`).
    public static func logLabel(usedModel: Bool, rejection: String?) -> String {
        let outcome = ModelOutcome(usedModel: usedModel, rejection: rejection)
        guard outcome == .rejectedByGuard, let rejection else { return outcome.rawValue }
        return "\(outcome.rawValue)(\(GuardCode(reason: rejection).rawValue))"
    }
}

extension ModelHealth.Verdict {
    /// The rejection reason to record when this verdict skips the call.
    var skipReason: String? {
        if case .skip(let reason) = self { return reason.rawValue }
        return nil
    }
}
