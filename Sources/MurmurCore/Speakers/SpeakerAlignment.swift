import Foundation

/// One contiguous speaker turn from a diarizer, note-relative seconds. Framework-agnostic
/// mirror of FluidAudio's `TimedSpeakerSegment` (`Diarizer/Core/DiarizerTypes.swift`) — kept
/// independent here so `MurmurCore` does not depend on FluidAudio, matching the existing
/// `Transcriber`/`WordConfidence` pattern.
public struct DiarizationTurn: Sendable, Equatable {
    /// Diarizer-assigned speaker id for this note, e.g. "S1"/"S2" (FluidAudio's own format).
    /// Stable only within a single diarization run over one note.
    public let speakerLabel: String
    public let start: Double
    public let end: Double

    public init(speakerLabel: String, start: Double, end: Double) {
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
    }
}

/// One contiguous run of same-speaker words, ready to persist as a `note_segment` row (see
/// `Store`/`Models.swift`). `text` is the joined words, in order.
public struct AlignedSegment: Sendable, Equatable {
    public let speakerLabel: String
    public let start: Double
    public let end: Double
    public let text: String

    public init(speakerLabel: String, start: Double, end: Double, text: String) {
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Aligns ASR word timings to diarization speaker turns, per
/// docs/research/speaker-labeling.md §2.2: each word is assigned to the turn whose interval
/// covers its midpoint; consecutive same-speaker words are merged into one segment. A pure
/// function (no I/O, no FluidAudio dependency) so it's unit-testable in isolation from both the
/// ASR and diarization engines.
public enum SpeakerAlignment {
    /// Assigns each word to the diarization turn covering its midpoint, then merges consecutive
    /// same-speaker words into segments.
    ///
    /// - Words are assumed already in time order (`NoteRecorder` appends them in chunk order,
    ///   which is time order); this does not re-sort them, matching `WordTiming`'s existing
    ///   contract elsewhere in the pipeline.
    /// - A word whose midpoint falls in a gap between turns (no turn covers it) is assigned to
    ///   the *nearest* turn (by distance from the word's midpoint to the turn's nearest edge),
    ///   per the research doc's gap-handling guidance — never dropped.
    /// - A word whose midpoint falls inside two overlapping turns is assigned to whichever turn
    ///   has the larger overlap around that word's own span (research doc §2.2's overlap rule);
    ///   ties break toward the turn that starts earlier, for determinism.
    /// - If `turns` is empty (single-speaker fallback, or diarization found nothing), every word
    ///   becomes one segment with speaker label `singleSpeakerFallbackLabel`.
    public static func align(
        words: [WordTiming], turns: [DiarizationTurn],
        singleSpeakerFallbackLabel: String = "S1"
    ) -> [AlignedSegment] {
        guard !words.isEmpty else { return [] }
        guard !turns.isEmpty else {
            return [mergedSegment(words: words, speakerLabel: singleSpeakerFallbackLabel)]
        }

        let labeledWords = Array(zip(words, labels(words: words, turns: turns, singleSpeakerFallbackLabel: singleSpeakerFallbackLabel)))

        var segments: [AlignedSegment] = []
        var runWords: [WordTiming] = []
        var runLabel: String?
        func flush() {
            guard let runLabel, !runWords.isEmpty else { return }
            segments.append(mergedSegment(words: runWords, speakerLabel: runLabel))
            runWords = []
        }
        for (word, label) in labeledWords {
            if let runLabel, runLabel != label {
                flush()
            }
            runLabel = label
            runWords.append(word)
        }
        flush()
        return segments
    }

    /// Each word's speaker label, by the same rules as `align` (midpoint, larger overlap, nearest
    /// turn across a gap), in the words' order. Every word gets one; none is dropped.
    public static func labels(
        words: [WordTiming], turns: [DiarizationTurn], singleSpeakerFallbackLabel: String = "S1"
    ) -> [String] {
        guard !turns.isEmpty else { return words.map { _ in singleSpeakerFallbackLabel } }
        let sortedTurns = turns.sorted { $0.start < $1.start }
        return words.map { word in
            speakerLabel(forMidpoint: (word.start + word.end) / 2, wordStart: word.start, wordEnd: word.end, in: sortedTurns)
        }
    }

    private static func mergedSegment(words: [WordTiming], speakerLabel: String) -> AlignedSegment {
        AlignedSegment(
            speakerLabel: speakerLabel,
            start: words.first?.start ?? 0,
            end: words.last?.end ?? 0,
            text: words.map(\.word).joined(separator: " ")
        )
    }

    /// Turns covering `midpoint`, given `sortedTurns` (must be sorted by `start`).
    private static func coveringTurns(midpoint: Double, in sortedTurns: [DiarizationTurn]) -> [DiarizationTurn] {
        sortedTurns.filter { $0.start <= midpoint && midpoint <= $0.end }
    }

    private static func speakerLabel(
        forMidpoint midpoint: Double, wordStart: Double, wordEnd: Double, in sortedTurns: [DiarizationTurn]
    ) -> String {
        let covering = coveringTurns(midpoint: midpoint, in: sortedTurns)
        if covering.count == 1 {
            return covering[0].speakerLabel
        }
        if covering.count > 1 {
            // Overlap: pick the turn with the larger overlap against this word's own span,
            // breaking ties toward the earlier-starting turn for determinism.
            return covering
                .max {
                    let lhsOverlap = overlap(wordStart: wordStart, wordEnd: wordEnd, turn: $0)
                    let rhsOverlap = overlap(wordStart: wordStart, wordEnd: wordEnd, turn: $1)
                    if lhsOverlap != rhsOverlap { return lhsOverlap < rhsOverlap }
                    return $0.start > $1.start
                }!.speakerLabel
        }
        // Gap: no turn covers the midpoint — assign to the nearest turn by edge distance.
        return sortedTurns
            .min { distance(midpoint: midpoint, turn: $0) < distance(midpoint: midpoint, turn: $1) }!
            .speakerLabel
    }

    private static func overlap(wordStart: Double, wordEnd: Double, turn: DiarizationTurn) -> Double {
        max(0, min(wordEnd, turn.end) - max(wordStart, turn.start))
    }

    private static func distance(midpoint: Double, turn: DiarizationTurn) -> Double {
        if midpoint < turn.start { return turn.start - midpoint }
        if midpoint > turn.end { return midpoint - turn.end }
        return 0
    }
}
