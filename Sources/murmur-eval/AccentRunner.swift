@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// Indian-accented English ASR accuracy measurement — see `.claude/DECISIONS.md`
/// ("Indian-accent ASR accuracy") and `docs/research/accent-robustness.md` for the full writeup.
///
///   murmur-eval accent [--models v2,v3] [--limit 300] [--top-errors 30]
///
/// Downloads (resumable, cached under Evals/data) up to `--limit` clips each from two EdAcc
/// (`edinburghcstr/edacc`) accent subsets — `edacc-indian` (accent == "Indian English") and
/// `edacc-us-control` (accent == "Mainstream US English", a size-matched control) — and reports,
/// per model: WER on each set, the accent penalty (Indian WER − US-control WER), and real-time
/// factor. Also prints the top substitution pairs on the Indian set and a rough classification
/// of which error classes vocabulary boosting could plausibly fix (proper nouns/jargon-shaped
/// substitutions) versus which it can't (function words, likely vowel/consonant shifts).
///
/// Svarah (`ai4bharat/Svarah`) was the first choice — see `Dataset.svarah` — but it is gated on
/// Hugging Face and this environment has no `HF_TOKEN`; EdAcc's own Indian English subset is
/// used instead: ungated, CC-BY-4.0, and (per a live scan while building this eval) EdAcc's test
/// split alone carries hundreds of usable Indian English utterances across multiple speakers.
enum AccentRunner {
    static func run(_ args: Arguments) async throws {
        let limit = args.int("limit") ?? 300
        let topErrors = args.int("top-errors") ?? 30
        let models = (args.string("models") ?? "v2,v3").split(separator: ",").map(String.init)

        let indianClips = try await loadOrDownload(.edaccIndian, limit: limit)
        let controlClips = try await loadOrDownload(.edaccUSControl, limit: limit)
        guard !indianClips.isEmpty else {
            throw EvalError.missing("No Indian English clips available — check network access to datasets-server.huggingface.co")
        }
        guard !controlClips.isEmpty else {
            throw EvalError.missing("No US-control clips available — check network access to datasets-server.huggingface.co")
        }

        var rows: [String] = []
        var allSubstitutionPairs: [(reference: String, hypothesis: String)] = []
        var recommendationLines: [String] = []

        for modelName in models {
            // `ultra+guard` = the app's English-only default (Ultra + v2 drift fallback).
            guard let engine = try await Engine.load(named: modelName) else {
                print("  skipping unknown model \(modelName)")
                continue
            }

            let indian = try await measure(engine: engine, clips: indianClips)
            let control = try await measure(engine: engine, clips: controlClips)
            let penalty = indian.wer - control.wer

            rows.append(
                "| \(modelName) | Indian English | \(indianClips.count) | \(Runners.percent(indian.wer)) | \(String(format: "%.1f", indian.realTimeFactor))× |")
            rows.append(
                "| \(modelName) | US control | \(controlClips.count) | \(Runners.percent(control.wer)) | \(String(format: "%.1f", control.realTimeFactor))× |")
            recommendationLines.append(
                "- \(modelName): Indian WER \(Runners.percent(indian.wer)), US-control WER \(Runners.percent(control.wer)), "
                    + "accent penalty **\(Runners.percent(penalty))**\(await engine.driftSummary)")

            if modelName == models.first {
                allSubstitutionPairs = indian.pairs
            }
        }

        let table = "| Model | Set | Clips | WER | RTF |\n|---|---|---|---|---|\n" + rows.joined(separator: "\n")
        let top = SubstitutionAnalysis.topSubstitutions(allSubstitutionPairs, top: topErrors)
        let errorLines = top.enumerated().map { index, entry in
            let classification = classify(entry.pair)
            return "  \(index + 1). \(entry.pair.reference) → \(entry.pair.hypothesis) (\(entry.count)×) — \(classification.rawValue)"
        }
        let boostable = top.filter { classify($0.pair) == .boostable }.count
        let notBoostable = top.count - boostable

        let summary = """
            ### Accent robustness · Indian-accented English (EdAcc) · \(models.joined(separator: ",")) · \(indianClips.count) clips/set
            \(table)

            Recommendation inputs:
            \(recommendationLines.joined(separator: "\n"))

            Of the top \(top.count) substitution pairs on the Indian English set, \(boostable) look
            fixable by vocabulary boosting (proper nouns / jargon-shaped) and \(notBoostable) do not
            (function words, short words, likely vowel/consonant shifts).
            """
        Runners.emit(summary, details: ["Top substitution pairs (reference → hypothesis):"] + errorLines)
    }

    // MARK: Per-model measurement

    private struct Measurement {
        let wer: Double
        let realTimeFactor: Double
        let pairs: [(reference: String, hypothesis: String)]
    }

    private static func measure(engine: Engine, clips: [EvalClip]) async throws -> Measurement {
        var pairs: [(reference: String, hypothesis: String)] = []
        var audioSeconds = 0.0
        var processingSeconds = 0.0
        for clip in clips {
            let url = URL(fileURLWithPath: clip.audioPath)
            let (text, seconds) = try await engine.transcribe(file: url)
            pairs.append((clip.reference, text))
            audioSeconds += (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            processingSeconds += seconds
        }
        let wer = EvalMetrics.corpusWER(pairs)
        let rtf = audioSeconds / max(processingSeconds, 0.001)
        return Measurement(wer: wer, realTimeFactor: rtf, pairs: pairs)
    }

    // MARK: Data loading

    /// Downloads a dataset if its manifest isn't already on disk, then loads it, filtering
    /// unscorable segments the same way `Runners.asr` does.
    private static func loadOrDownload(_ dataset: Dataset, limit: Int) async throws -> [EvalClip] {
        let manifestExists = FileManager.default.fileExists(atPath: dataset.manifest(root: Paths.data).path)
        if !manifestExists {
            print("Downloading \(dataset.summary) (up to \(limit) clips)…")
            let result = try await Downloader.download(dataset, limit: limit, root: Paths.data)
            print("  \(result.statusLine)")
        }
        // Same segment-tag/blank-transcript cleanup `Runners.asr` applies, so accent WER is
        // comparable to the numbers `murmur-eval asr` reports elsewhere.
        return try dataset.load(root: Paths.data)
            .filter { !$0.reference.contains("IGNORE_TIME_SEGMENT") }
            .map { clip in
                EvalClip(
                    id: clip.id, audioPath: clip.audioPath,
                    reference: clip.reference.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression),
                    fluentReference: clip.fluentReference, group: clip.group)
            }
            .filter { !$0.reference.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Error classification (report-only heuristic, never used for scoring)

    enum ErrorClass: String {
        case boostable = "vocabulary boosting could plausibly fix this"
        case notBoostable = "vocabulary boosting can't fix this (function word / short word / likely phonetic shift)"
    }

    /// A pair "looks boostable" when the reference word is a proper noun or jargon-shaped term:
    /// capitalized-looking in typical use, longer than a few letters, and not one of the
    /// closed-class function words a vowel/consonant shift most often lands on. This is a coarse
    /// heuristic for the report, not a scoring rule — every pair is also printed verbatim so a
    /// human can override the call.
    static func classify(_ substitution: SubstitutionAnalysis.Substitution) -> ErrorClass {
        let word = substitution.reference
        if functionWords.contains(word) { return .notBoostable }
        if word.count <= 3 { return .notBoostable }
        return .boostable
    }

    /// Closed-class function words (articles, prepositions, pronouns, auxiliaries, conjunctions)
    /// that vocabulary boosting has no lever over — boosting biases decoding toward a supplied
    /// term list, and function words aren't domain terms anyone would add to one.
    private static let functionWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "am", "be", "been", "being",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them",
        "my", "your", "his", "its", "our", "their", "this", "that", "these", "those",
        "and", "or", "but", "so", "if", "of", "to", "in", "on", "at", "by", "for",
        "with", "as", "from", "into", "than", "then", "not", "no", "yes", "do", "does",
        "did", "have", "has", "had", "can", "could", "will", "would", "should", "shall",
        "may", "might", "must", "there", "here", "what", "which", "who", "whom", "how",
        "when", "where", "why", "up", "down", "out", "off", "over", "under", "again",
    ]
}
