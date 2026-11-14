import FluidAudio
import Foundation
import MurmurCore

/// Multi-language dictation evals: ASR word-error-rate on non-English clips across
/// Parakeet v2/v3/Ultra, and a cleanup word-preservation check confirming non-English text
/// survives `TextCleaner`/`SmartCleaner` intact (the English-only stages are skipped for it —
/// see `TextCleaner.clean`).
///
///   murmur-eval multilang wer [--languages es,fr,de,it] [--models v2,v3,ultra] [--limit 25]
///   murmur-eval multilang cleanup [--min-preserved 0.99]
///
/// `wer` downloads (resumable, cached under Evals/data — see `Downloader.download`) up to
/// `--limit` clips per language from Multilingual LibriSpeech (`mls-es`/`mls-fr`/`mls-de`/
/// `mls-it` — see `Dataset.multilangDatasets` for why this replaced FLEURS) and reports WER +
/// latency per model, matching the shape of `murmur-eval asr`. Never touches the held-out Voice
/// Lab set.
enum MultilangRunner {
    static func run(_ args: Arguments) async throws {
        switch args.positional.first {
        case "cleanup": try await cleanupPreservation(args)
        default: try await wer(args)
        }
    }

    // MARK: WER across languages × models

    static func wer(_ args: Arguments) async throws {
        let languages = (args.string("languages") ?? "es,fr,de,it").split(separator: ",").map(String.init)
        let datasets = languages.compactMap { Dataset(rawValue: "mls-\($0)") }
        guard datasets.count == languages.count else {
            throw EvalError.missing("Unknown language in --languages (expected a subset of es,fr,de,it)")
        }
        let models = (args.string("models") ?? "v2,v3,ultra").split(separator: ",").map(String.init)
        let limit = args.int("limit") ?? 25
        var rows: [String] = []
        for dataset in datasets {
            if !hasManifest(dataset) {
                print("Downloading \(dataset.summary) (up to \(limit) clips)…")
                let result = try await Downloader.download(dataset, limit: limit, root: Paths.data)
                print("  \(result.statusLine)")
            }
            let clips = try dataset.load(root: Paths.data).prefix(limit)
            guard !clips.isEmpty else {
                rows.append("| \(dataset.rawValue) | — | 0 clips (download failed/unavailable) | — | — |")
                continue
            }
            for modelName in models {
                guard let version = Self.modelVersion(modelName) else { continue }
                let engine = try await Engine.load(version)
                var pairs: [(reference: String, hypothesis: String)] = []
                var latencies: [Double] = []
                for clip in clips {
                    let url = URL(fileURLWithPath: clip.audioPath)
                    let start = Date()
                    let (text, _) = try await engine.transcribe(file: url)
                    latencies.append(Date().timeIntervalSince(start) * 1000)
                    pairs.append((clip.reference, text))
                }
                let corpusWER = EvalMetrics.corpusWER(pairs)
                let p50 = EvalMetrics.percentile(latencies, 0.5)
                rows.append("| \(dataset.rawValue) | \(modelName) | \(clips.count) | \(Runners.percent(corpusWER)) | \(Runners.ms(p50)) |")
            }
        }
        let table = "| Dataset | Model | Clips | WER | Latency p50 |\n|---|---|---|---|---|\n" + rows.joined(separator: "\n")
        Runners.emit("### Multi-language ASR · languages \(languages.joined(separator: ",")) · models \(models.joined(separator: ","))\n" + table)
    }

    private static func hasManifest(_ dataset: Dataset) -> Bool {
        FileManager.default.fileExists(atPath: dataset.manifest(root: Paths.data).path)
    }

    private static func modelVersion(_ name: String) -> AsrModelVersion? {
        switch name {
        case "v2": .v2
        case "v3": .v3
        case "ultra": .ultra
        default: nil
        }
    }

    // MARK: Cleanup word preservation for non-English text

    private struct MultilangCase: Decodable {
        let id: String
        let language: String
        let spoken: String
    }

    /// For non-English text, cleanup should only apply language-neutral tidy steps (punctuation,
    /// voice-command line breaks) and never the English-only stages (fillers, restatement,
    /// self-correction, ITN, English list formatting) — see `TextCleaner.clean`. This measures
    /// that indirectly and robustly: the fraction of the *spoken* transcript's content words
    /// that still appear somewhere in the cleaned output. Punctuation/capitalization changes
    /// don't count against it; a dropped or mistranslated word does.
    static func cleanupPreservation(_ args: Arguments) async throws {
        let url = args.string("golden").map { URL(fileURLWithPath: $0) } ?? Paths.root.appendingPathComponent("multilang-golden.json")
        let cases = try JSONDecoder().decode([MultilangCase].self, from: Data(contentsOf: url))
        guard !cases.isEmpty else { throw EvalError.missing("multilang golden set is empty") }
        let cleaner = SmartCleaner()
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        var preservedRatios: [Double] = []
        var failures: [String] = []
        for item in cases {
            let options = CleanupOptions(level: .clean, voiceCommandsEnabled: true, detectedLanguage: item.language)
            let result = await pipeline.clean(item.spoken, settings: PipelineSettings(cleanupOptions: options))
            let spokenWords = Self.words(item.spoken)
            let outputWords = Set(Self.words(result.text))
            let preserved = spokenWords.isEmpty ? 1.0 : Double(spokenWords.filter(outputWords.contains).count) / Double(spokenWords.count)
            preservedRatios.append(preserved)
            if preserved < 0.99 {
                failures.append("\(item.id): preserved \(Runners.percent(preserved)) — \"\(result.text)\"")
            }
        }
        let overall = preservedRatios.reduce(0, +) / Double(preservedRatios.count)
        let summary = "### Multi-language cleanup word preservation · \(cases.count) cases\n- Preserved: **\(Runners.percent(overall))** (word-preservation floor: 99%)"
        Runners.emit(summary, details: failures.isEmpty ? [] : ["Below floor:"] + failures)
        let minimum = Double(args.string("min-preserved") ?? "0.99") ?? 0.99
        guard overall >= minimum else {
            throw EvalError.missing("Multi-language word preservation \(Runners.percent(overall)) below required \(Runners.percent(minimum))")
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
