import Foundation

/// One candidate configuration in the Tune auto-tune sweep: {model v2, ultra} x {boosting on,
/// off}. Kept independent of `AsrModelVersion`/`FluidAudio` so this file (and its tests) build
/// without FluidAudio; the app maps `TuneCandidate.model` to `AsrModelVersion` at the call site.
public struct TuneCandidate: Sendable, Equatable, Hashable {
    public enum Model: String, Sendable, CaseIterable {
        case v2, ultra
    }

    public let model: Model
    public let boosting: Bool

    public init(model: Model, boosting: Bool) {
        self.model = model
        self.boosting = boosting
    }

    /// Sweep order also used as the tie-break order: v2 (the app's current default, see
    /// .claude/DECISIONS.md) without boosting comes first, so "ties -> current default" falls
    /// out of a stable sort rather than needing a separate rule.
    public static let sweepOrder: [TuneCandidate] = [
        TuneCandidate(model: .v2, boosting: false),
        TuneCandidate(model: .v2, boosting: true),
        TuneCandidate(model: .ultra, boosting: false),
        TuneCandidate(model: .ultra, boosting: true),
    ]
}

/// One candidate's result across the 4 takes: per-sentence transcript plus whether the spoken
/// self-correction (sentence 4) was resolved correctly.
public struct TuneCandidateResult: Sendable, Equatable {
    public let candidate: TuneCandidate
    /// Transcript produced for each sentence, indexed like `TuneSentenceBuilder.build(terms:)`.
    public let transcripts: [TuneSentence.Kind: String]

    public init(candidate: TuneCandidate, transcripts: [TuneSentence.Kind: String]) {
        self.candidate = candidate
        self.transcripts = transcripts
    }
}

/// Per-sentence pass/fail plus the overall accuracy score shown on the Tune result card.
public struct TuneSentenceScore: Sendable, Equatable, Identifiable {
    public let sentence: TuneSentence
    public let transcript: String
    public let passed: Bool

    public var id: TuneSentence.Kind { sentence.id }
}

/// A word the reference expected that the best candidate still got wrong, offered to the user
/// as an "Add to dictionary" chip (heard variant as the alias).
public struct TuneMishearing: Sendable, Equatable, Identifiable {
    public let expectedWord: String
    public let heardWord: String

    public var id: String { expectedWord + "→" + heardWord }
}

/// Scores one candidate's four takes against the known sentences, and picks the best candidate
/// across the sweep. Pure and deterministic: no I/O, no ASR — callers (the app, tests) supply
/// the already-transcribed text for each candidate/sentence pair.
public enum TuneScorer {
    /// Word-level score for one sentence: exact word-sequence match (case/punctuation-tolerant,
    /// via `EvalMetrics.wordsMatch`) for the three plain sentences, and a dedicated check for
    /// the correction sentence (must land on "thirty", must not say "twenty five").
    public static func score(_ sentence: TuneSentence, transcript: String) -> TuneSentenceScore {
        let passed: Bool
        if sentence.id == .correction {
            passed = correctionResolved(transcript)
        } else {
            passed = EvalMetrics.wordsMatch(sentence.expected, transcript)
        }
        return TuneSentenceScore(sentence: sentence, transcript: transcript, passed: passed)
    }

    /// The correction sentence is right only if the final quantity is present and the
    /// superseded quantity is not — matching what `SelfCorrection` is meant to produce, not
    /// requiring the rest of the sentence to match verbatim (a reasonable rephrasing of "for the
    /// office" should not fail this check). `EvalMetrics.normalizedWords` maps number words to
    /// digits ("thirty" -> "30", "twenty" -> "20"), so the check compares digit forms.
    static func correctionResolved(_ transcript: String) -> Bool {
        let words = EvalMetrics.normalizedWords(transcript)
        return words.contains("30") && !words.contains("25") && !words.contains("20")
    }

    /// Scores every sentence for one candidate.
    public static func score(_ result: TuneCandidateResult, sentences: [TuneSentence]) -> [TuneSentenceScore] {
        sentences.map { sentence in
            score(sentence, transcript: result.transcripts[sentence.id] ?? "")
        }
    }

    /// Accuracy across a candidate's sentence scores: passed / total.
    public static func accuracy(_ scores: [TuneSentenceScore]) -> Double {
        guard !scores.isEmpty else { return 0 }
        return Double(scores.filter(\.passed).count) / Double(scores.count)
    }

    /// Picks the best candidate: highest accuracy, ties broken by `TuneCandidate.sweepOrder`
    /// (which puts the current default, v2 without boosting, first) so a genuine tie never
    /// silently switches the user onto Ultra or boosting for no measured benefit.
    public static func pickBest(
        _ results: [TuneCandidateResult], sentences: [TuneSentence]
    ) -> (candidate: TuneCandidate, scores: [TuneSentenceScore])? {
        let scored = results.map { result in (result.candidate, score(result, sentences: sentences)) }
        guard !scored.isEmpty else { return nil }
        let bestAccuracy = scored.map { accuracy($0.1) }.max() ?? 0
        // Stable: `results` (and thus `scored`) is expected in `TuneCandidate.sweepOrder`.
        guard let winner = scored.first(where: { accuracy($0.1) == bestAccuracy }) else { return nil }
        return (winner.0, winner.1)
    }

    /// One line explaining the winning choice, e.g. "English model + your names: 0 errors" or
    /// "Automatic model: fixed 1 name your terms didn't cover".
    public static func explain(_ candidate: TuneCandidate, scores: [TuneSentenceScore]) -> String {
        let modelName = candidate.model == .v2 ? "English model" : "Automatic model"
        let errors = scores.filter { !$0.passed }.count
        let suffix = candidate.boosting ? " + your names" : ""
        return errors == 0
            ? "\(modelName)\(suffix): 0 errors"
            : "\(modelName)\(suffix): \(errors) error\(errors == 1 ? "" : "s")"
    }

    /// Finds words the reference expected that the winning candidate's transcript still got
    /// wrong — offered as "Add to dictionary" chips with the heard variant as the alias.
    /// Alignment is by position after tokenizing both sides identically (`EvalMetrics`'s
    /// normalization), which is exact for these short, fixed sentences: a wrong word shows up
    /// as a substitution at the same index, not an insertion/deletion, since sentence length
    /// rarely changes for a single misheard word.
    public static func mishearings(expected: String, heard: String) -> [TuneMishearing] {
        let expectedWords = EvalMetrics.normalizedWords(expected)
        let heardWords = EvalMetrics.normalizedWords(heard)
        guard expectedWords.count == heardWords.count else { return [] }
        return zip(expectedWords, heardWords).compactMap { expected, heard in
            expected == heard ? nil : TuneMishearing(expectedWord: expected, heardWord: heard)
        }
    }
}
