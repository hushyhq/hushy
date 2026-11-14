import Foundation

/// Honest, from-data summary chips for one dictation's cleanup — e.g. "2 fillers removed",
/// "“uh” removed", "1 correction", "1 number". Deliberately does NOT attempt to name a
/// before/after word pair (the old `DictationDiff.substitution` chip, e.g. "“like” → “doing”"):
/// `WordDiff`'s LCS alignment only tells us which original words were dropped, not which
/// remaining word "replaced" them, so a positional guess reads as confident but is often wrong.
/// These chips only ever state a fact `WordDiff.keptFlags` can support directly: how many words
/// were removed, and — when exactly one was removed and it's a recognizable filler — which one.
public enum TimelineChips {
    /// A short, human list of dropped words that read as fillers ("um", "uh", "like", "you
    /// know", etc.) — checked against the removed words themselves, not guessed from position.
    private static let fillerWords: Set<String> = [
        "um", "uh", "umm", "uhh", "erm", "hmm", "like", "actually", "basically", "literally",
        "so", "well", "okay", "right", "anyway", "kind", "sort",
    ]

    /// Words that mark a self-correction ("ten, no, nine" / "call bob, actually sarah") — a
    /// contiguous run of removed words containing one of these is counted as a single
    /// correction *event*, not one correction per removed word, since the whole run is one act
    /// of "no wait, I meant X" rather than several independent edits.
    private static let correctionCues: Set<String> = [
        "no", "actually", "sorry", "wait", "scratch", "meant",
    ]

    /// One chip per honest category, in a fixed, stable order: fillers first, then a named
    /// single filler, then correction events, then numbers. At most a small handful of chips so
    /// a row never looks noisy.
    public static func chips(rawText: String, cleanedText: String) -> [String] {
        guard rawText != cleanedText, !rawText.isEmpty else { return [] }
        let kept = WordDiff.keptFlags(original: rawText, cleaned: cleanedText)
        let originalWords = WordDiff.words(rawText)
        let removedKeys = zip(originalWords, kept).map { WordDiff.key($0.0) }
        let removedRuns = contiguousRemovedRuns(kept: kept, keys: removedKeys)

        guard !removedRuns.isEmpty else { return [] }

        // Split runs into correction events (contain a correction cue) vs. plain removals,
        // which get bucketed as fillers or, if unrecognized, counted individually.
        let correctionRuns = removedRuns.filter { run in run.contains { correctionCues.contains($0) } }
        let plainRuns = removedRuns.filter { run in !run.contains { correctionCues.contains($0) } }
        let plainWords = plainRuns.flatMap { $0 }

        let removedFillers = plainWords.filter { fillerWords.contains($0) }
        let removedOther = plainWords.filter { !fillerWords.contains($0) }
        let containsNumber = removedOther.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil }
            || numberWordsChanged(original: rawText, cleaned: cleanedText)

        var labels: [String] = []

        if removedFillers.count == 1, removedOther.isEmpty {
            labels.append("“\(removedFillers[0])” removed")
        } else if removedFillers.count > 1 {
            labels.append("\(removedFillers.count) filler\(removedFillers.count == 1 ? "" : "s") removed")
        }

        // Each correction *run* is one correction event, regardless of how many words it spans
        // ("ten, no, nine" is one self-correction, not three). Non-cue leftover removals that
        // aren't fillers still count as individual corrections.
        let correctionCount = correctionRuns.count + removedOther.count
        if correctionCount > 0 {
            labels.append("\(correctionCount) correction\(correctionCount == 1 ? "" : "s")")
        }

        if containsNumber {
            labels.append("1 number")
        }

        return labels
    }

    /// Groups the indices of removed (non-kept, non-empty-token) words into contiguous runs,
    /// preserving each run's words in order — the unit a correction is judged over, since a
    /// self-correction phrase ("ten, no, nine") is removed as one adjacent block.
    private static func contiguousRemovedRuns(kept: [Bool], keys: [String]) -> [[String]] {
        var runs: [[String]] = []
        var current: [String] = []
        for (isKept, key) in zip(kept, keys) {
            if !isKept, !key.isEmpty {
                current.append(key)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// True when a number-shaped token changed between the two texts (e.g. "nine" -> "9",
    /// "10" -> "ten") — a coarse signal, but only used to add the "1 number" chip, never to
    /// name the specific before/after values.
    private static func numberWordsChanged(original: String, cleaned: String) -> Bool {
        let numberTokens: Set<String> = [
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        ]
        let originalHasNumberWord = WordDiff.words(original).map(WordDiff.key).contains { numberTokens.contains($0) }
        let cleanedHasDigit = cleaned.rangeOfCharacter(from: .decimalDigits) != nil
        return originalHasNumberWord && cleanedHasDigit
    }
}
