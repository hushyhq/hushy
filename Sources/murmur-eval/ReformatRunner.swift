import CryptoKit
import FluidAudio
import Foundation
import MurmurCore

/// `murmur-eval reformat [--level clean|polished|both] [--golden Evals/reformat-golden.json]
///     [--min-pass 0.NN] [--report path.json] [--limit N] [--judge] [--prewarm]
///     [--via-asr [--model ultra|v2] [--voices Samantha,Daniel,…]]`
///
/// HELD-OUT evaluation of how rambling dictation is reformatted into clean typed text. Every case
/// runs through the production text path — `DictationPipeline.clean` (the same entry point the
/// `cleanup`/`modes` commands and History retry use), with `CleanupOptions(level:)` and the
/// production strategy for that level (`SmartCleaner.strategy(for:)`: clean → hybrid, polished →
/// model) — and is scored with property checks (`ReformatChecks`), not exact text:
/// must-contain content, must-not-contain disfluencies, word bounds, negation preservation,
/// question marks / sentence splits, and `mustEqualInput` for negatives that must stay unchanged.
///
/// `--via-asr` re-renders every case through the real audio path instead: `/usr/bin/say` speaks
/// the case input (voices rotate, `--voices`), Parakeet (`--model`, default ultra) transcribes it
/// through `DictationPipeline.run` — loudness normalization, ASR with word confidences, then the
/// same cleanup — and the same checks score the result. Parakeet punctuates and capitalizes, so
/// this is the realistic input shape; the text-in mode's lowercase, unpunctuated inputs are the
/// worst case. For `mustEqualInput` negatives the reference is what ASR heard, so an ASR error
/// isn't blamed on cleanup; ASR WER against the case input is reported separately. Latency is
/// cleanup time after ASR.
///
/// `--prewarm` (text-in or `--via-asr`) simulates streaming prewarm (`StreamingDictationSession`): every closed group of a
/// long dictation is cleaned via `SmartCleaner.prewarmGroup` before the timer starts, as it would
/// be while the user is still talking, so the reported latency is the after-key-release time
/// (tail group only). It assumes speech lasted long enough for prewarm to finish — true for any
/// multi-group dictation at normal speaking pace (~2.5 words/s vs ~1.5-2.5 s per group).
///
/// Originally held out; since 2026-09-26 this set is the dev set for dictation robustness work
/// and a separate blind held-out set scores that work (see `.claude/DECISIONS.md`).
/// `--min-pass` gates on every requested level's deterministic pass rate. `--judge` adds an
/// optional TypeSafe/Jev cross-check against each case's `reference` (skipped without a key).
enum ReformatRunner {
    struct CaseRun: Sendable {
        let id: String
        let category: String
        let lengthBucket: String
        let negative: Bool
        let input: String
        let reference: String
        let output: String
        let usedModel: Bool
        let rejection: String?
        let latencyMs: Double
        let outcome: ReformatChecks.Outcome
    }

    struct LevelRun: Sendable {
        let level: CleanupLevel
        let strategy: SmartCleaner.Strategy
        let cases: [CaseRun]
        /// (case input, what ASR heard) — only for `--via-asr`.
        var asrPairs: [(reference: String, hypothesis: String)] = []

        var passRate: Double { ratio(cases.filter(\.outcome.passed).count, cases.count) }
    }

    static func run(_ args: Arguments) async throws {
        let golden = args.string("golden").map { URL(fileURLWithPath: $0) }
            ?? Paths.root.appendingPathComponent("reformat-golden.json")
        var cases = try JSONDecoder().decode([ReformatChecks.Case].self, from: Data(contentsOf: golden))
        let problems = ReformatChecks.validate(cases)
        guard problems.isEmpty else {
            throw EvalError.missing("Invalid reformat golden set:\n  " + problems.joined(separator: "\n  "))
        }
        if let limit = args.int("limit") { cases = Array(cases.prefix(limit)) }
        let levels = try parseLevels(args.string("level") ?? "both")
        let minPass = try args.string("min-pass").map(parseFraction)

        let cleaner = args.makeCleaner()
        cleaner.prewarm()
        let viaASR = args.flag("via-asr")
        let prewarm = args.flag("prewarm")
        let started = Date()
        var runs: [LevelRun] = []
        if viaASR {
            let engine = try await Recognizers.make(args)
            let pipeline = DictationPipeline(transcriber: RecognizerTranscriber(recognizer: engine), cleaner: cleaner)
            let voices = (args.string("voices") ?? "Samantha,Daniel,Karen,Moira").split(separator: ",").map(String.init)
            let audio = try synthesizeAll(cases, voices: voices)
            for level in levels {
                runs.append(try await runLevelViaASR(
                    level, cases: cases, audio: audio, pipeline: pipeline, cleaner: prewarm ? cleaner : nil))
            }
            print("\nASR: \(engine.name == "parakeet" ? args.modelName : engine.name) · voices \(voices.joined(separator: "/")) · WER vs case input \(Runners.percent(EvalMetrics.corpusWER(runs.first?.asrPairs ?? [])))")
        } else {
            let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
            for level in levels {
                runs.append(await runLevel(level, cases: cases, pipeline: pipeline, cleaner: prewarm ? cleaner : nil))
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        if prewarm { print("\nLatency is after-key-release time with simulated streaming prewarm (closed groups cleaned before timing).") }

        for run in runs { ReformatReport.print(run) }
        print("\nReformat eval wall time: \(String(format: "%.1f", elapsed)) s")
        let judged = args.flag("judge") ? await ReformatJudge.judge(runs) : [:]
        if let path = args.string("report") {
            try ReformatReport.write(runs, judged: judged, golden: golden, elapsedSeconds: elapsed, to: path)
        }
        if let minPass {
            let below = runs.filter { $0.passRate < minPass }
            if !below.isEmpty {
                let names = below.map(\.level.rawValue).joined(separator: ", ")
                FileHandle.standardError.write(Data("Reformat pass rate below required \(minPass) for: \(names)\n".utf8))
                exit(1)
            }
        }
    }

    static func parseLevels(_ raw: String) throws -> [CleanupLevel] {
        switch raw {
        case "clean": return [.clean]
        case "polished": return [.polished]
        case "both": return [.clean, .polished]
        default: throw EvalError.missing("--level must be clean, polished or both (got \(raw))")
        }
    }

    private static func parseFraction(_ raw: String) throws -> Double {
        guard let value = Double(raw), (0...1).contains(value) else {
            throw EvalError.missing("--min-pass must be a fraction in 0...1 (got \(raw))")
        }
        return value
    }

    private static func runLevel(
        _ level: CleanupLevel, cases: [ReformatChecks.Case], pipeline: DictationPipeline, cleaner: SmartCleaner?
    ) async -> LevelRun {
        let strategy = SmartCleaner.strategy(for: level)
        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: level))
        var results: [CaseRun] = []
        for item in cases {
            guard let expectation = item.levels[level.rawValue] else { continue }
            if let cleaner {
                // What `StreamingDictationSession.prewarmClosedGroups` does while the user talks.
                await cleaner.clearPrewarmedGroups()
                let groups = TextSegmentation.groups(item.input)
                for group in groups where !group.isTail {
                    await cleaner.prewarmGroup(group.text, options: settings.cleanupOptions, strategy: strategy,
                        previousRaw: group.index > 0 ? groups[group.index - 1].text : nil)
                }
            }
            let start = ContinuousClock.now
            let result = await pipeline.clean(item.input, settings: settings, strategy: strategy)
            let latency = ContinuousClock.now - start
            let latencyMs = Double(latency.components.seconds) * 1000 + Double(latency.components.attoseconds) / 1e15
            results.append(CaseRun(
                id: item.id, category: item.category, lengthBucket: item.lengthBucket, negative: item.isNegative,
                input: item.input, reference: expectation.reference, output: result.text,
                usedModel: result.usedModel, rejection: result.rejection, latencyMs: latencyMs,
                outcome: ReformatChecks.evaluate(item, expectation: expectation, output: result.text)))
        }
        return LevelRun(level: level, strategy: strategy, cases: results)
    }

    /// Speaks every case input once per voice rotation, cached by content hash under
    /// `Evals/data/tts` (the same cache `e2e` uses).
    private static func synthesizeAll(_ cases: [ReformatChecks.Case], voices: [String]) throws -> [String: URL] {
        let folder = Paths.data.appendingPathComponent("tts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [String: URL] = [:]
        for (index, item) in cases.enumerated() {
            let voice = voices[index % voices.count]
            let key = SHA256.hash(data: Data("tts-v2|LEI16@16000|\(voice)|\(item.input)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            let url = folder.appendingPathComponent("\(key).wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try Runners.synthesize(item.input, voice: voice, to: url)
            }
            urls[item.id] = url
        }
        return urls
    }

    /// `cleaner` non-nil means `--prewarm`: the ASR step runs first, the closed groups of what
    /// ASR heard are prewarmed (as `StreamingDictationSession` does while the user talks), and
    /// only the after-release cleanup is timed — the same split `DictationController` has
    /// (engine call, then `pipeline.clean` with the word confidences).
    private static func runLevelViaASR(
        _ level: CleanupLevel, cases: [ReformatChecks.Case], audio: [String: URL], pipeline: DictationPipeline,
        cleaner: SmartCleaner?
    ) async throws -> LevelRun {
        let strategy = SmartCleaner.strategy(for: level)
        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: level))
        var results: [CaseRun] = []
        var pairs: [(reference: String, hypothesis: String)] = []
        for item in cases {
            guard let expectation = item.levels[level.rawValue], let url = audio[item.id] else { continue }
            let samples = try AudioConverter().resampleAudioFile(url)
            let result: PipelineResult
            if let cleaner {
                let heard = try await pipeline.transcribeRawWithTimings(samples, vocabulary: settings.vocabulary)
                await cleaner.clearPrewarmedGroups()
                let groups = TextSegmentation.groups(heard.text)
                for group in groups where !group.isTail {
                    await cleaner.prewarmGroup(group.text, options: settings.cleanupOptions, strategy: strategy,
                        previousRaw: group.index > 0 ? groups[group.index - 1].text : nil)
                }
                result = await pipeline.clean(heard.text, confidences: heard.confidences, settings: settings, strategy: strategy)
            } else {
                result = try await pipeline.run(samples: samples, settings: settings, strategy: strategy)
            }
            pairs.append((item.input, result.raw))
            // Negatives must leave what ASR heard unchanged; judging them against the typed
            // input would blame cleanup for recognition errors.
            let heardCase = ReformatChecks.Case(
                id: item.id, category: item.category, lengthBucket: item.lengthBucket, negative: item.negative,
                mustEqualInput: item.mustEqualInput, input: item.isNegative ? result.raw : item.input,
                note: item.note, levels: item.levels)
            results.append(CaseRun(
                id: item.id, category: item.category, lengthBucket: item.lengthBucket, negative: item.isNegative,
                input: result.raw, reference: expectation.reference, output: result.text,
                usedModel: result.usedModel, rejection: result.rejection, latencyMs: result.timings.cleanupMs,
                outcome: ReformatChecks.evaluate(heardCase, expectation: expectation, output: result.text)))
        }
        return LevelRun(level: level, strategy: strategy, cases: results, asrPairs: pairs)
    }

    static func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }

    static func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "unavailable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
