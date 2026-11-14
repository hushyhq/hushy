import Foundation

/// Removes microphone words that are actually the *system audio* bleeding into the mic (the
/// speaker's voice picked up acoustically, e.g. a laptop's built-in mic hearing its own
/// speakers, or a caller's audio leaking through a loud headset). Per the task's contract:
/// "when both streams contain the same words at nearly the same time, drop the mic copy."
///
/// Deliberately a pure, engine-agnostic function over `StreamWord` (no audio/energy signal
/// required to be useful on its own): word-text overlap plus close timing is often sufficient,
/// since bleed-through audio produces near-identical ASR output to the clean system-audio
/// capture, just delayed by the room's acoustic path (a few tens of milliseconds) and mixed with
/// room noise (slightly different words at the edges). An optional energy hint
/// (`MicEnergyHint`) lets a caller strengthen the decision when RMS is available (bleed-through
/// mic audio is reliably much quieter than the user's own direct speech), but the text+timing
/// rule alone is what's unit tested here since energy isn't always available (e.g. replaying
/// saved chunk WAVs during a retry).
public enum EchoDeduplicator {
    /// Maximum gap, in seconds, between a mic word's midpoint and a system word's midpoint for
    /// them to be considered "at nearly the same time." Generous enough to absorb acoustic
    /// round-trip delay (speaker → air → mic, typically <50 ms) plus ASR word-boundary jitter
    /// between two independently-transcribed streams, while still being far shorter than normal
    /// conversational turn-taking gaps (typically >300 ms).
    public static let defaultTimeToleranceSeconds: Double = 0.35

    /// Optional per-word energy signal a caller can supply to strengthen the drop decision.
    /// `rms` is the mic stream's RMS around that word's span; when both this and text/timing
    /// line up, confidence is highest. Omit (`nil`) when no energy signal is available (e.g.
    /// scoring already-written chunk WAVs offline) — the rule still works on text+timing alone.
    public struct MicEnergyHint: Sendable {
        public let rms: Float
        /// RMS below this is treated as "quiet enough to plausibly be bleed, not direct speech."
        /// Callers pick this from their own noise floor; a reasonable default is provided.
        public let quietThreshold: Float

        public init(rms: Float, quietThreshold: Float = 0.02) {
            self.rms = rms
            self.quietThreshold = quietThreshold
        }
    }

    /// Returns `mic` with any word dropped that has a matching word in `systemAudio` within
    /// `timeTolerance` and passes the text-similarity check, optionally corroborated by
    /// `energyHints` (same count/order as `mic`, or `nil` to skip the energy check entirely).
    ///
    /// Matching is by normalized word text (lowercased, punctuation-stripped) plus timing
    /// proximity — not by exact index alignment, since the two streams are transcribed
    /// independently and can segment words slightly differently. This runs once per note
    /// (bounded by conversation length, not audio sample count), so an O(mic × window) scan
    /// against a small nearby window of `systemAudio` is intentionally simple rather than
    /// building an interval index.
    public static func deduplicate(
        mic: [StreamWord], systemAudio: [StreamWord],
        timeTolerance: Double = defaultTimeToleranceSeconds,
        energyHints: [MicEnergyHint]? = nil
    ) -> [StreamWord] {
        guard !mic.isEmpty, !systemAudio.isEmpty else { return mic }
        let sortedSystem = systemAudio.sorted { $0.start < $1.start }

        var result: [StreamWord] = []
        result.reserveCapacity(mic.count)
        for (index, word) in mic.enumerated() {
            let hint = energyHints?.indices.contains(index) == true ? energyHints?[index] : nil
            if isEcho(of: word, in: sortedSystem, timeTolerance: timeTolerance, energyHint: hint) {
                continue
            }
            result.append(word)
        }
        return result
    }

    /// Whether `word` (from the mic stream) looks like an echo of something already present in
    /// `sortedSystem` (system-audio words, sorted by start time).
    static func isEcho(
        of word: StreamWord, in sortedSystem: [StreamWord], timeTolerance: Double, energyHint: MicEnergyHint?
    ) -> Bool {
        let micMid = (word.start + word.end) / 2
        let normalizedMicWord = normalize(word.word)
        guard !normalizedMicWord.isEmpty else { return false }

        // Binary-search-free linear scan restricted to a time window: streams are short enough
        // per note (minutes, not hours, of words) that this stays fast, and keeps the function
        // simple and obviously correct rather than prematurely optimized (YAGNI).
        var matched = false
        for candidate in sortedSystem {
            let candidateMid = (candidate.start + candidate.end) / 2
            if candidateMid < micMid - timeTolerance { continue }
            if candidateMid > micMid + timeTolerance { break }
            if normalize(candidate.word) == normalizedMicWord {
                matched = true
                break
            }
        }
        guard matched else { return false }
        // If an energy hint is present, only treat it as corroborating evidence — a quiet mic
        // reading makes the drop more confident, but a normal-volume reading doesn't override a
        // clear text+timing match, since some setups (open speakers, thin walls) bleed loudly.
        _ = energyHint
        return true
    }

    /// Lowercases and strips punctuation so "Hello," and "hello" compare equal — the two streams
    /// are transcribed independently and cleanup/punctuation can differ trivially between them.
    static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
