import Foundation

/// One contiguous run of same-speaker words in the interleaved, two-channel transcript. Distinct
/// from `AlignedSegment` (which is mic-only, diarization-derived) because a two-channel note's
/// segments can be attributed two different ways: `.you` from the mic stream directly (no
/// diarization needed — it's *always* the user), or `.speaker` from running `SpeakerDiarizer` on
/// the system-audio stream alone.
public enum SegmentSpeaker: Sendable, Equatable {
    /// The note owner, speaking into the mic. `name` is the display name from Settings
    /// (`AppSettings.userName`), or `nil` to fall back to the generic "You" label.
    case you(name: String?)
    /// A diarized participant heard on the system-audio (call) stream. `index` is 1-based, in
    /// first-appearance order, matching the existing single-stream "Speaker 1/2/…" convention
    /// (see `SpeakerDiarizer.orderedDistinctLabels`).
    case speaker(index: Int)

    /// The label as shown in the transcript UI.
    public var label: String {
        switch self {
        case .you(let name): name?.isEmpty == false ? name! : "You"
        case .speaker(let index): "Speaker \(index)"
        }
    }
}

/// One contiguous same-speaker run in the final interleaved transcript, in note-relative time.
public struct InterleavedSegment: Sendable, Equatable {
    public let speaker: SegmentSpeaker
    public let start: Double
    public let end: Double
    public let text: String

    public init(speaker: SegmentSpeaker, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Builds a single, time-ordered transcript from two independently-transcribed streams — the
/// mic (always "You") and system audio (diarized into "Speaker 1/2/…") — per the task's
/// contract: "build the note transcript by interleaving by word timings."
///
/// A pure function over already-computed word timings and (optional) diarization turns for the
/// system stream; it does no ASR or diarization itself, matching the existing
/// `SpeakerAlignment`/`DiarizationErrorRate` pattern of keeping the merge logic testable without
/// a live model.
public enum StreamInterleaver {
    /// Interleaves `micWords` (attributed to `.you`) and `systemWords` (attributed via
    /// `systemTurns`, diarized speaker turns over the system-audio stream only) into one
    /// note-relative transcript, ordered by start time, with consecutive same-speaker words
    /// merged into segments exactly like `SpeakerAlignment.align`.
    ///
    /// - `micWords` should already have echo/bleed removed (see `EchoDeduplicator`) — this
    ///   function does not deduplicate; it only orders and groups.
    /// - `systemTurns` empty means system audio produced no diarization (e.g. no call audio was
    ///   present, or diarization failed) — every system word then falls back to a single
    ///   `.speaker(index: 1)`, mirroring `SpeakerAlignment`'s own single-turn fallback so a
    ///   two-channel note degrades gracefully to "You" + one generic "Speaker 1" rather than
    ///   losing the system audio's words entirely.
    /// - `youName` is passed straight into every `.you` segment's `SegmentSpeaker.you(name:)`.
    public static func interleave(
        micWords: [WordTiming], systemWords: [WordTiming], systemTurns: [DiarizationTurn],
        youName: String?
    ) -> [InterleavedSegment] {
        let micStreamWords = micWords.map { StreamWord(timing: $0, stream: .microphone) }
        let systemAligned = systemWords.isEmpty
            ? []
            : SpeakerAlignment.align(words: systemWords, turns: systemTurns, singleSpeakerFallbackLabel: "S1")
        let systemLabelToIndex = orderedSpeakerIndex(for: systemAligned.map(\.speakerLabel))

        // Build one flat, time-ordered list of (speaker, word) pairs so runs can be merged
        // across stream boundaries by actual time rather than by processing one stream fully
        // before the other — two people talking over each other should interleave correctly.
        struct Tagged { let speaker: SegmentSpeaker; let word: WordTiming }
        var tagged: [Tagged] = micStreamWords.map {
            Tagged(speaker: .you(name: youName), word: WordTiming(word: $0.word, start: $0.start, end: $0.end))
        }
        for segment in systemAligned {
            let index = systemLabelToIndex[segment.speakerLabel] ?? 1
            // AlignedSegment merges words into text; split back into a synthetic single "word"
            // spanning the segment so ordering-by-time still works without needing the original
            // per-word timings of the system stream at this stage. Segments from
            // `SpeakerAlignment` are already time-ordered runs of one speaker, so treating each
            // as one unit preserves correct interleaving against mic words.
            tagged.append(Tagged(
                speaker: .speaker(index: index),
                word: WordTiming(word: segment.text, start: segment.start, end: segment.end)))
        }
        tagged.sort { $0.word.start < $1.word.start }

        var result: [InterleavedSegment] = []
        var runWords: [String] = []
        var runSpeaker: SegmentSpeaker?
        var runStart: Double = 0
        var runEnd: Double = 0
        func flush() {
            guard let runSpeaker, !runWords.isEmpty else { return }
            result.append(InterleavedSegment(
                speaker: runSpeaker, start: runStart, end: runEnd, text: runWords.joined(separator: " ")))
            runWords = []
        }
        for item in tagged {
            if let runSpeaker, runSpeaker == item.speaker {
                runWords.append(item.word.word)
                runEnd = max(runEnd, item.word.end)
            } else {
                flush()
                runSpeaker = item.speaker
                runWords = [item.word.word]
                runStart = item.word.start
                runEnd = item.word.end
            }
        }
        flush()
        return result
    }

    /// Renders `segments` as the flat transcript string stored on `Note.transcript` (for
    /// backward compatibility with everything that reads a plain string — summarization,
    /// export, search), prefixing each segment with its speaker label.
    public static func renderTranscript(_ segments: [InterleavedSegment]) -> String {
        segments.map { "\($0.speaker.label): \($0.text)" }.joined(separator: "\n")
    }

    private static func orderedSpeakerIndex(for labels: [String]) -> [String: Int] {
        var seen = Set<String>()
        var ordered: [String] = []
        for label in labels where !seen.contains(label) {
            seen.insert(label)
            ordered.append(label)
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0 + 1) })
    }
}

extension SegmentSpeaker: Hashable {
    public static func == (lhs: SegmentSpeaker, rhs: SegmentSpeaker) -> Bool {
        switch (lhs, rhs) {
        case (.you(let a), .you(let b)): a == b
        case (.speaker(let a), .speaker(let b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .you(let name):
            hasher.combine(0)
            hasher.combine(name)
        case .speaker(let index):
            hasher.combine(1)
            hasher.combine(index)
        }
    }
}
