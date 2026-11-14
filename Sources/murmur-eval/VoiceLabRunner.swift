@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// Scores the Voice Lab: a held-out set of the user's real dictation, captured through the
/// exact production microphone path (see `Sources/Murmur/VoiceLab`). Unlike `e2e` (synthesized
/// TTS through `say`) and `cleanup` (text only, no ASR), this is real audio from a real mic —
/// the closest thing this repo has to a ground-truth eval, and it is intentionally never tuned
/// against: see Evals/README.md.
///
///   murmur-eval voicelab [--dir path] [--model v2|ultra] [--strategy rules|hybrid]
///       [--dictionary terms.json] [--gate3] [--report path] [--min-pass 0.NN]
///
/// `--dictionary` + the Gate 3 block (raw WER / after-dictionary WER / whispered WER against the
/// gate 3 limits) are described in `VoiceLabGate`; `--gate3` exits non-zero when a limit is
/// missed, otherwise the block is report-only.
extension Runners {
    struct VoiceLabCase {
        let prompt: VoiceLabPrompt
        let take: VoiceLabTake
        let result: PipelineResult
        let latencyMs: Double

        var passed: Bool {
            result.pressEnter == (prompt.expectedPressEnter ?? false) && prompt.accepted.contains {
                (prompt.exactText == true ? $0 == result.text : EvalMetrics.layoutMatches($0, result.text))
            }
        }

        /// True when the transcript came back empty even though the take had audio — i.e. the
        /// mic captured a real take but nothing made it through ASR/cleanup (a "gate" reject).
        var wasRejected: Bool { result.text.isEmpty && !prompt.expected.isEmpty }
    }

    static func voicelab(_ args: Arguments) async throws {
        let directory = args.string("dir").map { URL(fileURLWithPath: $0) } ?? VoiceLabStorage.root
        let recordings = (try? VoiceLabStorage.discoverRecordings(in: directory)) ?? []
        guard !recordings.isEmpty else {
            print("### Voice Lab · no recordings found under \(directory.path)")
            print("Skipped: record a session in the app (Settings → Developer → Voice Lab) first.")
            return
        }

        let promptsURL = args.string("prompts").map { URL(fileURLWithPath: $0) } ?? Paths.root.appendingPathComponent("voicelab-prompts.json")
        let prompts = try VoiceLabPrompts.load(from: promptsURL)
        let promptsByID = Dictionary(uniqueKeysWithValues: prompts.map { ($0.id, $0) })

        // Gate 3's dictionary is only ever a file passed explicitly (see VoiceLabGate) — this
        // command never reads the app's database, so the founder's real Dictionary is typed
        // into a small JSON file instead.
        let dictionary = try args.string("dictionary").map { try VoiceLabDictionaryFile.load(from: URL(fileURLWithPath: $0)) } ?? []
        let personalizer = Personalizer(dictionary: dictionary)
        let vocabulary = VocabularyContext.from(dictionary: dictionary)

        let engine = try await Engine.load(args.model)
        let cleaner = SmartCleaner()
        cleaner.prewarm()
        let pipeline = DictationPipeline(transcriber: engine, cleaner: cleaner)

        var cases: [VoiceLabCase] = []
        var gateTakes: [VoiceLabGate.Take] = []
        var skippedMissingPrompt: [String] = []
        for recording in recordings {
            guard let prompt = promptsByID[recording.take.promptID] else {
                skippedMissingPrompt.append(recording.take.promptID)
                continue
            }
            let samples = try AudioConverter().resampleAudioFile(recording.audioURL)
            let start = Date()
            let result = try await pipeline.run(
                samples: samples, settings: PipelineSettings(personalizer: personalizer), strategy: args.strategy)
            let latency = Date().timeIntervalSince(start) * 1000
            cases.append(VoiceLabCase(prompt: prompt, take: recording.take, result: result, latencyMs: latency))
            // Gate 3 passes: ASR alone, then ASR biased by the dictionary + its spelling fixes.
            let raw = try await pipeline.transcribeRaw(samples)
            let boosted = dictionary.isEmpty ? raw : try await pipeline.transcribeRaw(samples, vocabulary: vocabulary)
            gateTakes.append(VoiceLabGate.Take(
                style: prompt.style, spoken: VoiceLabGate.spokenText(of: prompt),
                raw: raw, withDictionary: personalizer.apply(boosted).text))
        }

        guard !cases.isEmpty else {
            print("### Voice Lab · \(recordings.count) recording(s) found, but none matched a known prompt id")
            return
        }

        let gate = VoiceLabGate.measure(gateTakes, dictionaryTerms: dictionary.count)
        try report(cases: cases, gate: gate, args: args, promptCount: prompts.count, skippedMissingPrompt: skippedMissingPrompt)
        if args.flag("gate3"), !gate.passes {
            throw EvalError.missing("Gate 3 thresholds not met (see the Gate 3 block above)")
        }
    }

    private static func report(
        cases: [VoiceLabCase], gate: VoiceLabGate.Measurement, args: Arguments, promptCount: Int, skippedMissingPrompt: [String]
    ) throws {
        let passed = cases.filter(\.passed).count
        let rejected = cases.filter(\.wasRejected).count
        let latencies = cases.map(\.latencyMs)
        let byStyle = Dictionary(grouping: cases, by: { $0.prompt.style }).sorted { $0.key.rawValue < $1.key.rawValue }
        let styleLines = byStyle.map { style, items -> String in
            let stylePassed = items.filter(\.passed).count
            let wer = EvalMetrics.corpusWER(items.map { ($0.prompt.expected, $0.result.text) })
            return "  - \(style.rawValue): \(stylePassed)/\(items.count) pass (\(percent(Double(stylePassed) / Double(items.count)))) · WER \(percent(wer))"
        }
        let overallWER = EvalMetrics.corpusWER(cases.map { ($0.prompt.expected, $0.result.text) })

        let summary = """
            ### Voice Lab · \(args.modelName) · \(args.strategy.rawValue) · \(cases.count)/\(promptCount) prompts recorded
            - Pass: **\(passed)/\(cases.count) (\(percent(Double(passed) / Double(cases.count))))**
            - Word distance to expected: \(percent(overallWER))
            - Gate-rejected (empty output on non-empty expected): \(rejected)/\(cases.count)
            - Latency: p50 \(ms(EvalMetrics.percentile(latencies, 0.5))), p95 \(ms(EvalMetrics.percentile(latencies, 0.95)))
            - By style:
            \(styleLines.joined(separator: "\n"))
            \(VoiceLabGate.markdown(gate))
            """ + (skippedMissingPrompt.isEmpty ? "" : "\n- Skipped \(skippedMissingPrompt.count) recording(s) with no matching prompt id: \(skippedMissingPrompt.prefix(5).joined(separator: ", "))")

        let failures = cases.filter { !$0.passed }.map { c in
            """
              ✘ \(c.prompt.id) [\(c.prompt.style.rawValue)/\(c.prompt.category)]
                got:      \(c.result.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                expected: \(c.prompt.expected.replacingOccurrences(of: "\n", with: " ⏎ "))
            """
        }
        emit(summary, details: failures.isEmpty ? [] : ["Failures:"] + failures)

        if let path = args.string("report") {
            try writeVoiceLabReport(cases: cases, gate: gate, path: path, args: args)
        }
        if let minimum = args.string("min-pass") {
            guard let value = Double(minimum), (0...1).contains(value) else {
                throw EvalError.missing("--min-pass must be a fraction in 0...1")
            }
            guard Double(passed) / Double(cases.count) >= value else {
                throw EvalError.missing("Voice Lab pass rate below required \(value)")
            }
        }
    }

    private static func writeVoiceLabReport(cases: [VoiceLabCase], gate: VoiceLabGate.Measurement, path: String, args: Arguments) throws {
        let entries: [[String: Any]] = cases.map { c in
            [
                "id": c.prompt.id, "category": c.prompt.category, "style": c.prompt.style.rawValue,
                "expected": c.prompt.expected, "accepted": c.prompt.accepted, "actual": c.result.text,
                "passed": c.passed, "pressEnter": c.result.pressEnter,
                "expectedPressEnter": c.prompt.expectedPressEnter ?? false,
                "latencyMs": c.latencyMs, "usedModel": c.result.usedModel,
                "rejection": c.result.rejection as Any? ?? NSNull(),
                "deviceName": c.take.deviceName, "voiceProcessingEnabled": c.take.voiceProcessingEnabled,
                "osVersion": c.take.osVersion, "capturePeak": c.take.capturePeak, "captureRMS": c.take.captureRMS,
                "durationSeconds": c.take.durationSeconds,
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1, "kind": "voicelab", "title": "Voice Lab",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "arguments": Array(CommandLine.arguments.dropFirst()),
            "passed": cases.filter(\.passed).count, "total": cases.count, "cases": entries,
            "gate3": [
                "passes": gate.passes, "rawWER": gate.rawWER, "dictionaryWER": gate.dictionaryWER,
                "whisperWER": gate.whisperWER, "normalNoisyTakes": gate.normalNoisyCount,
                "whisperTakes": gate.whisperCount, "dictionaryTerms": gate.dictionaryTerms,
                "limits": ["raw": VoiceLabGate.rawWERLimit, "dictionary": VoiceLabGate.dictionaryWERLimit, "whisper": VoiceLabGate.whisperWERLimit],
            ],
        ]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
