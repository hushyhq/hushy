import Foundation

extension MLXEngine {
    static func log(_ stats: SpeculationStats) {
        MLXLog.model.info(
            "mlx speculation passes=\(stats.forwardPasses, privacy: .public) rounds=\(stats.draftRounds, privacy: .public) drafted=\(stats.draftedTokens, privacy: .public) accepted=\(stats.acceptedDraftTokens, privacy: .public) refed=\(stats.refedTokens, privacy: .public) grammarCut=\(stats.grammarTrimmedDraftTokens, privacy: .public)")
    }
}

extension MLXLanguageModel {
    /// This call's speculation: `configuration.speculation`, or a per-call override (on uses the
    /// configured settings, or the defaults when the configuration has none).
    public func speculationSettings(override: Bool?) -> SpeculationSettings? {
        switch override {
        case nil: configuration.speculation
        case false?: nil
        case true?: configuration.speculation ?? SpeculationSettings()
        }
    }
}

extension SpeculationSettings {
    /// `HUSHY_MLX_SPECULATE`: `on` (defaults) or a maximum draft length (`8`); `off`, empty or
    /// anything else → nil (off).
    static func fromEnvironment(_ value: String?) -> SpeculationSettings? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        if value == "on" || value == "1" || value == "true" { return SpeculationSettings() }
        if let length = Int(value), length > 1 { return SpeculationSettings(maxDraftTokens: length) }
        return nil
    }
}
