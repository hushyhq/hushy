import FluidAudio
import Foundation
import MurmurCore

/// Calibrates `ConfidenceSpans.Calibration.threshold` on public data: how well does ASR word
/// confidence predict which words are actually wrong?
///
/// For each clip, this runs the same `Engine`/`SpeechEngine` ASR path the app uses, aggregates
/// per-word confidence exactly as `SpeechEngine.wordConfidences(from:)` does (min over
/// SentencePiece pieces), aligns the hypothesis to the reference transcript with the same
/// LCS word-alignment `BoostGuard.align` uses elsewhere in this codebase (so calibration
/// measures against the same notion of "aligned" the runtime guard uses), and labels each
/// hypothesis word correct/wrong. Sweeping candidate thresholds then reports, for each: what
/// fraction of wrong words would be marked (coverage — this is what protects against
/// over-deletion, since only marked words are eligible for model edits) and what fraction of
/// all words would be marked (marking rate — this is the cost, since a highly-marked transcript
/// gives the model too much freedom and reintroduces the over-correction problem this feature
/// exists to fix).
enum ConfidenceCalibration {
    struct WordSample {
        let confidence: Float
        let isWrong: Bool
    }

    static func run(_ args: Arguments) async throws {
        let datasetNames = (args.string("datasets") ?? "librispeech-other,commonvoice-spontaneous")
            .split(separator: ",").map(String.init)
        let limit = args.int("limit") ?? 150
        let engine = try await Engine.load(args.model)

        var report = "### Confidence calibration · \(datasetNames.joined(separator: ", ")) · \(args.modelName)\n"
        var allSamples: [WordSample] = []

        for name in datasetNames {
            let manifestURL = Paths.data.appendingPathComponent(name, isDirectory: true).appendingPathComponent("manifest.json")
            guard let clips = try? JSONDecoder().decode([EvalClip].self, from: Data(contentsOf: manifestURL)) else {
                report += "\n- \(name): no manifest found, skipped (run `murmur-eval download` / `import-commonvoice` first)\n"
                continue
            }
            let datasetDir = Paths.data.appendingPathComponent(name, isDirectory: true)
            let samples = try await collect(clips: Array(clips.prefix(limit)), engine: engine, datasetDir: datasetDir)
            allSamples += samples
            report += "\n#### \(name) · \(samples.count) words from \(min(limit, clips.count)) clips\n"
            report += table(samples)
        }

        report += "\n#### Combined · \(allSamples.count) words\n"
        report += table(allSamples)
        report += "\n- Chosen threshold: **\(ConfidenceSpans.Calibration.threshold)** " +
            "(see `docs/research/confidence-threshold-calibration.md` for the rationale)\n"
        Runners.emit(report)
    }

    /// Runs ASR on each clip, aggregates word confidences, and labels each hypothesis word
    /// correct/wrong against the reference using `BoostGuard`'s LCS alignment: a word inside a
    /// `.same` run is correct, a word inside the `new` side of a `.changed` run (substitution or
    /// insertion) is wrong.
    private static func collect(clips: [EvalClip], engine: Engine, datasetDir: URL) async throws -> [WordSample] {
        var samples: [WordSample] = []
        for clip in clips {
            // `manifest.json` can carry an absolute `audioPath` baked from a different worktree
            // (each worktree checks out its own copy of Evals/, but manifests are committed with
            // whatever path existed when they were written). Resolve by basename under this
            // dataset's own directory instead of trusting the recorded absolute path.
            let candidate = URL(fileURLWithPath: clip.audioPath)
            let resolved = FileManager.default.fileExists(atPath: candidate.path)
                ? candidate : datasetDir.appendingPathComponent(candidate.lastPathComponent)
            // A handful of downloaded clips can be truncated/corrupt/missing; skip rather than
            // abort the whole calibration run over one bad file.
            guard let converted = try? AudioConverter().resampleAudioFile(resolved) else { continue }
            guard let result = try? await engine.transcribeRawResult(converted),
                  let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty
            else { continue }
            let wordConfidences = FluidAudioWordConfidence.aggregate(tokenTimings)
            guard !wordConfidences.isEmpty else { continue }

            let referenceKeys = EvalMetrics.normalizedWords(clip.reference)
            let hypothesisKeys = wordConfidences.map { EvalMetrics.normalizedWords($0.word).first ?? "" }
            let wrongIndices = WordAlignment.wrongHypothesisIndices(reference: referenceKeys, hypothesis: hypothesisKeys)
            for (index, wc) in wordConfidences.enumerated() {
                samples.append(WordSample(confidence: wc.confidence, isWrong: wrongIndices.contains(index)))
            }
        }
        return samples
    }

    /// Precision/coverage table across candidate thresholds, in the same style as the rest of
    /// the harness's markdown reports.
    private static func table(_ samples: [WordSample]) -> String {
        guard !samples.isEmpty else { return "  (no data)\n" }
        let wrongCount = samples.filter(\.isWrong).count
        var lines = "  | threshold | marked | marked-of-total | coverage of wrong words |\n"
        lines += "  |---|---|---|---|\n"
        for threshold in stride(from: Float(0.3), through: 0.98, by: 0.04) {
            let marked = samples.filter { $0.confidence < threshold }
            let markedWrong = marked.filter(\.isWrong).count
            let markRate = Double(marked.count) / Double(samples.count)
            let coverage = wrongCount == 0 ? 0 : Double(markedWrong) / Double(wrongCount)
            lines += String(
                format: "  | %.2f | %d | %.1f%% | %.1f%% |\n",
                threshold, marked.count, markRate * 100, coverage * 100)
        }
        lines += "  - overall word error rate on this sample: \(String(format: "%.1f%%", Double(wrongCount) / Double(samples.count) * 100))\n"
        return lines
    }
}
