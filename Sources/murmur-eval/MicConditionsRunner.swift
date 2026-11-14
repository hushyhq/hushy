@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// `murmur-eval mics`: how the shipping recogniser does across simulated microphones.
///
/// Measurement only. Each public clip is put through a simulated condition (`MicCondition`), then
/// through exactly what the app does with a recording: the speech gate, loudness normalisation and
/// the recogniser (`ultra+guard` by default). For every condition it reports word error rate, the
/// share of clips the speech gate rejected (the app would say it heard nothing) and the share
/// that passed the gate and came back with no words.
///
///   murmur-eval mics [--datasets librispeech-clean,commonvoice-spontaneous] [--limit 100]
///       [--model ultra+guard] [--max-seconds 40] [--data <Evals/data folder>]
///       [--ffmpeg /opt/homebrew/bin/ffmpeg] [--only <group or text in a condition's name>] [--out report.json]
///
/// Public datasets only. A name that looks like a sealed set or a person's own recordings
/// (`heldout`, `voicelab`, `ab-`) is refused before anything is read.
enum MicConditionsRunner {
    static let defaultDatasets = ["librispeech-clean", "commonvoice-spontaneous"]

    struct ConditionResult: Codable {
        var condition: String
        var group: String
        var clips: Int
        /// Corpus WER over every clip; a clip with no text counts every reference word as missed.
        var wer: Double
        /// Corpus WER over the clips that produced text.
        var werWhereText: Double
        var gateRejected: Int
        var empty: Int
        /// Clips where `InputHearing` would call it hardly any sound (the quiet-microphone row).
        var heardLittle: Int
    }

    struct Report: Codable {
        var model: String
        var datasets: [String]
        var clipsPerDataset: [String: Int]
        var audioSeconds: Double
        var results: [ConditionResult]
        var skipped: [String]
    }

    /// Refuses names that are not public speech: sealed sets and the founder's own recordings.
    static func refusal(for dataset: String) -> String? {
        let name = dataset.lowercased()
        if name.contains("heldout") { return "\(dataset) is a sealed set" }
        if name.hasPrefix("voicelab") || name.hasPrefix("ab-") { return "\(dataset) is a person's own recordings, not public speech" }
        return nil
    }

    static func run(_ args: Arguments) async throws {
        let datasets = (args.string("datasets") ?? defaultDatasets.joined(separator: ","))
            .split(separator: ",").map(String.init)
        for dataset in datasets {
            if let reason = refusal(for: dataset) { throw EvalError.missing("murmur-eval mics: \(reason)") }
        }
        let dataRoot = args.string("data").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Paths.data
        let limit = args.int("limit") ?? 100
        let maxSeconds = Double(args.string("max-seconds") ?? "") ?? 40
        let modelName = args.string("model") ?? "ultra+guard"
        guard let engine = try await Engine.load(named: modelName) else {
            throw EvalError.missing("murmur-eval mics: unknown --model \(modelName)")
        }
        let pipeline = DictationPipeline(transcriber: engine)

        // Clips: the first `limit` of each dataset that are no longer than a dictation.
        var clips: [(reference: String, samples: [Float])] = []
        var perDataset: [String: Int] = [:]
        for dataset in datasets {
            let manifest = dataRoot.appendingPathComponent(dataset, isDirectory: true).appendingPathComponent("manifest.json")
            let listed = try JSONDecoder().decode([EvalClip].self, from: Data(contentsOf: manifest))
            var taken = 0
            for clip in listed where taken < limit {
                let reference = clip.reference.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                guard !WhisperEnglishNormalizer.words(reference).isEmpty else { continue }
                let samples = try AudioConverter().resampleAudioFile(path: clip.audioPath)
                guard Double(samples.count) / 16_000 <= maxSeconds, !samples.isEmpty else { continue }
                clips.append((reference, samples))
                taken += 1
            }
            perDataset[dataset] = taken
        }
        guard !clips.isEmpty else { throw EvalError.missing("murmur-eval mics: no clips found under \(dataRoot.path)") }
        let audioSeconds = Double(clips.reduce(0) { $0 + $1.samples.count }) / 16_000

        // Codec conditions need ffmpeg; without it they are named as skipped.
        let ffmpegPath = args.string("ffmpeg") ?? "/opt/homebrew/bin/ffmpeg"
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-eval-mics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let codec = FileManager.default.isExecutableFile(atPath: ffmpegPath)
            ? FFmpegRoundTrip(ffmpeg: URL(fileURLWithPath: ffmpegPath), scratch: scratch) : nil
        var (conditions, skipped) = MicCondition.all(codec: codec, encoders: codec?.encoders() ?? [])
        if let only = args.string("only")?.lowercased() {
            conditions = conditions.filter {
                $0.name == MicCondition.cleanName || $0.group == only || $0.name.lowercased().contains(only)
            }
        }

        var results: [ConditionResult] = []
        for (number, condition) in conditions.enumerated() {
            var all: [(reference: String, hypothesis: String)] = []
            var withText: [(reference: String, hypothesis: String)] = []
            var gateRejected = 0, empty = 0, heardLittle = 0
            for (index, clip) in clips.enumerated() {
                // Babble comes from four other clips of the run, never the clip itself.
                let others = (1...4).map { clips[(index + $0 * 13) % clips.count].samples }
                var input = MicCondition.Input(
                    index: index, samples: clip.samples, otherVoices: others,
                    noise: SeededNoise(seed: UInt64(number &* 1_000_003 &+ index &+ 42)))
                let samples = try condition.apply(&input)
                // What the app does with a recording, in its order: the gate, then normalise and recognise.
                var text = ""
                if SpeechGate.evaluate(samples).hasSpeech {
                    text = try await pipeline.transcribeRaw(samples).trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { empty += 1 }
                } else {
                    gateRejected += 1
                }
                if text.isEmpty, InputHearing.measure(samples).heardLittle { heardLittle += 1 }
                all.append((clip.reference, text))
                if !text.isEmpty { withText.append((clip.reference, text)) }
            }
            let result = ConditionResult(
                condition: condition.name, group: condition.group, clips: clips.count,
                wer: WhisperEnglishNormalizer.corpusWER(all), werWhereText: WhisperEnglishNormalizer.corpusWER(withText),
                gateRejected: gateRejected, empty: empty, heardLittle: heardLittle)
            results.append(result)
            FileHandle.standardError.write(Data("  \(number + 1)/\(conditions.count) \(Self.row(result))\n".utf8))
        }

        let report = Report(model: modelName, datasets: datasets, clipsPerDataset: perDataset, audioSeconds: audioSeconds,
                            results: results, skipped: skipped)
        if let out = args.string("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: out))
        }
        Runners.emit(markdown(report, drift: await engine.driftSummary))
    }

    static func row(_ result: ConditionResult) -> String {
        "| \(result.condition) | \(Runners.percent(result.wer)) | \(share(result.gateRejected, result.clips)) | "
            + "\(share(result.empty, result.clips)) | \(Runners.percent(result.werWhereText)) |"
    }

    static func share(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "–" : String(format: "%.1f%% (%d)", Double(part) / Double(whole) * 100, part)
    }

    static func markdown(_ report: Report, drift: String = "") -> String {
        let total = report.results.first?.clips ?? 0
        let sources = report.datasets.map { "\($0) \(report.clipsPerDataset[$0] ?? 0)" }.joined(separator: ", ")
        var lines = [
            "### Microphone conditions · \(report.model) · \(total) clips (\(sources)) · "
                + String(format: "%.0f min of audio", report.audioSeconds / 60) + drift,
            "Simulated conditions, each through the speech gate, loudness normalisation and the recogniser. WER counts a clip "
                + "with no text as every word missed; Whisper English normaliser.",
            "",
            "| Condition | WER | Gate rejected | Passed the gate, no words | WER where there was text |",
            "|---|---|---|---|---|",
        ]
        var group = ""
        for result in report.results {
            if result.group != group {
                group = result.group
                lines.append("| **\(group)** | | | | |")
            }
            lines.append(row(result))
        }
        if !report.skipped.isEmpty {
            lines.append("")
            lines.append("Not run: " + report.skipped.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}
