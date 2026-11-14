@preconcurrency import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import MurmurCore

enum Runners {
    // MARK: ASR accuracy on public datasets

    static func asr(_ args: Arguments) async throws {
        guard let name = args.positional.first else {
            throw EvalError.missing("usage: murmur-eval asr <\(Dataset.allCases.map(\.rawValue).joined(separator: "|"))|<local manifest folder under Evals/data>>")
        }
        // Known catalogue datasets load through `Dataset`; a local import (e.g. `import-commonvoice`'s
        // commonvoice-spontaneous/commonvoice-scripted) is just a folder with a manifest.json under
        // Evals/data, so fall back to loading that directly by name.
        let manifestURL = Paths.data.appendingPathComponent(name, isDirectory: true).appendingPathComponent("manifest.json")
        guard Dataset(rawValue: name) != nil || FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw EvalError.missing("usage: murmur-eval asr <\(Dataset.allCases.map(\.rawValue).joined(separator: "|"))|<local manifest folder under Evals/data>>")
        }
        // Some corpora mark unscorable segments or annotate noises like <laugh>; drop those.
        let clips = try (Dataset(rawValue: name)?.load(root: Paths.data)
            ?? JSONDecoder().decode([EvalClip].self, from: Data(contentsOf: manifestURL)))
            .filter { !$0.reference.contains("IGNORE_TIME_SEGMENT") }
            .map { clip in
                var copy = clip
                copy = EvalClip(
                    id: clip.id, audioPath: clip.audioPath,
                    reference: clip.reference.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression),
                    fluentReference: clip.fluentReference, group: clip.group)
                return copy
            }
            .filter { !$0.reference.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(args.int("limit") ?? .max)
        let engine = try await Recognizers.make(args)
        var pairs: [(reference: String, hypothesis: String)] = []
        var latencies: [Double] = []
        var audioSeconds = 0.0
        var processing = 0.0
        var worst: [(wer: Double, clip: EvalClip, hypothesis: String)] = []

        for clip in clips {
            let url = URL(fileURLWithPath: clip.audioPath)
            let (text, seconds) = try await engine.transcribe(file: url)
            pairs.append((clip.reference, text))
            latencies.append(seconds * 1000)
            audioSeconds += (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            processing += seconds
            worst.append((EvalMetrics.wer(reference: clip.reference, hypothesis: text), clip, text))
        }
        let wer = EvalMetrics.corpusWER(pairs)
        // ESB-style normalizer (Whisper/ESB conventions: number words, contractions, US/UK
        // spelling, hyphenation, symmetric filler stripping) reported alongside the product
        // normalizer so a WER change from normalization choices is visible next to the number
        // that gates golden-set scoring; see Sources/MurmurCore/Support/EvalTextNormalizer.swift.
        let esbWER = EvalTextNormalizer.corpusWER(pairs)
        let report = """
            ### ASR · \(name) · \(engine.name == "parakeet" ? args.modelName : engine.name) · \(clips.count) clips
            - WER: **\(percent(wer))** (product normalizer) · \(percent(esbWER)) (\(EvalTextNormalizer.version) normalizer)
            - Speed: \(String(format: "%.0f", audioSeconds / max(processing, 0.001)))× real time
            - Latency per clip: p50 \(ms(EvalMetrics.percentile(latencies, 0.5))), p95 \(ms(EvalMetrics.percentile(latencies, 0.95)))
            """
        var groups: [String] = []
        let grouped = Dictionary(grouping: zip(clips, pairs), by: { $0.0.group ?? "" })
        if grouped.count > 1 {
            groups = grouped.map { group, items in
                (group, EvalMetrics.corpusWER(items.map(\.1)), items.count)
            }
            .filter { $0.2 >= 5 }
            .sorted { $0.1 > $1.1 }
            .map { "  - \($0.0): \(percent($0.1)) (\($0.2) clips)" }
        }
        let failures = worst.sorted { $0.wer > $1.wer }.prefix(5).map {
            "  - \(percent($0.wer)) ref: \($0.clip.reference.prefix(90))\n    hyp: \($0.hypothesis.prefix(90))"
        }
        let byGroup = groups.isEmpty ? "" : "\n- WER by accent:\n" + groups.joined(separator: "\n")
        emit(report + byGroup, details: ["Worst clips:"] + failures)
    }

    // MARK: Cleanup quality on the golden set (text only)

    struct GoldenCase: Decodable {
        let id: String
        let tag: String
        let spoken: String
        let expected: String
        /// Other outputs a reasonable person would also accept.
        let alternatives: [String]?
        let expectedPressEnter: Bool?
        let exactText: Bool?
        /// Optional release-gate membership, independent of `tag`: `"literal-command"` marks
        /// the literal/negated-command subset that `scripts/safety-gate.sh` holds to a 100%
        /// floor (gate 6). Added as a separate field so existing `tag` groupings and
        /// `--require-tags` behavior are untouched.
        let gate: String?

        var accepted: [String] { [expected] + (alternatives ?? []) }
    }

    static func loadGolden(_ args: Arguments) throws -> [GoldenCase] {
        let url = args.string("golden").map { URL(fileURLWithPath: $0) } ?? Paths.golden
        let cases = try JSONDecoder().decode([GoldenCase].self, from: Data(contentsOf: url))
        guard !cases.isEmpty, Set(cases.map(\.id)).count == cases.count else {
            throw EvalError.missing("Golden set must be nonempty with unique IDs")
        }
        return cases
    }

    /// Text-only: no ASR, so there is nothing to normalize. Still runs through
    /// `DictationPipeline.clean` (production cleanup/personalization/style) rather than calling
    /// `SmartCleaner` directly, so this and `e2e` cannot silently drift from the app's behavior.
    /// `--incremental false` forces the pre-segmentation whole-text path on the same golden set,
    /// so long-golden.json can be scored both ways for a direct before/after comparison (see
    /// `scripts/run-evals.sh` and the DECISIONS.md entry for incremental cleanup).
    static func cleanup(_ args: Arguments) async throws {
        let cases = try loadGolden(args)
        let cleanupOptions = try args.cleanupOptions(level: args.cleanupLevel)
        let cleaner = args.makeCleaner(retainsRejectedCandidates: true)
        cleaner.prewarm(prefixesFor: cleanupOptions.level, grammarContract: cleanupOptions.grammarContract)
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        let incremental = args.string("incremental").map { $0 != "false" && $0 != "0" } ?? true
        let settings = PipelineSettings(cleanupOptions: cleanupOptions)
        var results: [CaseResult] = []
        for item in cases {
            let start = Date()
            let result = await pipeline.clean(item.spoken, settings: settings, strategy: args.strategy, incremental: incremental)
            let output = SmartCleaner.Output(
                text: result.text, pressEnter: result.pressEnter, usedModel: result.usedModel, rejection: result.rejection,
                groups: result.groups)
            var caseResult = CaseResult(item: item, input: item.spoken, output: output,
                                        latency: Date().timeIntervalSince(start) * 1000)
            if result.groups.count == 1, let rejected = result.groups[0].rejectedCandidate {
                caseResult.rejectedAnswer = SmartCleaner.presentable(rejected, raw: item.spoken, options: cleanupOptions)
            }
            results.append(caseResult)
        }
        let mode = incremental ? "incremental" : "whole-text"
        try report(title: "Cleanup · strategy \(args.strategy.rawValue) · \(mode) · text only", results: results, args: args)
    }

    // MARK: End to end: synthesized speech → DictationPipeline (normalize → ASR → cleanup → style)
    //
    // Shares DictationPipeline with the app so this exercises actual production behavior,
    // not a second hand-rolled preparation/transcription path. `--raw` keeps a raw-ASR
    // benchmark path (no normalization, no cleanup) clearly separate and labeled, matching
    // what built-in dictation without any cleanup would insert.

    /// Raw ASR deliberately has no cleanup settings; other audio evaluations use the same
    /// validated level, contract, and context options as text-only cleanup.
    static func audioCleanupSettings(_ args: Arguments) throws -> PipelineSettings? {
        if args.command == "e2e", args.flag("raw") || args.string("raw") != nil { return nil }
        guard !args.flag("level"), args.string("level").map({ CleanupLevel(rawValue: $0) != nil }) ?? true else {
            throw EvalError.missing("--level must be verbatim, clean, or polished")
        }
        return PipelineSettings(cleanupOptions: try args.cleanupOptions(level: args.cleanupLevel))
    }

    static func audioCleanupStrategy(_ args: Arguments, settings: PipelineSettings) -> SmartCleaner.Strategy {
        args.string("strategy") == nil ? SmartCleaner.strategy(for: settings.cleanupOptions.level) : args.strategy
    }

    static func cleanupSettingsLabel(_ options: CleanupOptions) -> String {
        "level \(options.level.rawValue) · contract \(options.grammarContract.rawValue) · code \(options.isCodeContext) · casual \(options.isCasualContext) · language \(options.detectedLanguage ?? "unknown")"
    }

    static func cleanupSettingsMetadata(_ options: CleanupOptions?) -> [String: Any] {
        guard let options else { return ["applied": false] }
        return ["applied": true, "level": options.level.rawValue,
                "grammarContract": options.grammarContract.rawValue,
                "isCodeContext": options.isCodeContext, "isCasualContext": options.isCasualContext,
                "detectedLanguage": options.detectedLanguage as Any? ?? NSNull()]
    }

    static func endToEnd(_ args: Arguments) async throws {
        let settings = try audioCleanupSettings(args)
        let strategy = settings.map { audioCleanupStrategy(args, settings: $0) }
        let cases = try loadGolden(args)
        let voices = (args.string("voices") ?? "Samantha,Daniel,Karen,Moira,Aman").split(separator: ",").map(String.init)
        guard !voices.isEmpty else { throw EvalError.missing("At least one voice is required") }
        // All audio is synthesized before the recognizer and the on-device model load. When
        // `say` ran between inferences, a neural voice (Aman) came back truncated — 0.46 s and
        // 1.46 s for a 2.5 s sentence, exit status 0 — and the cached file then failed the case
        // on every later run (corr-month-1 heard "April"). In isolation the same call renders
        // the full 2.51 s. `ReformatRunner.synthesizeAll` has always synthesized up front.
        let folder = Paths.data.appendingPathComponent("tts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var audio: [String: URL] = [:]
        for (index, item) in cases.enumerated() {
            let voice = voices[index % voices.count]
            let key = SHA256.hash(data: Data("tts-v2|LEI16@16000|\(voice)|\(item.spoken)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            let url = folder.appendingPathComponent("\(key).wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try synthesize(item.spoken, voice: voice, to: url)
            }
            audio[item.id] = url
        }

        let engine = try await Recognizers.make(args)
        // --raw: insert the recognizer's text as-is, with no normalization or cleanup — a raw
        // ASR benchmark, kept separate from the production pipeline path below.
        let raw = settings == nil
        let pipeline: DictationPipeline?
        if let settings {
            let cleaner = args.makeCleaner()
            cleaner.prewarm(prefixesFor: settings.cleanupOptions.level,
                            grammarContract: settings.cleanupOptions.grammarContract)
            pipeline = DictationPipeline(transcriber: RecognizerTranscriber(recognizer: engine), cleaner: cleaner)
        } else { pipeline = nil }

        var results: [CaseResult] = []
        var asrPairs: [(reference: String, hypothesis: String)] = []
        for (index, item) in cases.enumerated() {
            let voice = voices[index % voices.count]
            guard let url = audio[item.id] else { continue }
            let start = Date()
            let heard: String
            let output: SmartCleaner.Output
            if raw {
                heard = try await engine.transcribe(file: url).text
                output = SmartCleaner.Output(text: heard, pressEnter: false, usedModel: false, rejection: nil)
            } else if let settings, let pipeline {
                let samples = try AudioConverter().resampleAudioFile(url)
                let result = try await pipeline.run(samples: samples, settings: settings, strategy: strategy)
                heard = result.raw
                output = SmartCleaner.Output(
                    text: result.text, pressEnter: result.pressEnter, usedModel: result.usedModel, rejection: result.rejection)
            } else { throw EvalError.missing("Missing end-to-end cleanup pipeline") }
            let latency = Date().timeIntervalSince(start) * 1000
            asrPairs.append((item.spoken, heard))
            results.append(CaseResult(item: item, input: heard, output: output, latency: latency, voice: voice))
        }
        try report(
            title: "End to end · \(engine.name == "parakeet" ? args.modelName : engine.name) · \(raw ? "raw ASR, no cleanup" : (strategy?.rawValue ?? "unknown")) · voices \(voices.joined(separator: "/"))",
            results: results, args: args,
            extra: ["- ASR WER on the spoken text: \(percent(EvalMetrics.corpusWER(asrPairs)))",
                    "- Cleanup settings: \(settings.map { cleanupSettingsLabel($0.cleanupOptions) } ?? "not applied (raw ASR)")"])
    }

    // MARK: Real disfluent speech

    static func disfluency(_ args: Arguments) async throws {
        let clips = try Array(Dataset.disfluency.load(root: Paths.data).prefix(args.int("limit") ?? .max))
        let engine = try await Engine.load(args.model)
        let cleaner = args.makeCleaner()
        cleaner.prewarm()
        var verbatim: [(reference: String, hypothesis: String)] = []
        var rawVsFluent: [(reference: String, hypothesis: String)] = []
        var cleanVsFluent: [(reference: String, hypothesis: String)] = []
        var modelUses = 0
        for clip in clips {
            guard let fluent = clip.fluentReference else { continue }
            let samples = try AudioConverter().resampleAudioFile(path: clip.audioPath)
            let (raw, _) = try await engine.transcribe(samples)
            let cleaned = await cleaner.clean(raw, options: CleanupOptions(), strategy: args.strategy)
            if cleaned.usedModel { modelUses += 1 }
            verbatim.append((clip.reference, raw))
            rawVsFluent.append((fluent, raw))
            cleanVsFluent.append((fluent, cleaned.text))
        }
        emit("""
            ### Disfluent speech · \(args.modelName) · \(args.strategy.rawValue) · \(verbatim.count) clips
            - ASR WER vs verbatim transcript: **\(percent(EvalMetrics.corpusWER(verbatim)))**
            - Distance to fluent transcript — raw ASR: \(percent(EvalMetrics.corpusWER(rawVsFluent))), after cleanup: **\(percent(EvalMetrics.corpusWER(cleanVsFluent)))**
            - Model pass used on \(modelUses) clips
            """)
    }

    // MARK: Notes path: 48 kHz capture buffers → resampler → 30 s chunks → ASR

    static func notes(_ args: Arguments) async throws {
        let clips = try Array(Dataset.librispeechClean.load(root: Paths.data).prefix(args.int("limit") ?? 40))
        let engine = try await Engine.load(args.model)
        // Build one long "meeting" at 48 kHz, like a Mac microphone delivers.
        var long16k: [Float] = []
        var reference = ""
        for clip in clips {
            long16k += try AudioConverter().resampleAudioFile(path: clip.audioPath)
            long16k += [Float](repeating: 0, count: 8_000)
            reference += clip.reference + " "
        }
        let mic = try upsample(long16k, to: 48_000)

        // Feed it through the live capture path in 1024-frame buffers.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let resampler = StreamingResampler(from: format) else { throw EvalError.missing("resampler") }
        var captured: [Float] = []
        var offset = 0
        while offset < mic.count {
            let count = min(1_024, mic.count - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            mic[offset..<(offset + count)].withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count)
            }
            captured += resampler.convert(buffer)
            offset += count
        }

        // Chunk exactly like NoteRecorder.
        var pending = captured
        var chunks: [[Float]] = []
        let chunkSamples = 30 * 16_000
        while !pending.isEmpty {
            let cut = pending.count < chunkSamples ? pending.count : ChunkSplitter.splitIndex(Array(pending.prefix(chunkSamples)))
            chunks.append(Array(pending.prefix(cut)))
            pending.removeFirst(cut)
        }
        var chunked = ""
        for chunk in chunks where chunk.count > 8_000 {
            chunked += try await engine.transcribe(chunk).0 + " "
        }
        let whole = try await engine.transcribeLong(long16k)
        emit("""
            ### Notes pipeline · \(args.modelName) · \(Int(Double(long16k.count) / 16_000)) s of audio in \(chunks.count) chunks
            - Captured \(captured.count) samples from \(long16k.count) expected (\(String(format: "%+.2f", Double(captured.count - long16k.count) / 16_000)) s)
            - WER, capture + 30 s chunks: **\(percent(EvalMetrics.wer(reference: reference, hypothesis: chunked)))**
            - WER, whole file at once: \(percent(EvalMetrics.wer(reference: reference, hypothesis: whole)))
            """)
    }

    // MARK: Helpers

    struct CaseResult {
        let item: GoldenCase
        let input: String
        let output: SmartCleaner.Output
        let latency: Double
        var voice: String?
        /// Single-group runs only: the text the model's rejected answer would have pasted.
        var rejectedAnswer: String?

        var passed: Bool { matches(output.text) }

        func matches(_ text: String) -> Bool {
            output.pressEnter == (item.expectedPressEnter ?? false) && item.accepted.contains {
                (item.exactText == true ? $0 == text : EvalMetrics.layoutMatches($0, text))
            }
        }
    }

    static func report(title: String, results: [CaseResult], args: Arguments, extra: [String] = []) throws {
        let passed = results.filter(\.passed).count
        let byTag = Dictionary(grouping: results, by: \.item.tag).sorted { $0.key < $1.key }.map { tag, items in
            "\(tag) \(items.filter(\.passed).count)/\(items.count)"
        }
        let werToExpected = EvalMetrics.corpusWER(results.map { ($0.item.expected, $0.output.text) })
        let latencies = results.map(\.latency)
        let modelUses = results.filter(\.output.usedModel).count
        let summary = """
            ### \(title) · \(results.count) cases
            - Pass: **\(passed)/\(results.count) (\(percent(Double(passed) / Double(max(results.count, 1)))))** — \(byTag.joined(separator: " · "))
            - Scoring: layout-and-command-v2 (optional exact text)
            - Word distance to expected: \(percent(werToExpected))
            - Latency: p50 \(ms(EvalMetrics.percentile(latencies, 0.5))), p95 \(ms(EvalMetrics.percentile(latencies, 0.95)))
            - Model pass used on \(modelUses)/\(results.count) · rejected \(results.filter { $0.output.rejection != nil }.count)
            """ + (extra.isEmpty ? "" : "\n" + extra.joined(separator: "\n"))
        let failures = results.filter { !$0.passed }.map { result in
            """
              ✘ \(result.item.id)\(result.voice.map { " [\($0)]" } ?? "")\(result.output.rejection.map { " (model rejected: \($0))" } ?? "")
                heard:    \(result.input.replacingOccurrences(of: "\n", with: " ⏎ "))
                got:      \(result.output.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                expected: \(result.item.expected.replacingOccurrences(of: "\n", with: " ⏎ "))
                enter:    \(result.output.pressEnter) (expected \(result.item.expectedPressEnter ?? false))
            """
        }
        let outcomes = args.command == "cleanup" ? CleanupOutcomeReport.lines(results) : []
        emit(summary, details: outcomes + (failures.isEmpty ? [] : ["Failures:"] + failures))
        try GoldenReport.write(title: title, results: results, args: args)
        if let minimum = args.string("min-pass") {
            guard let value = Double(minimum), (0...1).contains(value) else {
                throw EvalError.missing("--min-pass must be a fraction in 0...1")
            }
            guard Double(passed) / Double(max(1, results.count)) >= value else {
                throw EvalError.missing("Pass rate below required \(value)")
            }
        }
        let protected = Set((args.string("require-tags") ?? "").split(separator: ",").map(String.init))
        let present = Set(results.map(\.item.tag))
        guard protected.isSubset(of: present),
              !results.contains(where: { protected.contains($0.item.tag) && !$0.passed }) else {
            throw EvalError.missing("Required tags missing or failing: \(protected.sorted())")
        }
    }

    static func emit(_ summary: String, details: [String] = []) {
        print(summary)
        if !details.isEmpty { print(details.joined(separator: "\n")) }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\n<!-- \(stamp) -->\n\(summary)\n"
        if let handle = try? FileHandle(forWritingTo: Paths.results) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? ("# Murmur eval results\n" + entry).write(to: Paths.results, atomically: true, encoding: .utf8)
        }
    }

    /// Neural voices (Aman) under host load have returned a truncated file — 0.46 s for a
    /// 2.5 s sentence — with exit status 0, which then sat in the TTS cache and showed up as a
    /// cleanup failure (`corr-month-1` heard only "April"). The file is accepted only when it is
    /// at least `minSecondsPerWord` per word (valid files go down to ~0.21 s/word, so 0.12 only
    /// catches gross truncation, not every case); otherwise it is deleted and retried after a
    /// pause. The structural fix is in `endToEnd`: synthesize before any inference runs.
    static let synthesisAttempts = 3
    static let minSecondsPerWord = 0.12

    static func synthesize(_ text: String, voice: String, to url: URL) throws {
        let minimum = Double(max(1, TextStats.wordCount(text))) * minSecondsPerWord
        for attempt in 1...synthesisAttempts {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw EvalError.missing("say failed for voice \(voice)") }
            let seconds = audioSeconds(url) ?? 0
            if seconds >= minimum { return }
            try? FileManager.default.removeItem(at: url)
            Thread.sleep(forTimeInterval: 1)
            FileHandle.standardError.write(Data(
                "say (\(voice)) returned \(String(format: "%.2f", seconds)) s for \(TextStats.wordCount(text)) words (attempt \(attempt)/\(synthesisAttempts)): \(text.prefix(60))…\n".utf8))
        }
        throw EvalError.missing("say kept returning truncated audio for voice \(voice): \(text.prefix(60))")
    }

    static func audioSeconds(_ url: URL) -> Double? {
        (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate }
    }

    static func upsample(_ samples: [Float], to rate: Double) throws -> [Float] {
        let converter = AudioConverter(sampleRate: rate)
        return try converter.resample(samples, from: 16_000)
    }

    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
    static func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
}

/// Parakeet via FluidAudio, as used by the app. Vocabulary boosting mirrors `SpeechEngine`'s
/// approach exactly (CTC 110M side model, loaded lazily, rebuilt when the vocabulary changes)
/// so `murmur-eval vocab` measures the same code path the app runs, not a second implementation.
actor Engine {
    private let manager: AsrManager
    private var boostingSession: VocabularyBoostingSession?
    private var boostingPasses: BoostingPasses?
    /// `SpeechEngine`'s order since 2026-11-07: the CTC pass starts with the primary pass (`BoostingPasses`). False runs
    /// the library's `VocabularyBoostingSession.rescore` after the primary pass, the order before (measurement only).
    var boostsAlongside = true
    func setBoostsAlongside(_ value: Bool) { boostsAlongside = value }
    private var boostingVocabulary: VocabularyContext?
    /// Mirrors `SpeechEngine`'s English-only drift guard: when set, every result is checked by
    /// `AsrDriftGuard` and, on drift, re-transcribed with Parakeet v2 (loaded lazily on the
    /// first drift, kept afterwards) — so evals measure the same path the app runs.
    let driftGuard: Bool
    private var fallback: Engine?
    private(set) var driftFallbackCount = 0
    private(set) var transcriptionCount = 0

    private init(manager: AsrManager, driftGuard: Bool) {
        self.manager = manager
        self.driftGuard = driftGuard
    }

    static func load(_ version: AsrModelVersion, driftGuard: Bool = false) async throws -> Engine {
        let models = try await AsrModels.downloadAndLoad(to: modelDirectory(for: version), version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var state = TdtDecoderState.make()
        _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
        return Engine(manager: manager, driftGuard: driftGuard && version != .v2)
    }

    /// Where to fetch a model the app hasn't already downloaded: FluidAudio's shared cache by
    /// default, or `$MURMUR_EVAL_MODELS_DIR` when set (so a one-off comparison model, e.g. v3 for
    /// `us-english`, can live in a scratch folder and be deleted afterwards). Models already in
    /// the shared cache are always used from there.
    static func modelDirectory(for version: AsrModelVersion) -> URL? {
        guard let root = ProcessInfo.processInfo.environment["MURMUR_EVAL_MODELS_DIR"], !root.isEmpty,
              !AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
        else { return nil }
        // FluidAudio downloads into the parent of this path, in a folder named after the repo.
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("\(version)")
    }

    /// Parses the `--models` / `--model` spelling used by the runners: `ultra+guard` (or
    /// `v3+guard`) is the guarded English-only configuration the app ships by default.
    static func load(named name: String) async throws -> Engine? {
        let parts = name.split(separator: "+").map(String.init)
        let version: AsrModelVersion
        switch parts.first ?? "" {
        case "v2": version = .v2
        case "v3": version = .v3
        case "ultra": version = .ultra
        case "redux": version = .redux
        default: return nil
        }
        return try await load(version, driftGuard: parts.dropFirst().contains("guard"))
    }

    /// "n/N" fallback summary for report lines; empty when the guard is off.
    var driftSummary: String {
        driftGuard ? ", drift fallback \(driftFallbackCount)/\(transcriptionCount)" : ""
    }

    func transcribe(_ samples: [Float]) async throws -> (String, Double) {
        try await transcribe(samples, vocabulary: .empty)
    }

    /// Transcribes and reports total wall-clock time (base ASR + drift fallback + boosting
    /// rescore, if any), matching what a real dictation experiences end to end.
    func transcribe(_ samples: [Float], vocabulary: VocabularyContext) async throws -> (String, Double) {
        let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
        let start = Date()
        let (result, rescored) = try await basePassAndRescore(padded, vocabulary: vocabulary)
        var text = result.text
        if let rescored { text = vocabulary.guarded(original: text, boosted: rescored) }
        return (text, Date().timeIntervalSince(start))
    }

    /// Loads the drift guard's v2 recogniser now, as the app's launch warm-up does, so no timed pass waits for it.
    func warmFallback() async throws {
        if driftGuard, fallback == nil { fallback = try await Engine.load(.v2) }
    }

    /// `release-paste`: `SpeechEngine.transcribeWithConfidence`'s release pass with its two stages timed apart, the
    /// primary pass (drift guard included) and the vocabulary rescore. Same result shape as the app's: confidences
    /// only when boosting left the text alone, and the unboosted text when it changed it.
    func releaseStages(_ samples: [Float], vocabulary: VocabularyContext) async throws
        -> (result: TranscriptionResult, baseMs: Double, boostMs: Double) {
        let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
        var baseMs = 0.0
        let start = ContinuousClock.now
        let (base, rescored) = try await basePassAndRescore(padded, vocabulary: vocabulary) {
            baseMs = ModelPace.ms(ContinuousClock.now - start)
        }
        let boostMs = ModelPace.ms(ContinuousClock.now - start) - baseMs
        let text = base.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = TranscriptionResult(text: text, confidences: base.tokenTimings.map(FluidAudioWordConfidence.aggregate))
        guard let rescored else { return (plain, baseMs, boostMs) }
        let boosted = vocabulary.guarded(original: text, boosted: rescored.trimmingCharacters(in: .whitespacesAndNewlines))
        guard boosted != text else { return (plain, baseMs, boostMs) }
        return (TranscriptionResult(text: boosted, unboosted: text), baseMs, boostMs)
    }

    /// The guarded primary pass and the vocabulary rescore: the rescored text when it changed, else nil. With
    /// `boostsAlongside` the CTC pass runs while the primary pass does, as `SpeechEngine` does. `primaryDone` runs
    /// when the primary pass (drift guard included) has its text.
    private func basePassAndRescore(
        _ padded: [Float], vocabulary: VocabularyContext, primaryDone: () -> Void = {}
    ) async throws -> (result: ASRResult, rescored: String?) {
        let wanted = !vocabulary.isEmpty
        let passes = wanted && boostsAlongside ? await boostingPassesFor(vocabulary) : nil
        let earlySpot = passes.map { passes in Task { await passes.spot(padded) } }
        let result: ASRResult
        do { result = try await guardedBasePass(padded) } catch { earlySpot?.cancel(); throw error }
        primaryDone()
        let text = result.text
        guard wanted, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let timings = result.tokenTimings,
              !timings.isEmpty else {
            earlySpot?.cancel()
            return (result, nil)
        }
        if let passes, let earlySpot {
            let rescored = await earlySpot.value.flatMap { passes.rescoredText(text, tokenTimings: timings, spot: $0) }
            return (result, rescored)
        }
        guard let session = await boostingSession(for: vocabulary),
              let output = await session.rescore(text: text, tokenTimings: timings, audioSamples: padded),
              output.wasModified else { return (result, nil) }
        return (result, output.text)
    }

    /// Exposes the same ASR → CTC rescore → BoostGuard path for local, synthetic probes.
    func vocabularyTrace(_ samples: [Float], vocabulary: VocabularyContext) async throws -> (
        base: String, drifted: String, rescored: String, guarded: String, confidenceWords: Int
    ) {
        let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
        let passes = !vocabulary.isEmpty && boostsAlongside ? await boostingPassesFor(vocabulary) : nil
        let earlySpot = passes.map { passes in Task { await passes.spot(padded) } }
        defer { earlySpot?.cancel() }
        var state = TdtDecoderState.make()
        var result = try await manager.transcribe(padded, decoderState: &state)
        transcriptionCount += 1
        let base = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if driftGuard, AsrDriftGuard.decision(for: base).needsFallback {
            if fallback == nil { fallback = try await Engine.load(.v2) }
            if let fallback {
                let recovered = try await fallback.transcribeRawResult(padded)
                if AsrDriftGuard.acceptsFallback(primary: base, fallback: recovered.text) {
                    result = recovered
                }
                driftFallbackCount += 1
            }
        }
        let drifted = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let confidenceWords = result.tokenTimings.map { FluidAudioWordConfidence.aggregate($0).count } ?? 0
        guard !vocabulary.isEmpty, !drifted.isEmpty, let timings = result.tokenTimings, !timings.isEmpty
        else { return (base, drifted, drifted, drifted, confidenceWords) }
        let rescoredText: String?
        if let passes, let earlySpot {
            rescoredText = await earlySpot.value.flatMap { passes.rescoredText(drifted, tokenTimings: timings, spot: $0) }
        } else if let session = await boostingSession(for: vocabulary) {
            rescoredText = await session.rescore(text: drifted, tokenTimings: timings, audioSamples: padded)?.text
        } else {
            rescoredText = nil
        }
        guard let rescoredText else { return (base, drifted, drifted, drifted, confidenceWords) }
        let boosted = rescoredText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base, drifted, boosted, vocabulary.guarded(original: drifted, boosted: boosted), confidenceWords)
    }

    func transcribeLong(_ samples: [Float]) async throws -> String {
        try await transcribe(samples).0
    }

    /// Voice-trace entry point: the guarded base pass with its intermediates exposed —
    /// the Ultra text, the guard's decision on it, and the final (possibly v2-fallback) text.
    /// Same inference as `transcribe(_:vocabulary:)` with an empty vocabulary and no boosting;
    /// additive only, the live path and every other runner are untouched.
    func transcribeTrace(_ samples: [Float]) async throws -> (
        base: String, decision: AsrDriftGuard.Decision, text: String, seconds: Double
    ) {
        let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
        let start = Date()
        var state = TdtDecoderState.make()
        let base = try await manager.transcribe(padded, decoderState: &state)
        transcriptionCount += 1
        let decision = AsrDriftGuard.decision(for: base.text)
        var text = base.text
        if driftGuard, decision.needsFallback {
            if fallback == nil { fallback = try await Engine.load(.v2) }
            if let fallback {
                let recovered = try await fallback.transcribeRawResult(padded).text
                if AsrDriftGuard.acceptsFallback(primary: base.text, fallback: recovered) {
                    text = recovered
                }
                driftFallbackCount += 1
            }
        }
        return (base.text, decision, text, Date().timeIntervalSince(start))
    }

    /// Raw ASR result (text, token timings, no vocabulary boosting) for callers that need more
    /// than the plain-text/latency pair `transcribe` returns — currently only
    /// `ConfidenceCalibration`, which needs `tokenTimings` to compute word confidences without
    /// boosting muddying the signal.
    func transcribeRawResult(_ samples: [Float]) async throws -> ASRResult {
        let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
        return try await guardedBasePass(padded)
    }

    /// The primary model's pass plus, when `driftGuard` is on and `AsrDriftGuard` flags the
    /// result, the same audio re-run through v2 — the exact order `SpeechEngine` uses, so
    /// confidences (computed by callers from this result) belong to the text actually used.
    private func guardedBasePass(_ padded: [Float]) async throws -> ASRResult {
        var state = TdtDecoderState.make()
        var result = try await manager.transcribe(padded, decoderState: &state)
        transcriptionCount += 1
        guard driftGuard, AsrDriftGuard.decision(for: result.text).needsFallback else { return result }
        if fallback == nil { fallback = try await Engine.load(.v2) }
        if let fallback {
            let recovered = try await fallback.transcribeRawResult(padded)
            if AsrDriftGuard.acceptsFallback(primary: result.text, fallback: recovered.text) {
                result = recovered
            }
            driftFallbackCount += 1
        }
        return result
    }

    /// The split passes for `vocabulary`, built with its session.
    private func boostingPassesFor(_ vocabulary: VocabularyContext) async -> BoostingPasses? {
        guard await boostingSession(for: vocabulary) != nil else { return nil }
        return boostingPasses
    }

    /// Builds (once) or reuses a `VocabularyBoostingSession` for `vocabulary`. Returns nil on
    /// any load failure rather than throwing, matching `SpeechEngine`'s best-effort contract.
    private func boostingSession(for vocabulary: VocabularyContext) async -> VocabularyBoostingSession? {
        if let boostingSession, boostingVocabulary == vocabulary { return boostingSession }
        do {
            let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let terms = vocabulary.terms.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases) }
            // Matches SpeechEngine's production config: the acoustic spotter-rescue overfires
            // badly on small Dictionary-sized vocabularies (see SpeechEngine's comment and the
            // `vocab` command's own README note), so evals must disable it too or they'd measure
            // a different pipeline than the app actually runs.
            let config = VocabularyRescorer.Config(spotterRescueEnabled: false)
            let session = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctcModels, config: config)
            boostingSession = session
            boostingPasses = try await BoostingPasses(session: session, models: ctcModels, config: config)
            boostingVocabulary = vocabulary
            return session
        } catch {
            FileHandle.standardError.write(Data("  ! vocabulary boosting model load failed: \(error.localizedDescription)\n".utf8))
            return nil
        }
    }
}

// MARK: - Challenge set (after Wispr's Canto eval): noise, overlapping speech, low volume, short dictations

extension Runners {
    static let shortPhrases = [
        "Yes.", "No.", "Thanks!", "Sounds good.", "On it.", "Ship it.", "Call me.", "Perfect.", "Got it.",
        "See you soon.", "Approved.", "Not today.", "Done.", "Maybe later.", "Love it.", "Running late.",
        "Agreed.", "Let's go.", "Good morning.", "Thank you so much.",
    ]

    static func challenge(_ args: Arguments) async throws {
        let clips = try Array(Dataset.librispeechClean.load(root: Paths.data).prefix(args.int("limit") ?? 60))
        // `--guard` runs the English-only default configuration (Ultra + v2 drift fallback).
        let engine = try await Engine.load(args.model, driftGuard: args.flag("guard"))
        let pipeline = DictationPipeline(transcriber: engine)
        var generator = SeededNoise(seed: 42)
        let audio = try clips.map { try AudioConverter().resampleAudioFile(path: $0.audioPath) }

        // Runs through the shared production pipeline (normalize -> ASR), so the challenge set
        // reflects the same path a real dictation takes, and reports the gate's own pass/fail
        // count alongside WER: a condition can look good on WER while quietly being gated out
        // more often than it should (or vice versa).
        func run(_ name: String, _ transform: (Int, [Float]) -> [Float]) async throws -> String {
            var pairs: [(reference: String, hypothesis: String)] = []
            var gatePasses = 0
            for (index, clip) in clips.enumerated() {
                let samples = transform(index, audio[index])
                let gate = SpeechGate.evaluate(samples)
                if gate.hasSpeech { gatePasses += 1 }
                let text = try await pipeline.transcribeRaw(samples)
                pairs.append((clip.reference, text))
            }
            return "  - \(name): \(percent(EvalMetrics.corpusWER(pairs))) WER, gate passed \(gatePasses)/\(clips.count)"
        }

        var lines: [String] = []
        lines.append(try await run("clean") { _, samples in samples })
        lines.append(try await run("white noise, 10 dB SNR") { _, samples in mix(samples, generator.noise(count: samples.count), snrDB: 10) })
        lines.append(try await run("white noise, 0 dB SNR") { _, samples in mix(samples, generator.noise(count: samples.count), snrDB: 0) })
        lines.append(try await run("another speaker talking, 5 dB") { index, samples in
            mix(samples, loop(audio[(index + 7) % audio.count], to: samples.count), snrDB: 5)
        })
        lines.append(try await run("very quiet (−30 dB, far-field/whisper level)") { _, samples in samples.map { $0 * 0.03 } })

        // Short dictations, spoken by several synthetic voices.
        let folder = Paths.data.appendingPathComponent("tts-short", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let voices = ["Samantha", "Daniel", "Karen", "Moira", "Aman"]
        var shortPairs: [(reference: String, hypothesis: String)] = []
        var exact = 0
        var shortGatePasses = 0
        for (index, phrase) in shortPhrases.enumerated() {
            let voice = voices[index % voices.count]
            let url = folder.appendingPathComponent("short-\(index)-\(voice).wav")
            if !FileManager.default.fileExists(atPath: url.path) { try synthesize(phrase, voice: voice, to: url) }
            let samples = try AudioConverter().resampleAudioFile(url)
            if SpeechGate.evaluate(samples).hasSpeech { shortGatePasses += 1 }
            let text = try await pipeline.transcribeRaw(samples)
            shortPairs.append((phrase, text))
            if EvalMetrics.wordsMatch(phrase, text) { exact += 1 }
        }
        lines.append("  - short 1–3 word dictations: \(percent(EvalMetrics.corpusWER(shortPairs))) WER, \(exact)/\(shortPhrases.count) exactly right, gate passed \(shortGatePasses)/\(shortPhrases.count)")

        // Negative set: pure room noise and digital silence, which must never pass the gate —
        // a false-positive here means a silent or noise-only recording would be sent to ASR
        // and potentially inserted as garbage text.
        lines.append(try await negativeSet())

        let label = args.flag("guard") ? "\(args.modelName)+guard" : args.modelName
        let driftLine = engine.driftGuard ?"\n- Drift guard: fell back to v2 on \(await engine.driftFallbackCount)/\(await engine.transcriptionCount) transcriptions" : ""
        emit("### Challenge set · \(label) · \(clips.count) LibriSpeech clips per condition\n- WER by condition:\n" + lines.joined(separator: "\n") + driftLine)
    }

    /// Room noise (several levels) and digital silence: recordings with no speech in them.
    /// The gate must fail all of these; any pass is a false positive that would otherwise send
    /// silence/noise to ASR and risk inserting hallucinated text into the user's document.
    static func negativeSet() async throws -> String {
        var generator = SeededNoise(seed: 99)
        let oneSecond = 16_000
        var cases: [(name: String, samples: [Float])] = [
            ("digital silence", [Float](repeating: 0, count: oneSecond * 3)),
            ("quiet room (very low noise floor)", generator.noise(count: oneSecond * 3).map { $0 * 0.0003 }),
            ("noisy room (fan/HVAC-level noise)", generator.noise(count: oneSecond * 3).map { $0 * 0.0015 }),
        ]
        // A near-silent recording with one stray click (a desk bump, a key click) — the sort of
        // clip a fixed peak threshold used to pass but should still fail on active-frame share.
        var click = [Float](repeating: 0, count: oneSecond * 2)
        for i in 0..<320 { click[i + oneSecond] = 0.4 }
        cases.append(("near-silence with a single click", click))

        var falsePositives = 0
        for (name, samples) in cases {
            let gate = SpeechGate.evaluate(samples)
            if gate.hasSpeech {
                falsePositives += 1
                FileHandle.standardError.write(Data("  ! false positive: \"\(name)\" passed the gate (\(gate.metrics.logSummary))\n".utf8))
            }
        }
        return "  - noise-only negative set: gate correctly rejected \(cases.count - falsePositives)/\(cases.count) (\(falsePositives) false positive(s))"
    }

    /// Mixes `noise` into `signal` at the given signal-to-noise ratio.
    static func mix(_ signal: [Float], _ noise: [Float], snrDB: Double) -> [Float] {
        let signalPower = Double(StreamingResampler.rms(signal))
        let noisePower = Double(StreamingResampler.rms(noise))
        guard noisePower > 0 else { return signal }
        let gain = Float(signalPower / (noisePower * pow(10, snrDB / 20)))
        return zip(signal, noise).map { $0 + $1 * gain }
    }

    static func loop(_ samples: [Float], to count: Int) -> [Float] {
        guard !samples.isEmpty else { return [Float](repeating: 0, count: count) }
        return (0..<count).map { samples[$0 % samples.count] }
    }
}

/// Deterministic noise so challenge runs are comparable across changes.
struct SeededNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func noise(count: Int) -> [Float] {
        (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 1) % 2_000_001) / 1_000_000 - 1
        }
    }
}

// MARK: - Whispered speech

extension Runners {
    static let whisperPhrases = [
        "This looks great to me.", "Can you send me the report by Friday?", "Let's meet at nine tomorrow.",
        "I'll call you back in five minutes.", "Thanks for the quick turnaround.", "Please add milk and eggs to the list.",
        "The build is failing on the main branch.", "Sounds good, see you then.", "Can we move the meeting to three?",
        "I'm running a little late today.", "Let me know what you think.", "Ship it once the tests pass.",
    ]

    /// Whispered dictations (macOS "Whisper" voice, played back quietly) through each setup.
    /// Runs through `DictationPipeline` (shared with the app) rather than calling the engine
    /// directly, so this reports exactly what a real whispered dictation would experience:
    /// the gate's pass/fail decision plus `LoudnessNormalizer`'s output feeding the ASR model.
    static func whisper(_ args: Arguments) async throws {
        let folder = Paths.data.appendingPathComponent("tts-whisper", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var clips: [(String, [Float])] = []
        for (index, phrase) in whisperPhrases.enumerated() {
            let url = folder.appendingPathComponent("whisper-\(index).wav")
            if !FileManager.default.fileExists(atPath: url.path) { try synthesize(phrase, voice: "Whisper", to: url) }
            // A real whisper reaches the mic ~25-30 dB quieter than normal speech.
            clips.append((phrase, try AudioConverter().resampleAudioFile(url).map { $0 * 0.06 }))
        }
        var lines: [String] = []
        let setups: [(version: AsrModelVersion, guard: Bool, name: String)] = [
            (.v2, false, "parakeet v2 (English)"),
            (.ultra, false, "parakeet ultra (25 langs)"),
            (.ultra, true, "parakeet ultra + drift guard (English-only default)"),
        ]
        for setup in setups {
            let engine = try await Engine.load(setup.version, driftGuard: setup.guard)
            let pipeline = DictationPipeline(transcriber: engine)
            for normalize in [false, true] {
                var pairs: [(reference: String, hypothesis: String)] = []
                var foreign = 0
                var gatePasses = 0
                for (phrase, samples) in clips {
                    if SpeechGate.evaluate(samples).hasSpeech { gatePasses += 1 }
                    let text = normalize ? try await pipeline.transcribeRaw(samples) : try await engine.transcribe(samples)
                    pairs.append((phrase, text))
                    if isNonEnglish(text) { foreign += 1 }
                }
                let name = "\(setup.name)\(normalize ? " + gain normalization" : "")"
                lines.append("  - \(name): \(percent(EvalMetrics.corpusWER(pairs))) WER, \(foreign)/\(clips.count) came out in another language, gate passed \(gatePasses)/\(clips.count)\(await engine.driftSummary)")
            }
        }
        lines.append(try await negativeSet())
        emit("### Whispered dictation · \(clips.count) phrases\n" + lines.joined(separator: "\n"))
    }

    /// "Came out in another language" for reports: a non-Latin letter anywhere, or a confident
    /// non-English language ID on the text. On 1–3 word outputs `NLLanguageRecognizer` is not
    /// trustworthy on its own (the first drift-probe run flagged v2's "10 minutes." and "Ping
    /// Priya" — v2 has no language ID and cannot drift), so there a non-English ID only counts
    /// when no word is in the English dictionary either; a real short drift ("Tak", "Merci
    /// beaucoup") still trips it.
    static func isNonEnglish(_ text: String) -> Bool {
        if text.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.value > 0x02AF && !(0x1E00...0x1EFF).contains($0.value) }) {
            return true
        }
        guard let detected = LanguageDetector.detect(text), !detected.isEnglish else { return false }
        let words = text.split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
            .filter { $0.contains(where: \.isLetter) }
        if words.count > AsrDriftGuard.shortInputWordLimit { return true }
        return !words.contains { BoostGuard.isEnglishWord($0, in: BoostGuard.systemWords) }
    }
}
