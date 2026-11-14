import FluidAudio
import Foundation
import MurmurCore

/// Three ingestion paths (founder scale-up 2026-09-29), same aggregate shape
/// (per-corpus WER, cleanup win/loss, guard-fire, backend mix) everywhere:
///
/// (a) PARAKET-DIRECT (`--direct`): clip → `Engine` direct, no audio plumbing — maximum
///     scale first. The trace records `feed: "direct"` so it never mixes silently with (b).
/// (b) MOCK-MIC (default): clip file → `MockMicFeed` (where `AudioCapture` would deliver
///     samples) → `Engine` → `DictationPipeline`. Fidelity over scale.
/// (c) ACOUSTIC LOOPBACK (founder-run): `scripts/acoustic-loopback.sh` plays dataset clips
///     through the Mac speakers while the founder dictates through the LIVE app's real mic
///     path into a scratch doc (one line per clip); `voice-trace score-lines` aligns those
///     lines with the transcripts and reports WER. Agents NEVER run the live app (one-Hushy
///     rule) — the script + instructions are the kit, the founder's results file closes it.
///
/// and scored at every stage: raw ASR + WER vs transcript, drift-guard decision + fallback
/// taken, cleanup output per backend, guard rejections with `why=`, backend actually used,
/// end-to-end verdict — plus aggregates (WER by corpus, cleanup win/loss vs rules-only,
/// guard-fire rate, backend mix).
///
/// PRIMARY corpus (per founder redirect 2026-09-29): founder-supplied local WAV + transcript
/// pairs — same accent/mic/dictation style as the failures. Web corpora are breadth coverage
/// only. Clips are EVAL ONLY, never training data (see `.claude/AGENTS.md`).
///
///   murmur-eval voice-trace [--local-dir path] [--dataset a,b] [--no-web] [--direct]
///       [--model ultra+guard] [--limit 10] [--report path]
///   murmur-eval voice-trace score-lines --lines results.txt [--local-dir path | --dataset a,b]
///       [--limit N] [--report path]
///
/// `--local-dir`: folder with `transcripts.json` (`{"<basename>": "<exact words spoken>"}`)
///   plus one audio file per key (any `AVAudioFile`-decodable format; 16 kHz mono WAV
///   preferred). The folder lives outside git (e.g. `Evals/data/voice-trace-local/`, which is
///   gitignored with the rest of `Evals/data/`), is never committed, and never leaves the Mac.
/// `--dataset`: web breadth corpus — one `Dataset` raw value or several comma-separated
///   (e.g. `librispeech-clean,librispeech-other,accents`); default `edacc-indian`,
///   Indian-accented English, ungated — the highest founder value; falls back to
///   `librispeech-clean` when the download yields nothing, e.g. no network. LDC-licensed
///   sets (Switchboard/DRES) were never wired into `Dataset` and stay OUT.
/// `--model`: ASR engine (default `ultra+guard`, the app's English-only default).
/// The cleanup backend is the standard `--backend` (`apple`, `none`, `mlx`, `local`, or
/// `remote` for the GPU box's mlx4 server per `.claude/GPU-TRAINING.md` — candidate dev
/// evals go remote to spare the founder's Mac; GPU rules hold: no sudo, only
/// `~/hushy-train/`, shared FIFO lock, Tailscale-only).
/// Standalone only — never wired into `scripts/run-evals.sh`, which must run in seconds
/// without network/audio (this needs both: downloads + local ASR inference).
enum VoiceTraceRunner {
    // MARK: Clip sources

    struct VoiceClip: Sendable {
        let id: String
        let corpus: String
        let audioPath: String
        let reference: String
        /// Accent/speaker group label when the dataset provides one (e.g. EdAcc) — drives
        /// the per-group breakdown so accents are never pooled into one misleading mean.
        let group: String?
    }

    /// Founder-supplied local pairs: `transcripts.json` maps audio basename (without
    /// extension, or with) to the exact words spoken. Deterministic (sorted) order.
    static func loadLocalPairs(dir: URL) throws -> [VoiceClip] {
        let sidecar = dir.appendingPathComponent("transcripts.json")
        let map = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: sidecar))
        let extensions = ["wav", "mp3", "m4a", "aiff", "aif", "flac", "caf"]
        var clips: [VoiceClip] = []
        for key in map.keys.sorted() {
            guard let reference = map[key], !reference.isEmpty else { continue }
            var resolved: String?
            if key.contains(".") {
                let candidate = dir.appendingPathComponent(key).path
                if FileManager.default.fileExists(atPath: candidate) { resolved = candidate }
            } else {
                for ext in extensions {
                    let candidate = dir.appendingPathComponent("\(key).\(ext)").path
                    if FileManager.default.fileExists(atPath: candidate) { resolved = candidate; break }
                }
            }
            guard let audioPath = resolved else {
                FileHandle.standardError.write(Data(
                    "  ! voice-trace: no audio file for local key \"\(key)\" (skipped)\n".utf8))
                continue
            }
            clips.append(VoiceClip(
                id: "local-\(key)", corpus: "local", audioPath: audioPath, reference: reference,
                group: nil))
        }
        return clips
    }

    /// Web breadth corpus through the same resumable `Downloader` machinery every other
    /// runner uses — no parallel downloader. Applies `Runners.asr`'s segment-tag cleanup so
    /// WER is comparable to the numbers `murmur-eval asr` reports.
    static func loadOrDownload(_ dataset: Dataset, limit: Int) async throws -> [VoiceClip] {
        do {
            if !FileManager.default.fileExists(atPath: dataset.manifest(root: Paths.data).path) {
                print("Downloading \(dataset.summary) (up to \(limit) clips)…")
                let result = try await Downloader.download(dataset, limit: limit, root: Paths.data)
                print("  \(result.statusLine)")
            }
            return try dataset.load(root: Paths.data)
                .filter { !$0.reference.contains("IGNORE_TIME_SEGMENT") }
                .map { clip in
                    VoiceClip(
                        id: clip.id, corpus: dataset.rawValue, audioPath: clip.audioPath,
                        reference: clip.reference.replacingOccurrences(
                            of: "<[^>]+>", with: " ", options: .regularExpression),
                        group: clip.group)
                }
                .filter { !$0.reference.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(limit)
                .map { $0 }
        } catch {
            FileHandle.standardError.write(Data(
                "  ! voice-trace: \(dataset.rawValue) unavailable (\(error.localizedDescription))\n".utf8))
            return []
        }
    }

    // MARK: Trace assembly (pure — unit-tested without audio, network or models)

    struct CleanupOutput: Codable, Sendable {
        let backend: String
        let text: String
        let wer: Double
        let usedModel: Bool
        let rejection: String?
    }

    struct Trace: Codable, Sendable {
        let id: String
        let corpus: String
        let reference: String
        /// Accent/speaker group label when the dataset provides one.
        let group: String?
        /// Ingestion path: `"mock-mic"`, `"direct"`, or `"loopback"`.
        let feed: String
        let micSeconds: Double
        /// The Ultra pass, before the drift guard runs.
        let baseText: String
        /// `accept` or `fallback(<reason>)`.
        let driftDecision: String
        let fallbackTaken: Bool
        /// Final ASR text (post-fallback) — what cleanup sees.
        let rawText: String
        let rawWER: Double
        let rules: CleanupOutput
        let main: CleanupOutput
        /// Transcript-fidelity verdict: cleaned text matches the spoken transcript under
        /// the product normalizer. This does not score grammar repair or intended fluent text.
        let passed: Bool
        /// Cleanup vs rules-only: `win` (main WER lower), `loss` (higher), `tie`.
        let vsRules: String
        let asrMs: Double
        let totalMs: Double
    }

    static func decisionLabel(_ decision: AsrDriftGuard.Decision) -> String {
        switch decision {
        case .accept: "accept"
        case .fallback(let reason): "fallback(\(reason.rawValue))"
        }
    }

    static func assemble(
        id: String, corpus: String, reference: String, group: String? = nil,
        feed: String = "mock-mic", micSeconds: Double,
        baseText: String, decision: AsrDriftGuard.Decision, fallbackTaken: Bool,
        rawText: String, rulesText: String, rulesRejection: String?,
        mainBackend: String, mainText: String, mainUsedModel: Bool, mainRejection: String?,
        asrMs: Double, totalMs: Double
    ) -> Trace {
        let rawWER = EvalMetrics.wer(reference: reference, hypothesis: rawText)
        let rulesWER = EvalMetrics.wer(reference: reference, hypothesis: rulesText)
        let mainWER = EvalMetrics.wer(reference: reference, hypothesis: mainText)
        let vsRules: String
        if mainWER < rulesWER - 1e-9 { vsRules = "win" }
        else if mainWER > rulesWER + 1e-9 { vsRules = "loss" }
        else { vsRules = "tie" }
        return Trace(
            id: id, corpus: corpus, reference: reference, group: group, feed: feed,
            micSeconds: micSeconds,
            baseText: baseText, driftDecision: decisionLabel(decision), fallbackTaken: fallbackTaken,
            rawText: rawText, rawWER: rawWER,
            rules: CleanupOutput(
                backend: "rules", text: rulesText, wer: rulesWER,
                usedModel: false, rejection: rulesRejection),
            main: CleanupOutput(
                backend: mainBackend, text: mainText, wer: mainWER,
                usedModel: mainUsedModel, rejection: mainRejection),
            passed: EvalMetrics.wordsMatch(reference, mainText),
            vsRules: vsRules, asrMs: asrMs, totalMs: totalMs)
    }

    // MARK: Clip loading (shared by the live paths and `score-lines`)

    static func loadClips(_ args: Arguments, limit: Int) async throws -> [VoiceClip] {
        // PRIMARY first: founder-supplied local pairs. Web breadth after, unless --no-web.
        var clips: [VoiceClip] = []
        if let localDir = args.string("local-dir") {
            let local = try loadLocalPairs(dir: URL(fileURLWithPath: localDir))
            print("voice-trace: \(local.count) local pair(s) under \(localDir) (PRIMARY corpus)")
            clips += local.prefix(limit)
        }
        if !args.flag("no-web") {
            // English breadth scope (founder directive 2026-09-29): any combination of the
            // open-licensed English sets already wired into `Dataset` — LibriSpeech
            // test-clean/test-other, EdAcc all accents + the Indian/US subsets, VoxPopuli
            // English, Earnings-22, TED-LIUM, People's Speech, Common Voice imports, FLEURS
            // en-US. LDC-licensed sets (Switchboard/DRES) were never wired in and stay OUT.
            // Comma-separated `--dataset` runs several in one invocation; aggregates are
            // reported per corpus (and per accent group), never pooled into one mean.
            var web: [VoiceClip] = []
            if let names = args.string("dataset") {
                for name in names.split(separator: ",").map(String.init) {
                    guard let dataset = Dataset(rawValue: name) else {
                        FileHandle.standardError.write(Data(
                            "  ! voice-trace: unknown dataset \"\(name)\" (skipped)\n".utf8))
                        continue
                    }
                    web += try await loadOrDownload(dataset, limit: limit)
                }
            } else {
                let indian = try await loadOrDownload(.edaccIndian, limit: limit)
                if !indian.isEmpty {
                    web = indian
                } else {
                    FileHandle.standardError.write(Data(
                        "  ! voice-trace: edacc-indian yielded nothing — falling back to librispeech-clean\n".utf8))
                    web = try await loadOrDownload(.librispeechClean, limit: limit)
                }
            }
            clips += web
        }
        guard !clips.isEmpty else {
            throw EvalError.missing(
                "voice-trace: no clips — pass --local-dir <folder> (see Evals/README.md) or check network access to datasets-server.huggingface.co")
        }
        return clips
    }

    // MARK: Path (c): score the founder's acoustic-loopback results file
    //
    // `scripts/acoustic-loopback.sh` plays clips through the Mac speakers while the founder
    // dictates through the LIVE app into a scratch doc — one pasted line per played clip, in
    // order, blank line for a skipped clip (never delete a line: alignment is positional).
    // This scores that file against the same clips' transcripts: no audio, no models, no
    // network when the manifests are cached — the live app's real mic path is the backend,
    // reported as `live-app`, with guard/backend mix unknown.

    static func scoreLines(_ args: Arguments) throws {
        guard let linesPath = args.string("lines") else {
            throw EvalError.missing("usage: murmur-eval voice-trace score-lines --lines <results.txt> [--local-dir path | --dataset a,b] [--limit N]")
        }
        let rawLines = try String(contentsOfFile: linesPath, encoding: .utf8)
            .components(separatedBy: .newlines)
        // A trailing newline is not a skipped clip.
        let lines = rawLines.last?.isEmpty == true ? Array(rawLines.dropLast()) : rawLines
        // Loading is async (web manifests may download); bridge it synchronously — this mode
        // does no inference itself, so blocking here costs nothing on the Mac.
        let limit = args.int("limit") ?? lines.count
        let loaded: [VoiceClip] = try runBlocking { try await loadClips(args, limit: limit) }
        guard loaded.count == lines.count else {
            throw EvalError.missing(
                "voice-trace score-lines: \(lines.count) result line(s) but \(loaded.count) clip(s) — one line per played clip, blank line to skip, in order (see scripts/acoustic-loopback.sh)")
        }
        var traces: [Trace] = []
        for (clip, line) in zip(loaded, lines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            let wer = EvalMetrics.wer(reference: clip.reference, hypothesis: text)
            traces.append(Trace(
                id: clip.id, corpus: clip.corpus, reference: clip.reference, group: clip.group,
                feed: "loopback", micSeconds: 0,
                baseText: text, driftDecision: "live-app", fallbackTaken: false,
                rawText: text, rawWER: wer,
                rules: CleanupOutput(backend: "live-app", text: text, wer: wer, usedModel: false, rejection: nil),
                main: CleanupOutput(backend: "live-app", text: text, wer: wer, usedModel: false, rejection: nil),
                passed: EvalMetrics.wordsMatch(clip.reference, text),
                vsRules: "n/a", asrMs: 0, totalMs: 0))
        }
        report(traces: traces, model: "live-app (acoustic loopback)")
        if let path = args.string("report") {
            try writeReport(traces: traces, model: "live-app (acoustic loopback)", path: path, args: args)
        }
    }

    /// Runs an async closure synchronously (for `score-lines`, which needs the async clip
    /// loader but performs no inference of its own). The result crosses the `Task`
    /// boundary in the harness's own `LockedValue`, so Swift 6 sees only `Sendable`
    /// captures — no data race.
    private static func runBlocking<T: Sendable>(_ work: @Sendable @escaping () async throws -> T) throws -> T {
        let box = LockedValue<Result<T, Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let outcome: Result<T, Error>
            do { outcome = .success(try await work()) }
            catch { outcome = .failure(error) }
            box.update { $0 = outcome }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.update({ $0 }) else {
            throw EvalError.missing("voice-trace score-lines: internal synchronization error")
        }
        return try result.get()
    }

    // MARK: Command (paths a + b)

    static func run(_ args: Arguments) async throws {
        if args.positional.first == "score-lines" { return try scoreLines(args) }
        guard let settings = try Runners.audioCleanupSettings(args) else {
            throw EvalError.missing("voice-trace requires cleanup settings")
        }
        let limit = args.int("limit") ?? 10
        let modelName = args.string("model") ?? "ultra+guard"
        guard let engine = try await Engine.load(named: modelName) else {
            throw EvalError.missing("voice-trace: unknown --model \(modelName) (expected v2|v3|ultra[+guard])")
        }
        let backendLabel = args.string("backend") ?? "apple"
        let strategy = Runners.audioCleanupStrategy(args, settings: settings)
        let cleaner = args.makeCleaner()
        cleaner.prewarm(prefixesFor: settings.cleanupOptions.level,
                        grammarContract: settings.cleanupOptions.grammarContract)
        let pipeline = DictationPipeline(transcriber: engine, cleaner: cleaner)
        let clips = try await loadClips(args, limit: limit)

        var traces: [Trace] = []
        // Path (a) parakeet-direct: file straight to the engine, no audio plumbing, for
        // scale. Path (b) mock-mic (default): through `MockMicFeed`, for fidelity.
        let direct = args.flag("direct")
        let feed = direct ? "direct" : "mock-mic"
        for clip in clips {
            let clipStart = Date()
            let url = URL(fileURLWithPath: clip.audioPath)
            let samples: [Float]
            let micSeconds: Double
            if direct {
                samples = try AudioConverter().resampleAudioFile(url)
                micSeconds = Double(samples.count) / StreamingResampler.targetRate
            } else {
                let drained = try MockMicFeed.drain(file: url)
                micSeconds = Double(drained.count) / StreamingResampler.targetRate
                samples = drained
            }
            // Same normalization the production `run(samples:)` applies before ASR.
            let normalized = LoudnessNormalizer.normalize(samples)
            let fallbacksBefore = await engine.driftFallbackCount
            let (base, decision, raw, asrSeconds) = try await engine.transcribeTrace(normalized)
            let fallbackTaken = await engine.driftFallbackCount > fallbacksBefore
            let rulesResult = await pipeline.clean(raw, settings: settings, strategy: .rules)
            let mainResult = await pipeline.clean(raw, settings: settings, strategy: strategy)
            traces.append(assemble(
                id: clip.id, corpus: clip.corpus, reference: clip.reference, group: clip.group,
                feed: feed, micSeconds: micSeconds,
                baseText: base, decision: decision, fallbackTaken: fallbackTaken,
                rawText: raw, rulesText: rulesResult.text, rulesRejection: rulesResult.rejection,
                mainBackend: "\(backendLabel)/\(strategy.rawValue)", mainText: mainResult.text,
                mainUsedModel: mainResult.usedModel, mainRejection: mainResult.rejection,
                asrMs: asrSeconds * 1000, totalMs: Date().timeIntervalSince(clipStart) * 1000))
        }

        report(traces: traces, model: modelName, cleanupOptions: settings.cleanupOptions, strategy: strategy)
        if let path = args.string("report") {
            try writeReport(traces: traces, model: modelName, path: path, args: args, cleanupOptions: settings.cleanupOptions, strategy: strategy)
        }
    }

    // MARK: Reporting

    private static func report(
        traces: [Trace], model: String, cleanupOptions: CleanupOptions? = nil,
        strategy: SmartCleaner.Strategy? = nil
    ) {
        let byCorpus = Dictionary(grouping: traces, by: \.corpus).sorted { $0.key < $1.key }
        let corpusLines = byCorpus.flatMap { corpus, items -> [String] in
            let rawWER = EvalMetrics.corpusWER(items.map { ($0.reference, $0.rawText) })
            let cleanWER = EvalMetrics.corpusWER(items.map { ($0.reference, $0.main.text) })
            var lines = [
                "  - \(corpus): \(items.count) clips · raw WER \(Runners.percent(rawWER)) → cleaned WER \(Runners.percent(cleanWER))",
            ]
            // Parity framing (site rule: "score in the same range", never single-accent
            // superiority): accent groups inside a corpus are reported separately, never
            // pooled — groups with ≥ 2 clips each.
            let byGroup = Dictionary(grouping: items, by: { $0.group ?? "unlabeled" })
                .filter { $0.value.count >= 2 }.sorted { $0.key < $1.key }
            for (group, groupItems) in byGroup {
                let groupWER = EvalMetrics.corpusWER(groupItems.map { ($0.reference, $0.rawText) })
                lines.append("      · \(group): \(groupItems.count) clips · raw WER \(Runners.percent(groupWER))")
            }
            return lines
        }
        let wins = traces.filter { $0.vsRules == "win" }.count
        let losses = traces.filter { $0.vsRules == "loss" }.count
        let ties = traces.filter { $0.vsRules == "tie" }.count
        let guardFires = traces.filter(\.fallbackTaken).count
        let modelUsed = traces.filter(\.main.usedModel).count
        let rejections = Dictionary(grouping: traces.compactMap(\.main.rejection), by: { $0 })
            .map { k, v in "\(k)×\(v.count)" }.sorted()
        let latencies = traces.map(\.totalMs)
        let feed = traces.first?.feed ?? "mock-mic"
        // Path (c) loopback scores the live app's end state only: no stage split, no guard
        // visibility — report what is known instead of zeros that would mislead.
        let loopback = !traces.isEmpty && traces.allSatisfy { $0.feed == "loopback" }
        let cleanupLine = loopback
            ? "- Cleanup/backend: live app end state only (stage split unknown from outside)"
            : "- Cleanup vs rules-only: \(wins) win / \(losses) loss / \(ties) tie"
        let guardLine = loopback
            ? "- Guard-fire rate: unknown (live app internals not visible)"
            : "- Guard-fire rate: \(guardFires)/\(traces.count) fell back (~0 expected on English)"
        let backendLine = loopback
            ? "- Backend mix: live app (unknown from outside)"
            : "- Backend mix: model answered \(modelUsed)/\(traces.count)\(rejections.isEmpty ? "" : " · rejections: " + rejections.joined(separator: ", "))"
        let latencyLine = loopback
            ? "- Latency: n/a (founder-paced playback)"
            : "- Latency per clip: p50 \(Runners.ms(EvalMetrics.percentile(latencies, 0.5))), p95 \(Runners.ms(EvalMetrics.percentile(latencies, 0.95)))"
        let summary = """
            ### Voice trace · \(model) · \(traces.count) clips (\(feed) → ASR+guard → cleanup)
            - Transcript fidelity WER by corpus (raw → cleaned; spoken reference, not grammar quality):
            \(corpusLines.joined(separator: "\n"))
            \(cleanupLine)
            - Cleanup settings: \(cleanupOptions.map(Runners.cleanupSettingsLabel) ?? "unknown (live app)")
            - Cleanup strategy: \(strategy?.rawValue ?? "unknown (live app)")
            \(guardLine)
            \(backendLine)
            \(latencyLine)
            """
        let details = traces.map { trace in
            """
              \(trace.passed ? "✓" : "✘") \(trace.id) [\(trace.corpus)] \(trace.vsRules) vs rules\(trace.fallbackTaken ? " · GUARD FALLBACK (\(trace.driftDecision))" : "")
                ref:     \(trace.reference.prefix(100))
                raw:     \(trace.rawText.prefix(100)) (WER \(Runners.percent(trace.rawWER)))
                rules:   \(trace.rules.text.prefix(100))\(trace.rules.rejection.map { " (rejected: \($0))" } ?? "")
                \(trace.main.backend): \(trace.main.text.prefix(100))\(trace.main.usedModel ? " [model]" : " [rules fallback]")\(trace.main.rejection.map { " (rejected: \($0))" } ?? "")
            """
        }
        Runners.emit(summary, details: ["Per-clip traces:"] + details)
    }

    private static func writeReport(
        traces: [Trace], model: String, path: String, args: Arguments,
        cleanupOptions: CleanupOptions? = nil, strategy: SmartCleaner.Strategy? = nil
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = ReportPayload(
            schemaVersion: 1, kind: "voice-trace", model: model,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            arguments: Array(CommandLine.arguments.dropFirst()),
            cleanupSettings: cleanupOptions.map(CleanupSettings.init),
            cleanupStrategy: strategy?.rawValue, traces: traces)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(payload).write(to: url, options: .atomic)
    }

    private struct CleanupSettings: Codable {
        let level: String
        let grammarContract: String
        let isCodeContext: Bool
        let isCasualContext: Bool
        let detectedLanguage: String?

        init(_ options: CleanupOptions) {
            level = options.level.rawValue
            grammarContract = options.grammarContract.rawValue
            isCodeContext = options.isCodeContext
            isCasualContext = options.isCasualContext
            detectedLanguage = options.detectedLanguage
        }
    }

    private struct ReportPayload: Codable {
        let schemaVersion: Int
        let kind: String
        let model: String
        let timestamp: String
        let arguments: [String]
        /// Unknown for founder-run score-lines; never inferred from harness flags.
        let cleanupSettings: CleanupSettings?
        let cleanupStrategy: String?
        let traces: [Trace]
    }
}
