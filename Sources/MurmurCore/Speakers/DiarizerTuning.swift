import Foundation

/// The clustering numbers the app hands FluidAudio's diarizer, kept here so the app and `murmur-eval
/// voice-match` run the same settings and cannot drift apart. History and the measurements behind them:
/// `Evals/results.md` (2026-09-26 diarization tuning) and the handbook's notes-and-meetings page.
public enum DiarizerTuning {
    /// FluidAudio's default is 0.7; lower gives more clusters.
    public static let clusteringThreshold: Float = 0.65
    /// FluidAudio's default is 1.0 s.
    public static let minSpeechDuration: Float = 0.5
}
