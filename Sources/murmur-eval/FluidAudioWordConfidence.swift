import FluidAudio
import MurmurCore

/// Adapts FluidAudio's `TokenTiming` into `MurmurCore.WordConfidence` using FluidAudio's own
/// SentencePiece word-boundary helpers (`isWordBoundary`/`stripWordBoundaryPrefix`), matching
/// `SpeechEngine.wordConfidences(from:)` in the app target exactly. Duplicated (not shared)
/// because `murmur-eval` does not depend on the `Murmur` app target — same reasoning as
/// `Engine`'s independent vocabulary-boosting session in `Runners.swift`. Both call
/// `WordConfidenceAggregator.aggregate` in `MurmurCore`, so the actual aggregation logic (and
/// the min-over-pieces decision) is not duplicated, only this thin FluidAudio-specific adapter.
enum FluidAudioWordConfidence {
    static func aggregate(_ tokenTimings: [TokenTiming]) -> [WordConfidence] {
        let usable = tokenTimings.filter { !$0.token.isEmpty && $0.token != "<blank>" && $0.token != "<pad>" }
        return WordConfidenceAggregator.aggregate(
            pieces: usable.map(\.token), confidences: usable.map(\.confidence),
            isWordStart: isWordBoundary, stripBoundary: stripWordBoundaryPrefix)
    }
}
