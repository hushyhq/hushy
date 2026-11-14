import Foundation

/// Which way an explicit voice action's extraction went, as fixed categories for the log and the
/// usage metric: never the words, a title, a name or an error message.
public enum ExtractionOutcome: String, Sendable, CaseIterable {
    case acted
    case notAnAction = "not-an-action"
    case rejectedBudget = "rejected-budget"
    case rejectedBreaker = "rejected-breaker"
    case modelError = "model-error"

    /// The outcome for an extraction result; nil for results that are not one of these five
    /// (a refusal says its own reason, an unavailable model says so on the pill).
    public init?(_ result: ActionExtractionResult) {
        switch result {
        case .actions: self = .acted
        case .notAnAction: self = .notAnAction
        case .rejected(let reason): self = Self.rejection(reason)
        case .refused, .modelUnavailable: return nil
        }
    }

    /// `ActionExtractor` words its rejections "timeout", "skipped: <gate reason>" and "model error".
    static func rejection(_ reason: String) -> ExtractionOutcome {
        if reason == "timeout" { return .rejectedBudget }
        if reason.hasPrefix("skipped") { return .rejectedBreaker }
        return .modelError
    }

    /// The usage event for an attempt that ended here. Acting is counted when the action runs, so
    /// `acted` has none. Existing categories only: a budget or breaker miss is a time-out, a model
    /// error a backend failure, "not an action" the catch-all.
    public var metric: VoiceActionMetricEvent? {
        switch self {
        case .acted: nil
        case .notAnAction: VoiceActionMetricEvent(outcome: .failed, failure: .other)
        case .rejectedBudget, .rejectedBreaker: VoiceActionMetricEvent(outcome: .failed, failure: .timedOut)
        case .modelError: VoiceActionMetricEvent(outcome: .failed, failure: .backendFailed)
        }
    }

    /// The line for the log: one fixed word.
    public var logLine: String { "action extraction: \(rawValue)" }
}
