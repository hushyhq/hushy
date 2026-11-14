import Foundation

/// Marks low-confidence words in the rules-cleaned draft before it is sent to the model, and
/// strips the markers back out of the model's answer. The delimiter is `⟦…⟧` (U+27E6/U+27E7,
/// MATHEMATICAL LEFT/RIGHT WHITE SQUARE BRACKET): visually unambiguous, never appears in normal
/// dictation, and — unlike `[[…]]` or `**…**` — is not Markdown/wiki-link syntax the model might
/// be tempted to "helpfully" preserve, escape or interpret rather than treat as a plain marker.
public enum ConfidenceSpans {
    static let open: Character = "⟦"
    static let close: Character = "⟧"

    /// Confidences are computed against the *raw* ASR transcript, but the model is shown the
    /// *rules-cleaned* draft (fillers removed, self-corrections resolved, ITN applied) — the two
    /// word sequences differ. Re-aligns the raw transcript's low-confidence words onto the draft
    /// using the same LCS word-alignment vocabulary boosting already relies on (`BoostGuard.align`)
    /// rather than assuming position-for-position correspondence. A raw word that rules deleted
    /// contributes nothing (there is nothing left in the draft to mark); a raw word that survives
    /// unchanged in the draft carries its confidence over via the alignment's `.same` runs.
    static func lowConfidenceWords(in draft: String, raw: String, confidences: [WordConfidence]) -> Set<String> {
        guard !confidences.isEmpty else { return [] }
        let threshold = Calibration.threshold
        let lowRawKeys = Set(confidences.filter { $0.confidence < threshold }.map { BoostGuard.key($0.word) })
        guard !lowRawKeys.isEmpty else { return [] }

        let rawTokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let draftTokens = draft.split(whereSeparator: \.isWhitespace).map(String.init)
        let rawKeys = rawTokens.map(BoostGuard.key)
        let draftKeys = draftTokens.map(BoostGuard.key)

        var marked: Set<String> = []
        for region in BoostGuard.align(rawKeys, draftKeys) {
            switch region {
            case .same(let range):
                // These draft words are verbatim survivors of the matching raw words (by key),
                // so a low-confidence raw word here marks the same word in the draft.
                for index in range where lowRawKeys.contains(draftKeys[index]) {
                    marked.insert(draftKeys[index])
                }
            case .changed(let oldRange, let newRange):
                // Rules rewrote this span (e.g. ITN "nine" -> "9", filler removal). If any raw
                // word feeding the rewrite was low confidence, conservatively mark every draft
                // word produced from it — we cannot know which output word inherited the
                // uncertainty, and marking a few extra words the model is free to leave alone
                // is far cheaper than silently losing the signal.
                let anyLow = oldRange.contains { lowRawKeys.contains(rawKeys[$0]) }
                if anyLow {
                    for index in newRange where !draftKeys[index].isEmpty { marked.insert(draftKeys[index]) }
                }
            }
        }
        return marked
    }

    /// Wraps each draft word whose key is in `lowConfidenceWords` with the delimiter, preserving
    /// all original whitespace/punctuation around it.
    static func mark(_ draft: String, lowConfidenceWords: Set<String>) -> String {
        guard !lowConfidenceWords.isEmpty else { return draft }
        let tokens = draft.split(whereSeparator: \.isWhitespace).map(String.init)
        let marked = tokens.map { token -> String in
            lowConfidenceWords.contains(BoostGuard.key(token)) ? "\(open)\(token)\(close)" : token
        }
        return marked.joined(separator: " ")
    }

    /// Removes the delimiter characters from the model's answer (it is instructed to do this
    /// itself, but stripping defensively means a model that forgets never leaks the marker into
    /// pasted text).
    static func strip(_ text: String) -> String {
        String(text.filter { $0 != open && $0 != close })
    }

    /// The low-confidence threshold and how it was chosen — see
    /// `docs/research/confidence-threshold-calibration.md` for the curve this was read off.
    public enum Calibration {
        /// Word confidences (FluidAudio TDT decoder, min-aggregated over sub-word pieces) below
        /// this are marked. Calibrated on `librispeech-other` + `commonvoice-spontaneous`
        /// (`murmur-eval confidence-calibrate --model v2 --limit 150`): 0.86 marks 13.2% of all
        /// words (combined) while covering 50.3% of actually-wrong words — the best coverage
        /// available while staying under the ~15% marking-rate ceiling from the calibration
        /// brief. See `docs/research/confidence-threshold-calibration.md` for the full
        /// precision/coverage table across candidate thresholds and why 0.86 (not a lower,
        /// higher-coverage threshold) was chosen.
        public static let threshold: Float = 0.86
    }
}
