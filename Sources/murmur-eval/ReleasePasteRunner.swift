import CryptoKit
import FluidAudio
import Foundation
import HushyModelsApple
import HushyModelsMLX
import MurmurCore

/// `murmur-eval release-paste --cases Evals/release-paste-takes.jsonl --mlx-model <dir> --out <jsonl>
/// [--local-model <id>] [--rounds 3] [--voices Samantha,Daniel,Karen] [--speak-ms <n>]`
///
/// Key release to text, stage by stage, on the app's release path (`DictationController.process`) without the app:
/// audio analysis (meter, gate, gain, speech evidence), the whole-recording recogniser pass (Ultra with the drift
/// guard), the vocabulary rescore, the release swaps, the key-down warm's stop, and `DictationPipeline.clean` with the
/// shipped cleanup model and the app's cleaner settings. Paste is not driven: it needs a real target app.
///
/// Each take is spoken by `say` (cached under `Evals/data/tts`, made before any model loads). Before its release the
/// run waits as long as the take's audio, as the person would be speaking, and schedules the key-down warm the way
/// the app does. Texts go only to `--out`; stdout has times and counts.
enum ReleasePasteRunner {
    struct Take {
        let id: String
        let spoken: String
        let length: String
        let register: String
    }

    static func run(_ args: Arguments) async throws {
        guard let input = args.string("cases"), let output = args.string("out"),
              let folder = args.string("mlx-model") else {
            throw EvalError.missing("release-paste needs --cases <jsonl> --mlx-model <dir> --out <jsonl>")
        }
        let takes = try loadTakes(input)
        let rounds = args.int("rounds") ?? 3
        let voices = (args.string("voices") ?? "Samantha,Daniel,Karen").split(separator: ",").map(String.init)
        let audio = try synthesize(takes, voices: voices)

        let engine = try await Engine.load(.ultra, driftGuard: true)
        try await engine.warmFallback()
        if args.flag("overlap-probe") {
            try await overlapProbe(takes, audio: audio, engine: engine, rounds: rounds)
            return
        }
        let entry = try args.localModelEntry()
        let chain = LocalCleanupBackend.chain(
            entry: entry, directory: URL(fileURLWithPath: folder, isDirectory: true),
            fallback: AppleFoundationModel(), idleSeconds: nil, callLog: ModelCallLog())
        let cleaner = SmartCleaner(model: chain.model, wholeTranscript: { entry.promptProfile == .intent },
                                   registerLines: { entry.understandsRegisterLines }, secondOpinion: AppleFoundationModel())
        let warm = KeyDownWarmScheduler { await cleaner.warmOnKeyDown() }
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner, warmScheduler: warm)
        cleaner.prewarm(prefixesFor: .polished)
        await chain.model.prefixCache(instructions: SmartCleaner.cleanupInstructions(confidenceGuided: false))
        if cleaner.sendsRegisterLines {
            for register in IntentRegister.allCases {
                await chain.model.prefixCache(instructions: SmartCleaner.registerInstructions(register))
            }
        }
        let vocabulary = settings(for: takes[0]).vocabulary
        // The app's boosting session is built while the person speaks; build it here before any take is timed.
        _ = try await engine.releaseStages(try AudioConverter().resampleAudioFile(audio[takes[0].id]!), vocabulary: vocabulary)
        print("release-paste model=\(entry.id) takes=\(takes.count) rounds=\(rounds) vocabularyTerms=\(vocabulary.terms.count) load \(WaitLatencyRunner.loadAverage())")

        // `--boost ab`: every take is released twice per round, once with the CTC pass after the primary pass
        // (`sequential`, the order before 2026-11-07) and once alongside it, alternating which goes first.
        let boost = args.string("boost") ?? "alongside"
        guard ["sequential", "alongside", "ab"].contains(boost) else { throw EvalError.missing("--boost sequential|alongside|ab") }
        var rows = [[String: Any]]()
        for round in 0..<rounds {
            for (index, take) in takes.enumerated() {
                let samples = try AudioConverter().resampleAudioFile(audio[take.id]!)
                let speakMs = args.int("speak-ms") ?? samples.count / 16
                let arms = boost == "ab" ? ((index + round) % 2 == 0 ? ["sequential", "alongside"] : ["alongside", "sequential"]) : [boost]
                for arm in arms {
                    await engine.setBoostsAlongside(arm == "alongside")
                    warm.schedule()
                    try await Task.sleep(for: .milliseconds(speakMs))
                    var row = await release(take, samples: samples, engine: engine, pipeline: pipeline, warm: warm, chain: chain)
                    row["round"] = round
                    row["arm"] = arm
                    print("\(arm) " + summaryLine(row))
                    rows.append(row)
                }
            }
        }
        let lines = try rows.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        print(report(rows))
        print("release-paste load at end \(WaitLatencyRunner.loadAverage()) output=\(output)")
    }

    /// `--overlap-probe`: does the vocabulary model's CTC pass overlap the primary recogniser pass when both run at once
    /// (both are Core ML on the Neural Engine)? Per take: each alone, then both together, alternating which goes first.
    private static func overlapProbe(_ takes: [Take], audio: [String: URL], engine: Engine, rounds: Int) async throws {
        let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let spotter = CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count)
        let empty = CustomVocabularyContext(terms: [])
        func ms(_ start: ContinuousClock.Instant) -> Int { Int(ModelPace.ms(ContinuousClock.now - start).rounded()) }
        var sums = (asr: [Double](), ctc: [Double](), both: [Double]())
        for round in 0..<rounds {
            for (index, take) in takes.enumerated() {
                let samples = LoudnessNormalizer.normalize(try AudioConverter().resampleAudioFile(audio[take.id]!))
                var asrMs = 0, ctcMs = 0
                for step in (index + round) % 2 == 0 ? [0, 1] : [1, 0] {
                    let start = ContinuousClock.now
                    if step == 0 { _ = try await engine.transcribeRawResult(samples); asrMs = ms(start) } else {
                        _ = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: empty); ctcMs = ms(start)
                    }
                }
                let start = ContinuousClock.now
                async let primary = engine.transcribeRawResult(samples)
                async let spotted = spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: empty)
                _ = try await (primary, spotted)
                let bothMs = ms(start)
                sums.asr.append(Double(asrMs)); sums.ctc.append(Double(ctcMs)); sums.both.append(Double(bothMs))
                print("overlap \(take.id) audioMs=\(samples.count / 16) asrMs=\(asrMs) ctcMs=\(ctcMs) bothMs=\(bothMs) sequentialMs=\(asrMs + ctcMs)")
            }
        }
        let p = { (v: [Double]) in "\(Int(WaitLatencyRunner.percentile(v, 0.5)))/\(Int(WaitLatencyRunner.percentile(v, 0.9)))" }
        let seq = zip(sums.asr, sums.ctc).map(+)
        print("overlap p50/p90 asr \(p(sums.asr)) ctc \(p(sums.ctc)) sequential \(p(seq)) together \(p(sums.both)) n=\(seq.count)")
    }

    /// One key release, timed as `DictationController.process` runs it.
    private static func release(
        _ take: Take, samples: [Float], engine: Engine, pipeline: DictationPipeline, warm: KeyDownWarmScheduler,
        chain: LocalCleanupBackend.Chain
    ) async -> [String: Any] {
        let settings = settings(for: take)
        let released = ContinuousClock.now
        var mark = released
        func lap() -> Int {
            let now = ContinuousClock.now
            defer { mark = now }
            return Int(ModelPace.ms(now - mark).rounded())
        }
        let metrics = AudioMetering.measure(samples)
        let gate = SpeechGate.evaluate(samples, metrics: metrics)
        let normalized = LoudnessNormalizer.normalize(samples, metrics: metrics)
        _ = AudioMetering.measure(normalized)
        _ = SpeechEvidence(gate: gate, samples: samples, duration: Double(samples.count) / 16_000)
        let analysisMs = lap()
        let stages: (result: TranscriptionResult, baseMs: Double, boostMs: Double)
        do {
            stages = try await engine.releaseStages(normalized, vocabulary: settings.vocabulary)
        } catch {
            return ["id": take.id, "error": "\(error)"]
        }
        let recogniserMs = lap()
        let swapped = ReleaseSwaps.apply(stages.result, keep: settings.keepHeard)
        let raw = DraftCommonWordGuard.reconcile(
            draft: nil, release: swapped.text, vocabulary: settings.vocabulary, installedApps: settings.installedApps).text
        let textMs = lap()
        await warm.beforeRealCall()
        let warmStopMs = lap()
        let callsBefore = chain.mlx.stats.successes
        let result = await pipeline.clean(raw, confidences: stages.result.confidences, settings: settings, released: released)
        let cleanupMs = lap()
        let total = Int(ModelPace.ms(ContinuousClock.now - released).rounded())
        let calls = chain.mlx.stats.successes - callsBefore
        let timing = calls > 0 ? chain.mlx.lastCallTimings : nil
        let modelMs = result.groups.compactMap(\.modelMs).reduce(0, +)
        let callMs = result.groups.compactMap(\.measured.callMs).reduce(0, +)
        return [
            "id": take.id, "length": take.length, "register": take.register, "words": TextStats.wordCount(take.spoken),
            "audioMs": samples.count / 16, "totalMs": total,
            "analysisMs": analysisMs, "asrMs": Int(stages.baseMs.rounded()), "boostMs": Int(stages.boostMs.rounded()),
            "recogniserMs": recogniserMs, "textMs": textMs, "warmStopMs": warmStopMs, "cleanupMs": cleanupMs,
            "modelMs": modelMs, "callMs": callMs, "calls": calls,
            "prefixBuildMs": timing.map { Int($0.prefixMilliseconds.rounded()) } as Any? ?? NSNull(),
            "ttftMs": timing.map { Int($0.timeToFirstTokenMilliseconds.rounded()) } as Any? ?? NSNull(),
            "lastCallMs": timing.map { Int($0.totalMilliseconds.rounded()) } as Any? ?? NSNull(),
            "promptTokens": timing?.promptTokens as Any? ?? NSNull(),
            "sampledTokens": timing?.generatedTokens as Any? ?? NSNull(),
            "forcedTokens": timing?.forcedTokens as Any? ?? NSNull(),
            "plainRetryMs": result.groups.compactMap(\.plainRetryMs).reduce(0, +),
            "stages": result.cleanupStages,
            "usedModel": result.usedModel, "rejection": result.rejection as Any? ?? NSNull(),
            "speedFallback": result.speedFallback, "boosted": stages.result.unboosted != nil,
            "raw": raw, "text": result.text,
        ]
    }

    /// Default: refined in a plain editor. Professional: the tone chosen for Mail.
    static func settings(for take: Take) -> PipelineSettings {
        let professional = take.register == "professional"
        var settings = LiveShapeRunner.settings(
            tone: professional ? .professional : .refined, bundleID: professional ? "com.apple.mail" : "com.apple.TextEdit").0
        settings.installedApps = installedApps
        return settings
    }

    /// A fixed stand-in for the Mac's installed apps, which the app adds to the recogniser's vocabulary.
    static let installedApps = [
        ("com.tinyspeck.slackmacgap", "Slack"), ("notion.id", "Notion"), ("com.figma.Desktop", "Figma"),
        ("com.linear", "Linear"), ("com.raycast.macos", "Raycast"), ("md.obsidian", "Obsidian"),
        ("com.spotify.client", "Spotify"), ("us.zoom.xos", "Zoom"), ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.apple.dt.Xcode", "Xcode"),
    ].map { InstalledAppInfo(bundleID: $0.0, name: $0.1) }

    private static func loadTakes(_ path: String) throws -> [Take] {
        try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { line in
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, let spoken = row["spoken"] as? String else { return nil }
            return Take(id: id, spoken: spoken, length: row["length"] as? String ?? "-",
                        register: row["register"] as? String ?? "default")
        }
    }

    private static func synthesize(_ takes: [Take], voices: [String]) throws -> [String: URL] {
        let folder = Paths.data.appendingPathComponent("tts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var audio: [String: URL] = [:]
        for (index, take) in takes.enumerated() {
            let voice = voices[index % voices.count]
            let key = SHA256.hash(data: Data("tts-v2|LEI16@16000|\(voice)|\(take.spoken)".utf8)).map { String(format: "%02x", $0) }.joined()
            let url = folder.appendingPathComponent("\(key).wav")
            if !FileManager.default.fileExists(atPath: url.path) { try Runners.synthesize(take.spoken, voice: voice, to: url) }
            audio[take.id] = url
        }
        return audio
    }

    private static func summaryLine(_ row: [String: Any]) -> String {
        let keys = ["totalMs", "analysisMs", "asrMs", "boostMs", "textMs", "warmStopMs", "cleanupMs", "ttftMs", "lastCallMs",
                    "sampledTokens", "calls"]
        return "\(row["id"] ?? "?") " + keys.map { "\($0)=\(row[$0].map { "\($0)" } ?? "-")" }.joined(separator: " ")
    }

    /// p50 / p90 per length and register, then for every take.
    static func report(_ rows: [[String: Any]]) -> String {
        let stages = ["totalMs", "analysisMs", "asrMs", "boostMs", "textMs", "warmStopMs", "cleanupMs", "ttftMs",
                      "lastCallMs", "sampledTokens"]
        var groups: [(String, [[String: Any]])] = []
        for length in ["short", "medium", "long"] {
            for register in ["default", "professional"] {
                groups.append(("\(length) \(register)", rows.filter { $0["length"] as? String == length && $0["register"] as? String == register }))
            }
        }
        groups.append(("all", rows))
        var lines = ["| set | n | " + stages.joined(separator: " | ") + " |",
                     "|---|---:|" + String(repeating: "---:|", count: stages.count)]
        for (name, members) in groups where !members.isEmpty {
            let cells = stages.map { stage -> String in
                let values = members.compactMap { $0[stage] as? Int }.map(Double.init)
                guard !values.isEmpty else { return "-" }
                return "\(Int(WaitLatencyRunner.percentile(values, 0.5)))/\(Int(WaitLatencyRunner.percentile(values, 0.9)))"
            }
            lines.append("| \(name) | \(members.count) | " + cells.joined(separator: " | ") + " |")
        }
        let errors = rows.filter { $0["error"] != nil }.count
        let fallbacks = rows.filter { $0["speedFallback"] as? Bool == true }.count
        let used = rows.filter { $0["usedModel"] as? Bool == true }.count
        lines.append("errors=\(errors) speedFallback=\(fallbacks) usedModel=\(used)/\(rows.count) (cells are p50/p90 ms; sampledTokens is a count)")
        return lines.joined(separator: "\n")
    }
}
