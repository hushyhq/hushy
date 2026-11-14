import Foundation
import HushyModelsApple
import HushyModelsMLX
import MurmurCore

/// Runs the shipped cleanup pipeline with an intent model on a local MLX folder. Output text lives only
/// in the requested JSONL file; stdout has aggregate counts and times.
enum IntentAppRunner {
    static func run(_ args: Arguments) async throws {
        guard let input = args.string("cases"), let output = args.string("out"),
              let folder = args.string("mlx-model") else {
            throw EvalError.missing("intent-app needs --cases <jsonl|golden.json> --mlx-model <dir> --out <jsonl>")
        }
        let entry = try args.localModelEntry()
        // `--speculate ab --out-b <jsonl>`: every case runs twice on one loaded model, without speculation (rows in
        // `--out`) and with it (rows in `--out-b`), alternating which goes first, so both arms see the same load.
        // `--ab argmax` pairs the same way: arm A without the change (`--out`), arm B with it (`--out-b`).
        let abKnob = args.string("ab")
        if let abKnob, abKnob != "argmax" { throw EvalError.missing("--ab must be argmax") }
        let speculationPaired = args.string("speculate") == "ab"
        let paired = speculationPaired || abKnob != nil
        let outputB = args.string("out-b")
        if paired, outputB == nil { throw EvalError.missing("a paired run (--speculate ab, --ab) needs --out-b <jsonl>") }
        let personArm = args.string("person-arm")
        if let personArm, !["A", "B", "C", "D", "E", "N"].contains(personArm) {
            throw EvalError.missing("--person-arm must be A, B, C, D, E, or N")
        }
        // `--block-in-options` hands the block to the cleaner as the app does (`CleanupOptions.personBlock`), so the
        // output guard sees its words too; without it the block is only prefixed to the user turn, as before.
        let blockInOptions = args.flag("block-in-options")
        guard entry.promptProfile == .intent || (personArm != nil && entry.id == ModelRegistry.hushyCleanup2B) else {
            throw EvalError.missing("intent-app requires an intent registry entry (or v5.4 with --person-arm)")
        }
        let cases = try rows(input)
        guard !cases.isEmpty else { throw EvalError.missing("no cases with id and spoken") }
        let traceSteps = args.flag("trace-steps")
        let chain = LocalCleanupBackend.chain(
            entry: entry, directory: URL(fileURLWithPath: folder, isDirectory: true),
            fallback: AppleFoundationModel(), idleSeconds: nil, callLog: ModelCallLog(),
            speculation: speculationPaired ? true : try args.speculationOverride(), tuning: args.speculationTuning())
        // `--repairs-spans` puts a refused span back as the app does (the gate runs without it, as it always has).
        let repairsSpans = args.flag("repairs-spans")
        // Eval only: HUSHY_EVAL_REGISTER_LINES swaps a register line (RegisterLineOverride.swift).
        let lineOverride = try RegisterLineOverride.fromEnvironment(mlx: chain.mlx)
        if let lineOverride {
            print("intent-app register-line override: \(lineOverride.lines.keys.map(\.rawValue).sorted().joined(separator: ","))")
        }
        let answers = AnswerTape(chain.model, override: lineOverride)
        let cleaner = SmartCleaner(model: answers,
                                   // Rejected answers are kept so the output rows can show what a guard refused.
                                   retainsRejectedCandidates: true,
                                   repairsSpans: repairsSpans,
                                   wholeTranscript: { entry.promptProfile == .intent },
                                   registerLines: { entry.understandsRegisterLines },
                                   secondOpinion: AppleFoundationModel(),
                                   // `--no-paragraph-layout`: the cleanup as it was before `ParagraphLayout`, for a before/after on one build.
                                   laysOutParagraphs: !args.flag("no-paragraph-layout"))
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        let options = try args.cleanupOptions(level: args.cleanupLevel)
        // `--cold-registers`: warm as the app did before 2026-10-28, without the register prefixes, so the first
        // dictation of each register builds its prefix on the clock (measurement only).
        let coldRegisters = args.flag("cold-registers")
        if coldRegisters {
            SmartCleaner(model: answers).prewarm(prefixesFor: options.level)
        } else {
            cleaner.prewarm(prefixesFor: options.level)
        }
        if args.flag("warm") {
            // The app builds its prefixes at launch, long before the first dictation: wait for them here too, so the
            // first cases are not timed behind them.
            await answers.prefixCache(instructions: SmartCleaner.cleanupInstructions(confidenceGuided: false))
            if cleaner.sendsRegisterLines, !coldRegisters {
                for register in IntentRegister.allCases {
                    await answers.prefixCache(instructions: SmartCleaner.registerInstructions(register))
                }
            }
            try await Task.sleep(for: .seconds(2))
        }
        // `--bundle <id>` runs the cases as that app's dictation would (its category, code handling and tone plan),
        // at the level given by `--level`. Without it the cases run with no app context, as before.
        var settings = PipelineSettings(cleanupOptions: options)
        if let bundle = args.string("bundle") {
            settings = LiveShapeRunner.settings(tone: .refined, bundleID: bundle,
                                                surface: args.string("surface").flatMap(EditorChatSurface.Surface.init(rawValue:))).0
            settings.cleanupOptions.level = options.level
            settings.cleanupOptions.detectedLanguage = options.detectedLanguage
            settings.cleanupOptions.grammarContract = options.grammarContract
        }
        var outputRows = [[String: Any]]()
        var outputRowsB = [[String: Any]]()
        var used = 0
        let useScreenTerms = args.flag("use-screen-terms")
        func runCase(_ item: Row) async -> [String: Any] {
            let block = personArm.flatMap { item.personBlock(arm: $0) }
            // Arm N (measurement only): `history.block` is the block's text exactly as written, prefixed to the user
            // turn; the guard is not told its words.
            let rawBlock = personArm == "N" ? item.history["block"] as? String : nil
            answers.setBlock(rawBlock ?? (blockInOptions ? nil : block?.render()))
            var caseSettings = settings
            if let bundle = item.bundle {
                // An optional per-case `tone` ("casual", "professional") runs the case as if that tone were the default one.
                // An optional per-case `surface` ("chat", "code", "unknown") says what the editor's focused field is.
                let shaped = LiveShapeRunner.settings(tone: item.tone.flatMap(DictationTone.init(rawValue:)) ?? .refined, bundleID: bundle,
                                                      surface: item.surface.flatMap(EditorChatSurface.Surface.init(rawValue:)),
                                                      appWriting: item.appTone)
                caseSettings = shaped.0
                caseSettings.cleanupOptions.level = options.level
                caseSettings.cleanupOptions.detectedLanguage = options.detectedLanguage
                caseSettings.cleanupOptions.grammarContract = options.grammarContract
            }
            if useScreenTerms, !item.screenTerms.isEmpty {
                caseSettings.contextTerms = item.screenTerms
            }
            if let personArm, personArm != "A" {
                caseSettings.contextTerms = item.terms
                caseSettings.cleanupOptions.protectedTerms += item.terms
            }
            if blockInOptions { caseSettings.cleanupOptions.personBlock = block }
            let started = ContinuousClock.now
            let before = chain.mlx.stats.successes
            answers.reset()
            let result = await pipeline.clean(item.spoken, settings: caseSettings, strategy: args.strategy)
            let total = Int((ContinuousClock.now - started).components.seconds * 1_000)
                + Int((ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000)
            let timing = chain.mlx.lastCallTimings
            let localAnswered = chain.mlx.stats.successes > before
            let first = localAnswered ? timing?.timeToFirstTokenMilliseconds : nil
            let modelMs = result.groups.compactMap(\.modelMs).reduce(0, +)
            if result.usedModel { used += 1 }
            var row: [String: Any] = [
                "id": item.id, "text": result.text, "usedModel": result.usedModel,
                "register": caseSettings.cleanupOptions.register?.rawValue as Any? ?? NSNull(),
                "overriddenAsks": answers.overriddenAsks(),
                "rejection": result.rejection as Any? ?? NSNull(),
                "firstTokenMs": first as Any? ?? NSNull(), "totalMs": total, "modelMs": modelMs,
                "promptTokens": timing?.promptTokens as Any? ?? NSNull(),
                "prefixUse": localAnswered ? timing?.prefixUse as Any? ?? NSNull() : NSNull(),
                // The last model call of the case (speed only): sampled tokens, forward passes and draft acceptance.
                "genTokens": localAnswered ? timing?.generatedTokens as Any? ?? NSNull() : NSNull(),
                "lastCallMs": localAnswered ? timing.map { Int($0.totalMilliseconds) } as Any? ?? NSNull() : NSNull(),
                "passes": localAnswered ? timing?.speculation?.forwardPasses as Any? ?? NSNull() : NSNull(),
                "accepted": localAnswered ? timing?.speculation.map { [$0.draftedTokens, $0.acceptedDraftTokens] } as Any? ?? NSNull() : NSNull(),
                "groups": result.groups.count,
                // Eval output only: every raw answer the model gave for this case, before any guard or repair.
                "modelAnswers": answers.taken(),
                // Stage trace (eval output only): what changed the model's answer after the call.
                "stages": result.groups.map { group -> [String: Any] in
                    ["secondPass": String(describing: group.secondPass), "repairedSpans": group.repairedSpans,
                     "askedAgain": String(describing: group.askedAgain), "edited": group.edited,
                     "registerDropped": group.registerDropped, "plainRetryMs": group.plainRetryMs as Any? ?? NSNull(),
                     "registerRefusal": group.measured.registerRefusal ?? NSNull(),
                     "firstAskMs": group.firstAskMs as Any? ?? NSNull(),
                     "outcome": group.outcome.rawValue, "guard": group.guardCode.map { String(describing: $0) } ?? NSNull(),
                     "firstPass": group.measured.firstPassText ?? NSNull(),
                     "secondAnswer": group.measured.secondPassAnswer ?? NSNull(),
                     "rejectedAnswer": group.rejectedCandidate ?? NSNull()]
                },
            ]
            if traceSteps {
                let fixers = pipeline.earlyTranscript(item.spoken, settings: caseSettings)
                let assembled = PipelineStepCapture.assemble(
                    recognizer: item.spoken, boosted: item.spoken, fixers: fixers, result: result)
                row["steps"] = Dictionary(uniqueKeysWithValues: assembled.map { ($0.rawValue, $1) })
            }
            return row
        }
        for (index, item) in cases.enumerated() {
            guard paired else { outputRows.append(await runCase(item)); continue }
            for armB in index % 2 == 0 ? [false, true] : [true, false] {
                if abKnob == "argmax" { await chain.mlx.setMeasurementMasksFirst(!armB) } else { chain.mlx.setMeasurementSpeculation(armB) }
                let row = await runCase(item)
                if armB { outputRowsB.append(row) } else { outputRows.append(row) }
            }
        }
        func write(_ rows: [[String: Any]], to path: String) throws {
            let lines = try rows.map {
                String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        try write(outputRows, to: output)
        if let outputB, paired { try write(outputRowsB, to: outputB) }
        print("intent-app cases=\(cases.count) usedModel=\(used) output=\(output)")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let mlxMemory = MLXLanguageModel.allocatorMemoryBytes
        print("intent-app memory mlxPeakMB=\(mlxMemory.peak / 1_048_576) mlxActiveMB=\(mlxMemory.active / 1_048_576) maxRSSMB=\(Int(usage.ru_maxrss) / 1_048_576)")
    }

    struct Row {
        let id: String
        let spoken: String
        let history: [String: Any]
        let bundle: String?
        let screenTerms: [String]
        var tone: String? = nil
        var surface: String? = nil
        /// An optional per-case `app_tone`: the choice stored for the case's app ("professional", "casual", "prompt").
        var appTone: String? = nil
        var terms: [String] { history["terms"] as? [String] ?? [] }
        func personBlock(arm: String) -> PersonBlock? {
            guard ["C", "D", "E"].contains(arm) else { return nil }
            let edits = (history["edits"] as? [[String: String]] ?? []).compactMap { pair -> (before: String, after: String)? in
                guard let before = pair["before"], let after = pair["after"] else { return nil }
                return (before, after)
            }
            return PersonBlock(style: history["style"] as? String, terms: terms,
                earlier: arm == "C" ? [] : history["earlier"] as? [String] ?? [],
                edits: arm == "E" ? edits : [], screen: arm == "C" ? nil : history["screen"] as? String)
        }
    }

    private static func rows(_ path: String) throws -> [Row] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let objects: [[String: Any]]
        if path.hasSuffix(".json") {
            objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        } else {
            objects = try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        return objects.compactMap { row in
            guard let id = row["id"] as? String, let spoken = row["spoken"] as? String else { return nil }
            let bundle = row["bundle"] as? String
            let screen = row["screen_terms"] as? [String] ?? []
            return Row(id: id, spoken: spoken, history: row["history"] as? [String: Any] ?? [:],
                         bundle: bundle, screenTerms: screen, tone: row["tone"] as? String, surface: row["surface"] as? String,
                         appTone: row["app_tone"] as? String)
        }
    }
}

/// Passes every call through and keeps the model's raw answers for the current case, so a row can show what a
/// guard refused. Eval output only; the answer text never leaves the requested JSONL.
private final class AnswerTape: LanguageModel, @unchecked Sendable {
    private let inner: any LanguageModel
    private let lock = NSLock()
    private var answers = [String]()
    private var block: String?
    private let override: RegisterLineOverride?
    private var overridden = 0

    init(_ inner: any LanguageModel, override: RegisterLineOverride? = nil) { self.inner = inner; self.override = override }

    private func append(_ answer: String) { lock.lock(); answers.append(answer); lock.unlock() }
    func reset() { lock.lock(); answers = []; overridden = 0; lock.unlock() }
    /// How many asks of the current case went out with a replaced register line.
    func overriddenAsks() -> Int { lock.withLock { overridden } }
    func setBlock(_ value: String?) { lock.lock(); block = value; lock.unlock() }
    func taken() -> [String] { lock.lock(); defer { lock.unlock() }; return answers }

    var identifier: String { inner.identifier }
    var availability: LanguageModelAvailability { inner.availability }
    var contextTokens: Int { inner.contextTokens }
    func supportsLanguage(_ languageCode: String) -> Bool { inner.supportsLanguage(languageCode) }
    func prewarm(instructions: String) { inner.prewarm(instructions: instructions) }
    func prefixCache(instructions: String) async { await inner.prefixCache(instructions: instructions) }
    func warmForDictation(instructions: String) async { await inner.warmForDictation(instructions: instructions) }
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        let currentBlock = lock.withLock { block }
        let input = currentBlock.map { $0 + "\n" + prompt } ?? prompt
        if let override, let system = override.system(instructions: instructions, schema: schema) {
            let answer = try await override.mlx.respondVerbatim(system: system, prompt: input, schema: schema, maxTokens: 1_024).text
            lock.withLock { overridden += 1 }
            append(answer)
            return answer
        }
        let answer = try await inner.respond(instructions: instructions, prompt: input, schema: schema, options: options)
        append(answer)
        return answer
    }
}
