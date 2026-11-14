import Foundation

/// A word's ASR confidence, aligned to its position in the transcript. Kept independent of any
/// particular ASR framework's token representation (see `SpeechEngine` for the FluidAudio
/// `TokenTiming` -> `WordConfidence` aggregation) so `MurmurCore` does not depend on FluidAudio.
public struct WordConfidence: Sendable, Equatable {
    /// The word exactly as it appears in the transcript this confidence was computed for
    /// (before rules run), lowercased alphanumeric key comparisons are done by callers.
    public let word: String
    /// 0...1, aggregated from the sub-word piece confidences that made up this word.
    public let confidence: Float

    public init(word: String, confidence: Float) {
        self.word = word
        self.confidence = confidence
    }
}

/// A word's start/end time within the audio clip it was transcribed from, in seconds relative
/// to the start of that clip. Kept independent of any particular ASR framework's token
/// representation (see `SpeechEngine` for the FluidAudio `TokenTiming` -> `WordTiming`
/// aggregation), the same design as `WordConfidence`. This is the plumbing
/// `docs/research/speaker-labeling.md` (Phase 0) calls for: word timings already exist inside
/// FluidAudio's ASR result, they just weren't being carried out of `SpeechEngine` before.
public struct WordTiming: Sendable, Equatable {
    /// The word exactly as it appears in the transcript this timing was computed for (before
    /// rules run), matching the same word segmentation `WordConfidence` uses.
    public let word: String
    /// Seconds from the start of the audio clip that was transcribed.
    public let start: Double
    /// Seconds from the start of the audio clip that was transcribed.
    public let end: Double

    public init(word: String, start: Double, end: Double) {
        self.word = word
        self.start = start
        self.end = end
    }
}

/// What a `Transcriber` returns: the text plus, when the engine can provide it, per-word
/// confidence and timing aligned to the words of `text`. `confidences`/`timings == nil` means
/// the engine does not support that signal (or it wasn't computed) — every caller must treat
/// that the same as "no confidence-guided restriction"/"no timing available", never as "every
/// word is low confidence" or "every word starts at zero".
public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    /// Recognizer text before vocabulary boosting, when boosting changed it.
    public let unboosted: String?
    public let confidences: [WordConfidence]?
    /// Per-word start/end times, clip-relative seconds, in the same word order as `text`.
    /// Present whenever the underlying ASR call produced token timings (see
    /// `SpeechEngine.transcribeWithConfidence`), regardless of whether a vocabulary was
    /// supplied — unlike `confidences`, which is dropped after vocabulary boosting because
    /// boosting can change word count/order, `timings` are computed directly from timings and
    /// kept whenever available prior to boosting.
    public let timings: [WordTiming]?

    public init(text: String, confidences: [WordConfidence]? = nil, timings: [WordTiming]? = nil, unboosted: String? = nil) {
        self.text = text
        self.unboosted = unboosted
        self.confidences = confidences
        self.timings = timings
    }
}

/// Aggregates sub-word piece confidences into word-level confidences.
///
/// FluidAudio's Parakeet models are SentencePiece-tokenized: a word like "confidence" may be
/// several pieces ("▁conf", "id", "ence"), each with its own decoder confidence. Per the
/// confidence-guided ASR correction literature (arXiv:2509.25048, arXiv:2407.21414), the
/// aggregate should reflect the *weakest* link, not the average: a single badly-recognized
/// piece is exactly the signal we want to surface, and averaging it against two confident
/// pieces in the same word would wash it out and let a genuinely uncertain word slip through
/// unmarked. Min is used deliberately over mean for this reason.
public enum WordConfidenceAggregator {
    /// Groups `pieces` into words using `isWordBoundary`/`stripWordBoundaryPrefix`-equivalent
    /// logic supplied by the caller (so this stays independent of FluidAudio's token format),
    /// and reduces each word's piece confidences with `min`.
    ///
    /// - Parameters:
    ///   - pieces: token strings in order, already stripped of blanks/pads by the caller.
    ///   - confidences: one confidence per entry in `pieces`.
    ///   - isWordStart: true when a piece begins a new word.
    ///   - stripBoundary: removes the leading word-boundary marker from a piece before it is
    ///     appended to the word text.
    public static func aggregate(
        pieces: [String], confidences: [Float], isWordStart: (String) -> Bool,
        stripBoundary: (String) -> String
    ) -> [WordConfidence] {
        guard pieces.count == confidences.count, !pieces.isEmpty else { return [] }
        var result: [WordConfidence] = []
        var currentWord = ""
        var currentMin: Float = .greatestFiniteMagnitude

        func flush() {
            let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            result.append(WordConfidence(word: trimmed, confidence: currentMin))
        }

        for (piece, confidence) in zip(pieces, confidences) {
            let startsNewWord = isWordStart(piece) || currentWord.isEmpty
            if startsNewWord, !currentWord.isEmpty {
                flush()
                currentWord = ""
                currentMin = .greatestFiniteMagnitude
            }
            currentWord += startsNewWord ? stripBoundary(piece) : piece
            currentMin = min(currentMin, confidence)
        }
        flush()
        return result
    }
}

/// Aggregates sub-word piece start/end times into word-level `WordTiming`s, using the exact
/// same word-boundary grouping as `WordConfidenceAggregator` so a word's confidence and timing
/// always refer to the same span of pieces. A word's start is its first piece's start; its end
/// is its last piece's end.
public enum WordTimingAggregator {
    /// - Parameters:
    ///   - pieces: token strings in order, already stripped of blanks/pads by the caller.
    ///   - startTimes: one clip-relative start time (seconds) per entry in `pieces`.
    ///   - endTimes: one clip-relative end time (seconds) per entry in `pieces`.
    ///   - isWordStart: true when a piece begins a new word.
    ///   - stripBoundary: removes the leading word-boundary marker from a piece before it is
    ///     appended to the word text.
    public static func aggregate(
        pieces: [String], startTimes: [Double], endTimes: [Double], isWordStart: (String) -> Bool,
        stripBoundary: (String) -> String
    ) -> [WordTiming] {
        guard pieces.count == startTimes.count, pieces.count == endTimes.count, !pieces.isEmpty else { return [] }
        var result: [WordTiming] = []
        var currentWord = ""
        var currentStart: Double = 0
        var currentEnd: Double = 0

        func flush() {
            let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            result.append(WordTiming(word: trimmed, start: currentStart, end: currentEnd))
        }

        for index in pieces.indices {
            let piece = pieces[index]
            let startsNewWord = isWordStart(piece) || currentWord.isEmpty
            if startsNewWord, !currentWord.isEmpty {
                flush()
                currentWord = ""
            }
            if currentWord.isEmpty { currentStart = startTimes[index] }
            currentWord += startsNewWord ? stripBoundary(piece) : piece
            currentEnd = endTimes[index]
        }
        flush()
        return result
    }
}
