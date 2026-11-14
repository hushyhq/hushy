import Foundation
import MurmurCore

/// Where the time goes between key release and text appearing.
struct LatencyBreakdown {
    enum Stage: String { case speech, cleanup, insert }

    let releasedAt: Date
    private var last: Date
    private var stages: [(Stage, Double)] = []

    init(releasedAt: Date) {
        self.releasedAt = releasedAt
        last = releasedAt
    }

    mutating func mark(_ stage: Stage) {
        let now = Date()
        stages.append((stage, now.timeIntervalSince(last) * 1000))
        last = now
    }

    var totalMs: Int { Int(last.timeIntervalSince(releasedAt) * 1000) }

    /// How long `stage` took, or nil if it never ran (a dictation that stopped before it).
    func milliseconds(of stage: Stage) -> Int? {
        stages.first { $0.0 == stage }.map { Int($0.1) }
    }

    /// The stage times to keep with the History entry, or nil if a stage never ran. `groups` say how much of
    /// the cleanup stage was the second pass.
    func timeSplit(groups: [GroupTrace]) -> DictationTimeSplit? {
        guard let speech = milliseconds(of: .speech), let cleanup = milliseconds(of: .cleanup),
              let insert = milliseconds(of: .insert) else { return nil }
        return DictationTimeSplit(speechMs: speech, cleanupStageMs: cleanup, insertMs: insert, groups: groups)
    }

    var summary: String {
        stages.map { "\($0.0.rawValue) \(Int($0.1)) ms" }.joined(separator: " · ") + " · total \(totalMs) ms"
    }

    /// The log's `why=`: why the model did or didn't shape this dictation (`ModelOutcome`), plus
    /// `fallback=speed` when a long dictation's earlier group fell back even though the last one
    /// didn't, and the thermal state when it isn't nominal — enough to tell a slow model from a
    /// broken one or a guard doing its job without reproducing it.
    /// The log's `breaks=`: paragraph and line breaks as "paragraphs/lines", in the model's answer and in the text delivered.
    /// Numbers only. "-" for the model when no group got an answer from it.
    static func breaksSummary(_ cleaned: SmartCleaner.Output) -> String {
        let answers = cleaned.groups.compactMap(\.answerBreaks)
        let model = answers.isEmpty ? "-" : answers.dropFirst().reduce(answers[0], +).logSummary
        return "model:\(model) final:\(LineBreakCount(of: cleaned.text).logSummary)"
    }

    static func modelWhy(_ cleaned: SmartCleaner.Output) -> String {
        var why = ModelOutcome.logLabel(usedModel: cleaned.usedModel, rejection: cleaned.rejection)
        let lastWasSpeed = ModelOutcome(usedModel: cleaned.usedModel, rejection: cleaned.rejection).isSpeedFallback
        if cleaned.speedFallback, !lastWasSpeed { why += " fallback=speed" }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != .nominal { why += " thermal=\(thermal.logName)" }
        return why
    }
}

private extension ProcessInfo.ThermalState {
    var logName: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
