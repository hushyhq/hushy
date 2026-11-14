import MurmurCore

/// The CPU-only work after capture stops. The raw metrics are shared by the gate, gain and log;
/// normalized metrics describe a different signal and are measured once for its log line.
struct DictationAudioAnalysis: Sendable {
    let gate: SpeechGate.Decision
    /// How much real speech the recording holds, and where (`SpeechEvidence`).
    let evidence: SpeechEvidence
    let normalized: [Float]
    let normalizedMetrics: AudioStageMetrics

    /// Whether the recording goes on to the recogniser: the speech gate's call, checked against the evidence.
    var hasSpeech: Bool { evidence.accepts(gatePassed: gate.hasSpeech) }

    static func analyze(_ samples: [Float]) -> Self {
        let metrics = AudioMetering.measure(samples)
        let gate = SpeechGate.evaluate(samples, metrics: metrics)
        let normalized = LoudnessNormalizer.normalize(samples, metrics: metrics)
        let normalizedMetrics = AudioMetering.measure(normalized)
        let evidence = SpeechEvidence(gate: gate, samples: samples, duration: Double(samples.count) / 16_000)
        return Self(gate: gate, evidence: evidence, normalized: normalized, normalizedMetrics: normalizedMetrics)
    }
}
