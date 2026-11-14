import FluidAudio
import Foundation
import MurmurCore

/// `murmur-eval voice-match` — measures, on real multi-speaker speech with human speaker labels, how often the
/// app's diarization finds the right number of speakers and how a remembered voice scores against the same and
/// other speakers in later excerpts. It runs the app's own pipeline (FluidAudio `performCompleteDiarization` with
/// `DiarizerTuning`, the duration-weighted turn embeddings, `SpeakerVoiceSampling` and the embedding model for the
/// saved voice, `VoiceSimilarity`), on files, with no microphone and nothing written outside `--cache`/`--report`.
///
///     murmur-eval voice-match [--window 120] [--clustering-threshold F] [--min-speech-duration F]
///       [--cache cache.json | --save-cache cache.json] [--report report.md] [--false-match-limit 0.01]
///
/// Reads only `ami-meetings-sdm` and `voxconverse-dev` under the eval data folder; never downloads. Embeddings
/// saved by `--save-cache` come from dataset audio and belong in a temp folder, never in the app's home.
enum VoiceMatchRunner {
    static func run(_ args: Arguments) async throws {
        let window = args.string("window").flatMap(Double.init) ?? 120
        let falseLimit = args.string("false-match-limit").flatMap(Double.init) ?? 0.01
        let excerpts: [ExcerptRecord]
        var header = ""
        if let cachePath = args.string("cache") {
            excerpts = try JSONDecoder().decode([ExcerptRecord].self, from: Data(contentsOf: URL(fileURLWithPath: cachePath)))
            header = "Scored from a saved analysis (\(cachePath.isEmpty ? "" : "cache")); no audio or model used.\n"
        } else {
            (excerpts, header) = try await analyzeAll(args, window: window)
            if let path = args.string("save-cache") {
                try JSONEncoder().encode(excerpts).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        let report = render(excerpts, header: header, window: window, falseLimit: falseLimit)
        print(report)
        if let path = args.string("report") { try report.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    private static func analyzeAll(_ args: Arguments, window: Double) async throws -> ([ExcerptRecord], String) {
        var config = DiarizerConfig.default
        config.clusteringThreshold = args.string("clustering-threshold").flatMap(Float.init) ?? DiarizerTuning.clusteringThreshold
        config.minSpeechDuration = args.string("min-speech-duration").flatMap(Float.init) ?? DiarizerTuning.minSpeechDuration
        let analyzer = VoiceMatchAnalyzer(manager: try VoiceMatchAnalyzer.loadManager(config: config))
        let recordings = try VoiceMatchData.load(root: Paths.data)
        guard !recordings.isEmpty else { throw EvalError.missing("no recordings found under the eval data folder") }

        var excerpts: [ExcerptRecord] = []
        var rows: [String] = []
        for recording in recordings {
            let duration = Double(recording.audio.count) / VoiceMatchAnalyzer.sampleRate
            let windows = VoiceMatchMeasurement.windows(duration: duration, length: window, minimumTail: window / 2)
            for (index, span) in windows.enumerated() { excerpts.append(try analyzer.analyze(recording, window: span, index: index)) }
            let speakers = Set(recording.turns.map(\.label)).count
            rows.append("| \(recording.id) | \(recording.set) | \(recording.half.rawValue) | \(Int(duration)) s | \(speakers) | \(windows.count) |")
        }
        let header = """
            Clustering threshold \(config.clusteringThreshold), minimum speech \(config.minSpeechDuration) s, excerpt length \(Int(window)) s.

            | recording | set | half | length | true speakers | excerpts |
            |---|---|---|---|---|---|
            \(rows.joined(separator: "\n"))

            """
        return (excerpts, header)
    }

    static func render(_ excerpts: [ExcerptRecord], header: String, window: Double, falseLimit: Double) -> String {
        var parts = ["### Voice match on real speech · \(excerpts.count) excerpts of \(Int(window)) s", "", header]
        parts.append("Not used: " + VoiceMatchData.skipped.map { "\($0.set) (\($0.reason))" }.joined(separator: "; ") + ".\n")
        let tune = excerpts.filter { $0.half == .tune }, held = excerpts.filter { $0.half == .held }
        for (name, subset) in [("TUNE half", tune), ("HELD half", held), ("ALL", excerpts)] {
            let scorer = VoiceMatchScorer(excerpts: subset)
            parts += ["---", "### \(name) · \(subset.count) excerpts", ""]
            parts.append(VoiceMatchReport.speakerCounts(subset, title: name))
            parts.append(VoiceMatchReport.der(subset, title: name))
            parts.append(VoiceMatchReport.similarity(scorer, title: name))
            parts.append(VoiceMatchReport.variants(scorer, title: name))
            parts.append(VoiceMatchReport.overSplit(scorer, title: name))
            parts.append(VoiceMatchReport.trials(scorer, title: name, gates: VoiceMatchReport.reportedGates))
            parts.append(VoiceMatchReport.library(scorer, title: name, gates: VoiceMatchReport.reportedGates))
        }
        let tuneScorer = VoiceMatchScorer(excerpts: tune)
        let chosen = VoiceMatchReport.gateChosen(on: tuneScorer, falseMatchLimit: falseLimit)
        parts += ["---", "### Gate chosen on the tune half", ""]
        parts.append("Lowest gate on a 0.025 grid whose false-match rate over all different-speaker pairs on the TUNE half is at most \(String(format: "%.1f%%", falseLimit * 100)): " + (chosen.map { String(format: "%.3f", $0) } ?? "none up to 0.90") + ".\n")
        if let chosen {
            parts.append(VoiceMatchReport.trials(VoiceMatchScorer(excerpts: held), title: "HELD half at the chosen gate", gates: [0.75, chosen]))
        }
        return parts.joined(separator: "\n\n")
    }
}
