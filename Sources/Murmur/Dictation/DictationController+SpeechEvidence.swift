import MurmurCore
import os

extension DictationController {
    private static let evidenceLog = Logger(subsystem: "app.hushy", category: "speech-evidence")

    /// The recogniser's answer without the words it put where nothing was said. A long recording with one
    /// sentence in it can still come back with words in the quiet stretches (the recogniser fills silence);
    /// each word's time is checked against the stretches the speech gate called speech. Counts only are logged.
    func keepingWordsInSpeech(_ result: TranscriptionResult, evidence: SpeechEvidence) -> TranscriptionResult {
        let filtered = NonSpeechWordFilter.apply(
            text: result.text, unboosted: result.unboosted, timings: result.timings, evidence: evidence)
        guard filtered.dropped > 0 else { return result }
        Self.evidenceLog.notice("words outside speech dropped: \(filtered.dropped) of \(filtered.checked)")
        // Counts and order no longer match the per-word data, so it goes with them.
        return TranscriptionResult(text: filtered.text)
    }
}
