import Foundation

/// How much real speech a recording holds, from the speech gate's 20 ms frames (`SpeechGate.Decision.activeFrames`)
/// and, over the frames that count, whether they are voiced.
///
/// The gate asks for 5 % of the frames to be active. In a ten-second recording that is half a second, which
/// a quiet room reaches with nothing but scattered key clicks, a chair, breaths and the fan's flutter, so a long
/// hands-free recording with no one speaking passed the gate and the recogniser filled the silence with words
/// (build 2835: 20 s hands-free, nothing said, 31 words pasted). The same rule also threw away a single word said
/// in a long recording (2 % of the frames). Speech is neither scattered nor a share of the length. So this counts
/// **runs** and then asks what is in them:
///
/// - gaps shorter than `bridgeSeconds` inside a run are part of it (the stop of a "t", a breath between syllables);
/// - a run shorter than `minimumRunSeconds` is a click or a bump and counts for nothing;
/// - the runs must add up to `minimumSpeechSeconds` (the least any of the 222 speech clips and cuts measured, with
///   margin; see `EmptyDictationTriage`);
/// - and either some of their frames are voiced (a vowel: `minimumVoicedSeconds`), which clicks, typing, breaths and
///   a chair never are, or the runs are most of the recording (`unvoicedShare`), which is how a whispered
///   recording, which has no voiced frames, passes. A long recording of someone whispering one word is the one
///   thing this refuses that it should not; the voice is the evidence.
///
/// Measured with `murmur-eval empty-triage` (table in `.claude/DECISIONS.md`). The same runs say where speech is,
/// so words the recogniser puts between them can be dropped (`NonSpeechWordFilter`). Pure and cheap.
public struct SpeechEvidence: Sendable, Equatable {
    public static let frameSeconds: Double = Double(AudioMetering.frameSamples16k) / 16_000
    public static let bridgeSeconds: Double = 0.10
    public static let minimumRunSeconds: Double = 0.08
    public static let minimumSpeechSeconds: Double = 0.23
    /// Three voiced frames: the shortest vowel in a word, and more than any non-speech case measured (at most 1).
    public static let minimumVoicedSeconds: Double = 0.06
    /// Without voiced frames, the runs must be this share of the recording.
    public static let unvoicedShare: Double = 0.25

    /// A stretch of speech, in seconds from the start of the recording.
    public struct Run: Sendable, Equatable {
        public let start: Double
        public let end: Double
        public var length: Double { end - start }
    }

    public let duration: Double
    public let runs: [Run]
    /// Total length of the runs.
    public let speechSeconds: Double
    /// How much of the runs is voiced.
    public let voicedSeconds: Double

    public var share: Double { duration > 0 ? speechSeconds / duration : 0 }

    /// Under this long, the gate's own call stands (a "yeah" or "ok" said to a far microphone is shorter than
    /// the evidence needs, and a short recording has no room for scattered sounds to add up).
    public static let shortRecordingSeconds: Double = 1.0

    /// Whether the dictation goes on to the recogniser. A recording the gate passed goes on when it holds real
    /// speech, or is short. One the gate failed (under 5 % of its frames active) goes on only when its runs prove
    /// speech: a single word in a long recording.
    public func accepts(gatePassed: Bool) -> Bool {
        gatePassed ? (isSpeech || duration < Self.shortRecordingSeconds) : isSpeech
    }

    /// Whether the recording holds real speech, as described above.
    public var isSpeech: Bool {
        speechSeconds >= Self.minimumSpeechSeconds
            && (voicedSeconds >= Self.minimumVoicedSeconds || share >= Self.unvoicedShare)
    }

    /// - Parameter voiced: which frames are voiced (`VoicingFrames.measure`), or nil when not measured; then only
    ///   the runs' length and share decide (`voicedSeconds` is 0).
    public init(frames: [Bool], voiced: [Bool]? = nil, duration: Double) {
        self.duration = duration
        let step = Self.frameSeconds
        let bridge = max(1, Int((Self.bridgeSeconds / step).rounded()))
        let shortest = max(1, Int((Self.minimumRunSeconds / step).rounded()))
        var found: [Range<Int>] = []
        var start: Int?
        var lastActive = 0
        for (index, isActive) in frames.enumerated() where isActive {
            if let begun = start, index - lastActive > bridge {
                found.append(begun..<(lastActive + 1))
                start = index
            } else if start == nil {
                start = index
            }
            lastActive = index
        }
        if let begun = start { found.append(begun..<(lastActive + 1)) }
        let kept = found.filter { $0.count >= shortest }
        runs = kept.map { Run(start: Double($0.lowerBound) * step, end: Double($0.upperBound) * step) }
        speechSeconds = runs.reduce(0) { $0 + $1.length }
        let voicedFrames = voiced.map { flags in kept.reduce(0) { total, range in total + range.filter { $0 < flags.count && flags[$0] }.count } } ?? 0
        voicedSeconds = Double(voicedFrames) * step
    }

    /// Looks at voicing only when the runs are long enough to matter, so silence and clicks cost nothing.
    public init(gate: SpeechGate.Decision, samples: [Float], duration: Double) {
        let plain = SpeechEvidence(frames: gate.activeFrames, duration: duration)
        if plain.speechSeconds >= Self.minimumSpeechSeconds {
            self.init(frames: gate.activeFrames, voiced: VoicingFrames.measure(samples, active: gate.activeFrames), duration: duration)
        } else {
            self = plain
        }
    }

    /// True when `[start, end]` touches a run, allowing `margin` seconds either side (the recogniser's word
    /// times are rounded to its own frame size, and a word's soft edges can sit under the gate's bar).
    public func overlaps(start: Double, end: Double, margin: Double = 0.25) -> Bool {
        runs.contains { $0.end + margin >= start && $0.start - margin <= end }
    }
}

/// Drops the words the recogniser put where there was no speech.
public enum NonSpeechWordFilter {
    public struct Result: Equatable, Sendable {
        public let text: String
        /// How many words were left out.
        public let dropped: Int
        /// How many words the recogniser's timings could be matched to.
        public let checked: Int
    }

    /// Keeps a word when its time touches speech (`SpeechEvidence.overlaps`). The timings belong to the
    /// recogniser's own words, so they are matched against `unboosted` when vocabulary boosting changed the text,
    /// else against `text`; if they do not line up word for word nothing is touched. When the matched words are
    /// not the text itself (boosted), only the whole-text answer is safe: if no word is in speech the result is
    /// empty, otherwise the text is left as it was.
    public static func apply(text: String, unboosted: String? = nil, timings: [WordTiming]?, evidence: SpeechEvidence) -> Result {
        let unchanged = Result(text: text, dropped: 0, checked: 0)
        guard let timings, !timings.isEmpty else { return unchanged }
        let source = unboosted ?? text
        let words = source.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == timings.count, zip(words, timings).allSatisfy({ $0 == $1.word }) else { return unchanged }
        let kept = zip(words, timings).filter { evidence.overlaps(start: $0.1.start, end: $0.1.end) }.map(\.0)
        if kept.isEmpty { return Result(text: "", dropped: words.count, checked: words.count) }
        if source != text { return Result(text: text, dropped: 0, checked: words.count) }
        return Result(text: kept.joined(separator: " "), dropped: words.count - kept.count, checked: words.count)
    }
}

/// Which 20 ms frames are voiced (a vowel, a hum): the frame, seen over 40 ms around it, repeats itself at a
/// pitch period between 80 and 400 Hz. Clicks, breaths, a chair and the rushing of a fan do not. Only the frames
/// the gate called active are looked at, on the signal at 8 kHz, so a long recording costs little.
public enum VoicingFrames {
    /// Strength of the repeat (normalised autocorrelation, 0 to 1) a frame needs.
    public static let threshold: Float = 0.45

    public static func measure(_ samples: [Float], active: [Bool]) -> [Bool] {
        let frame = AudioMetering.frameSamples16k
        return active.enumerated().map { index, isActive in
            guard isActive else { return false }
            let lower = max(0, index * frame - frame / 2)
            let upper = min(samples.count, (index + 1) * frame + frame / 2)
            guard upper - lower >= 2 * frame else { return false }
            return strength(samples[lower..<upper]) >= threshold
        }
    }

    /// The best repeat between lags of 80 and 400 Hz, on the signal halved to 8 kHz.
    static func strength(_ window: ArraySlice<Float>) -> Float {
        var x: [Float] = []
        x.reserveCapacity(window.count / 2)
        var index = window.startIndex
        while index + 1 < window.endIndex { x.append(0.5 * (window[index] + window[index + 1])); index += 2 }
        let mean = x.reduce(0, +) / Float(max(1, x.count))
        for i in x.indices { x[i] -= mean }
        var best: Float = 0
        for lag in 20...100 where x.count > lag + 40 {
            var cross: Float = 0, first: Float = 0, second: Float = 0
            for n in 0..<(x.count - lag) {
                cross += x[n] * x[n + lag]
                first += x[n] * x[n]
                second += x[n + lag] * x[n + lag]
            }
            let denominator = (first * second).squareRoot()
            if denominator > 0 { best = max(best, cross / denominator) }
        }
        return best
    }
}
