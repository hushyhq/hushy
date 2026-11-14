import CryptoKit
import Foundation
import HushyModelsApple
import HushyModelsMLX
import MurmurCore

/// `murmur-eval grammar [--golden Evals/grammar-golden.json] [--strategy hybrid] [--split tune|holdout|all]
///   [--min-pass 0.NN] [--report path.json]`
///
/// Scores the grammar-repair capability added to `SmartCleaner`'s hybrid path (task: "grammar
/// polish" — the product owner's dictated example, "Voice signatures also I think should be in
/// free because if we are stating labelling as free shouldn't, voice signature should
/// automatically be free", pasted essentially unchanged because nothing triggered the model).
/// Runs through `DictationPipeline.clean` — the exact production path — like `cleanup`/`style`,
/// not `SmartCleaner` directly, so this can't silently drift from what the app does.
///
/// Two things are scored, both deterministically (no LLM judge):
///
///  1. **Repair rate**: for a "repair"/"mixed" case, the output must contain every string in
///     `mustContain` and none of `mustNotContain` — a required/forbidden substring check per
///     case, written by hand for each case rather than an exact-match string (grammar repair has
///     many acceptable phrasings; substring checks capture "was the problem actually fixed"
///     without over-constraining wording).
///  2. **Faithfulness on negatives**: for a "negative" case, the case is scored the same way
///     (`mustContain`/`mustNotContain` normally just asserts the whole input survived unchanged),
///     plus a separate, stricter content-word check: every content word (a word not in
///     `OutputGuard.freeFunctionWords`, i.e. carrying real meaning) in the input must still be
///     present in the output, and no new content word may appear — this is the "no content words
///     added or dropped" faithfulness bar from the task, checked independently of the
///     per-case substrings so a negative can't accidentally pass by coincidence.
///
/// The golden set is split in half via each case's `"split": "tune"|"holdout"` field: only
/// "tune" cases were used while writing the detector/prompt/guard changes in this task; "holdout"
/// is reported for the first time here, alongside "tune", so both numbers are honest — see
/// `.claude/DECISIONS.md` for the before/after comparison this produced.
enum GrammarRunner {
    struct GrammarCase: Decodable {
        let id: String
        let tag: String
        let split: String
        /// The cleanup level this case is scored under: "clean" for pure disfluency repair (the
        /// hybrid path's stricter, grammar-untouched instructions) or "polished" for full
        /// grammar-and-flow repair. Each case is run through exactly the level it targets, since
        /// `.clean` and `.polished` now have deliberately different contracts (task: "each
        /// cleanup level must do what the UI promises") — running a `.polished`-only repair case
        /// through `.clean` would always fail, not because the feature regressed but because that
        /// level was never supposed to fix it.
        let level: String
        /// "core" (default) is the original hand-written set; "real-user" is the coordinator's
        /// verbatim reported failures (reported separately, never tuned on); "legit-repeat" is
        /// the ambiguous doubled-word negatives ("very very", "that that", "had had", "bye bye")
        /// that must survive both levels unchanged.
        let group: String
        let spoken: String
        let mustContain: [String]
        let mustNotContain: [String]
        let note: String?

        var isNegative: Bool { tag == "negative" }
        var cleanupLevel: CleanupLevel { CleanupLevel(rawValue: level) ?? .clean }
    }

    struct GrammarResult {
        let item: GrammarCase
        let output: String
        let usedModel: Bool
        let rejection: String?
        let latencyMs: Double
        let modelCalls: [CleanupTraceCall]
        var groups: [GroupTrace] = []
        /// The text the model's rejected answer would have pasted (single-group runs).
        var rejectedAnswer: String?

        var substringsPass: Bool { substringsPass(for: output) }

        func substringsPass(for text: String) -> Bool {
            item.mustContain.allSatisfy { text.contains($0) } && item.mustNotContain.allSatisfy { !text.contains($0) }
        }

        /// Why a failing case failed, from the model's side (see `CleanupOutcomeReport.failureClass`).
        var failureClass: String {
            guard let group = groups.last else { return "no trace" }
            switch group.outcome {
            case .used: return group.edited ? "applied and wrong" : "model made no edit"
            case .rejectedByGuard:
                guard let answer = rejectedAnswer else { return "rejected, answer unavailable" }
                return substringsPass(for: answer) ? "rejected, the answer was right" : "rejected, the answer was wrong too"
            case .notAsked: return "not asked"
            default: return "no answer (\(group.outcome.rawValue))"
            }
        }

        /// Only meaningful for a negative case: every content word (a real, non-function word)
        /// spoken must survive, and no new content word may appear.
        func faithfulness() -> (droppedContent: [String], addedContent: [String]) {
            let spokenContent = contentWords(item.spoken)
            let outputContent = contentWords(output)
            let dropped = spokenContent.subtracting(outputContent)
            let added = outputContent.subtracting(spokenContent)
            return (Array(dropped).sorted(), Array(added).sorted())
        }

        var passed: Bool {
            guard substringsPass else { return false }
            guard item.isNegative else { return true }
            let (dropped, added) = faithfulness()
            return dropped.isEmpty && added.isEmpty
        }

        private func contentWords(_ text: String) -> Set<String> {
            Set(OutputGuard.words(text).filter { !OutputGuard.freeFunctionWords.contains($0) })
        }
    }

    static func run(_ args: Arguments) async throws {
        let url = args.string("golden").map { URL(fileURLWithPath: $0) }
            ?? Paths.root.appendingPathComponent("grammar-golden.json")
        let experiment = try experimentProfile(args)
        if experiment != nil {
            try SealedEvalGuard.assertTuningSafe(url, purpose: "grammar experiment input")
        }
        let caseData = try Data(contentsOf: url)
        let allCases = try JSONDecoder().decode([GrammarCase].self, from: caseData)
        guard !allCases.isEmpty, Set(allCases.map(\.id)).count == allCases.count else {
            throw EvalError.missing("Grammar golden set must be nonempty with unique IDs")
        }
        let splitFilter = args.string("split") ?? "all"
        let cases = splitFilter == "all" ? allCases : allCases.filter { $0.split == splitFilter }
        guard !cases.isEmpty else { throw EvalError.missing("No cases for --split \(splitFilter)") }
        if experiment != nil, !cases.contains(where: { $0.cleanupLevel == .polished }) {
            throw EvalError.missing("--polished-experiment requires at least one polished case in the selected split")
        }

        let selected = LanguageModels.current
        let mlx = try validateSelectedModel(args, experiment: experiment, selected: selected)

        let recorder = CleanupTraceRecorder()
        let recordingModel = RecordingLanguageModel(base: selected, recorder: recorder,
            compactPrompt: mlx?.configuration.promptProfile == .compact,
            mlxPromptProfile: mlx?.configuration.promptProfile,
            polishedExperiment: experiment)
        let cleaner = makeCleaner(args, model: recordingModel, retainsRejectedCandidates: true)
        let grammarContract = try args.cleanGrammarContract()
        if cases.contains(where: { $0.cleanupLevel == .clean }) {
            cleaner.prewarm(prefixesFor: .clean, grammarContract: grammarContract)
        }
        if cases.contains(where: { $0.cleanupLevel == .polished }) {
            cleaner.prewarm(prefixesFor: .polished, grammarContract: grammarContract)
        }
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        // `.clean` runs as hybrid (asks the model only when triggered); `.polished` always asks —
        // matching `SmartCleaner.strategy(for:)`'s own production mapping, so each case is scored
        // exactly the way the real level behaves, not overridden by a single `--strategy` flag.
        let strategyOverride = args.string("strategy").flatMap(SmartCleaner.Strategy.init(rawValue:))

        var results: [GrammarResult] = []
        for item in cases {
            let strategy = strategyOverride ?? SmartCleaner.strategy(for: item.cleanupLevel)
            let settings = PipelineSettings(cleanupOptions: try args.cleanupOptions(level: item.cleanupLevel))
            let start = Date()
            let callsBefore = Set(recorder.snapshot.map(\.callID))
            let result = await pipeline.clean(item.spoken, settings: settings, strategy: strategy)
            let calls = recorder.snapshot.filter { !callsBefore.contains($0.callID) }
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            var row = GrammarResult(
                item: item, output: result.text, usedModel: result.usedModel, rejection: result.rejection,
                latencyMs: elapsedMs, modelCalls: calls, groups: result.groups)
            if result.groups.count == 1, let rejected = result.groups[0].rejectedCandidate {
                row.rejectedAnswer = SmartCleaner.presentable(
                    rejected, raw: item.spoken, options: settings.cleanupOptions)
            }
            results.append(row)
        }

        report(results, args: args, caseSetSHA256: hash(caseData), selected: selected,
            experiment: experiment, backend: args.string("backend") ?? "apple",
            mlxPrompt: mlx?.configuration.promptProfile.rawValue ?? "not-applicable")
    }

    static func experimentProfile(_ args: Arguments) throws -> String? {
        if args.flag("polished-experiment") {
            throw EvalError.missing("--polished-experiment requires a value (agreement-v1)")
        }
        return try CleanupTracePromptExperiment.profile(args.string("polished-experiment"),
            backend: args.string("backend") ?? "apple")
    }

    private static func validateSelectedModel(_ args: Arguments, experiment: String?,
                                               selected: any LanguageModel) throws -> MLXLanguageModel? {
        guard experiment != nil else { return selected as? MLXLanguageModel }
        guard args.string("backend") == "mlx" else {
            throw EvalError.missing("--polished-experiment agreement-v1 requires --backend mlx")
        }
        guard let modelPath = args.string("mlx-model") else {
            throw EvalError.missing("--polished-experiment requires --mlx-model <local-directory>")
        }
        guard let mlx = selected as? MLXLanguageModel, selected.identifier.hasPrefix("mlx:") else {
            throw EvalError.missing("selected language model does not match --backend mlx (fallbacks are forbidden)")
        }
        let requestedDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard requestedDirectory == mlx.configuration.directory.resolvingSymlinksInPath().standardizedFileURL else {
            throw EvalError.missing("selected MLX model directory does not match --mlx-model")
        }
        guard mlx.configuration.adapterDirectory == nil, args.string("mlx-adapter") == nil else {
            throw EvalError.missing("grammar experiment compares direct model weights; LoRA adapters are not accepted")
        }
        return mlx
    }

    private static func makeCleaner(
        _ args: Arguments, model: any LanguageModel, retainsRejectedCandidates: Bool = false
    ) -> SmartCleaner {
        guard let ms = args.int("budget-ms"), ms > 0 else {
            return SmartCleaner(cleanGate: args.cleanGate, model: model, retainsRejectedCandidates: retainsRejectedCandidates)
        }
        let budget = Duration.milliseconds(ms)
        return SmartCleaner(budget: budget, correctionBudget: budget, polishedBudget: budget,
            segmentBudget: budget, cleanGate: args.cleanGate, model: model,
            retainsRejectedCandidates: retainsRejectedCandidates)
    }

    private static func report(_ results: [GrammarResult], args: Arguments, caseSetSHA256: String,
                               selected: any LanguageModel, experiment: String?, backend: String, mlxPrompt: String) {
        func summarize(_ subset: [GrammarResult], label: String) -> [String] {
            guard !subset.isEmpty else { return ["- \(label): no cases"] }
            let repairCases = subset.filter { !$0.item.isNegative }
            let negativeCases = subset.filter(\.item.isNegative)
            let repairPassed = repairCases.filter(\.passed).count
            let negativePassed = negativeCases.filter(\.passed).count
            let latencies = subset.map(\.latencyMs)
            var lines = ["- \(label): \(subset.count) cases"]
            if !repairCases.isEmpty {
                lines.append("  - Repair rate: **\(repairPassed)/\(repairCases.count) (\(pct(safeDiv(repairPassed, repairCases.count))))**")
            }
            if !negativeCases.isEmpty {
                lines.append("  - Faithfulness on negatives: **\(negativePassed)/\(negativeCases.count) (\(pct(safeDiv(negativePassed, negativeCases.count))))**")
            }
            lines.append("  - Latency: p50 \(ms(EvalMetrics.percentile(latencies, 0.5))), p95 \(ms(EvalMetrics.percentile(latencies, 0.95)))")
            let modelUses = subset.filter(\.usedModel).count
            lines.append("  - Model pass used on \(modelUses)/\(subset.count)")
            return lines
        }

        let tune = results.filter { $0.item.split == "tune" && $0.item.group == "core" }
        let holdout = results.filter { $0.item.split == "holdout" && $0.item.group == "core" }
        let realUser = results.filter { $0.item.group == "real-user" }
        let legitRepeat = results.filter { $0.item.group == "legit-repeat" }
        let cleanLevel = results.filter { $0.item.cleanupLevel == .clean }
        let polishedLevel = results.filter { $0.item.cleanupLevel == .polished }
        let shortInputs = results.filter { TextStats.wordCount($0.item.spoken) < 10 }

        var summaryLines = ["### Grammar repair · \(results.count) cases"]
        summaryLines += summarize(tune, label: "Tune split (core, tuned on)")
        summaryLines += summarize(holdout, label: "Holdout split (core, never tuned on)")
        summaryLines += summarize(realUser, label: "Real-user group (coordinator's exact reports, never tuned on)")
        summaryLines += summarize(legitRepeat, label: "Legit-repeat negatives (ambiguous doubled words)")
        summaryLines += ["- By level:"]
        summaryLines += summarize(cleanLevel, label: "  .clean (disfluency only)")
        summaryLines += summarize(polishedLevel, label: "  .polished (grammar repair)")
        if !shortInputs.isEmpty {
            let shortLatencies = shortInputs.map(\.latencyMs)
            summaryLines.append("- Short inputs (<10 words), \(shortInputs.count) cases: latency p50 " +
                "\(ms(EvalMetrics.percentile(shortLatencies, 0.5))), p95 \(ms(EvalMetrics.percentile(shortLatencies, 0.95)))")
        }
        summaryLines += summarize(results, label: "Combined (all groups)")
        summaryLines += outcomeLines(results)
        let summary = summaryLines.joined(separator: "\n")
        Runners.emit(summary)

        let failures = results.filter { !$0.passed }
        if !failures.isEmpty {
            print("\nFailures:")
            for failure in failures {
                let (dropped, added) = failure.faithfulness()
                print("  ✘ \(failure.item.id) [\(failure.item.split)/\(failure.item.tag)/\(failure.item.level)/\(failure.item.group)]\(failure.rejection.map { " (model rejected: \($0))" } ?? "")")
                print("      spoken:   \(failure.item.spoken)")
                print("      got:      \(failure.output)")
                if !failure.item.mustContain.isEmpty {
                    let missing = failure.item.mustContain.filter { !failure.output.contains($0) }
                    if !missing.isEmpty { print("      missing:  \(missing)") }
                }
                let present = failure.item.mustNotContain.filter { failure.output.contains($0) }
                if !present.isEmpty { print("      present (should be absent): \(present)") }
                if failure.item.isNegative, !dropped.isEmpty || !added.isEmpty {
                    print("      dropped content words: \(dropped)")
                    print("      added content words:   \(added)")
                }
            }
        }

        if let path = args.string("report") {
            writeReport(results, to: path, caseSetSHA256: caseSetSHA256, selected: selected,
                experiment: experiment, backend: backend, mlxPrompt: mlxPrompt)
        }

        if let minimum = args.string("min-pass") {
            guard let value = Double(minimum), (0...1).contains(value) else {
                fatalError("--min-pass must be a fraction in 0...1")
            }
            let passed = results.filter(\.passed).count
            guard safeDiv(passed, results.count) >= value else {
                FileHandle.standardError.write(Data("Grammar pass rate below required \(value)\n".utf8))
                exit(1)
            }
        }
    }

    /// What the model did per group, and why each failing case failed from the model's side.
    private static func outcomeLines(_ results: [GrammarResult]) -> [String] {
        var lines: [String] = []
        for (label, subset) in [("clean", results.filter { $0.item.cleanupLevel == .clean }),
                                ("polished", results.filter { $0.item.cleanupLevel == .polished })] where !subset.isEmpty {
            var counts: [String: Int] = [:]
            for group in subset.flatMap(\.groups) {
                let key: String = switch group.outcome {
                case .used: group.edited ? "accepted, edited the draft" : "accepted, no change to the draft"
                case .rejectedByGuard: "rejected by guard: \(CleanupOutcomeReport.guardName(group.guardCode))"
                default: group.outcome.rawValue
                }
                counts[key, default: 0] += 1
            }
            lines.append("- Model outcome per group, \(label) level (\(subset.count) cases):")
            lines += counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "    \($0.value)  \($0.key)" }
            let modelMs = subset.flatMap(\.groups).compactMap { $0.modelMs.map(Double.init) }
            if !modelMs.isEmpty {
                lines.append("    model call: p50 \(Int(EvalMetrics.percentile(modelMs, 0.5))) ms, p95 \(Int(EvalMetrics.percentile(modelMs, 0.95))) ms over \(modelMs.count) calls")
            }
            let failed = subset.filter { !$0.passed }
            if !failed.isEmpty {
                var classes: [String: Int] = [:]
                for result in failed { classes[result.failureClass, default: 0] += 1 }
                lines.append("    failing (\(failed.count)) by model-side cause:")
                lines += classes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .map { "      \($0.value)  \($0.key)" }
            }
        }
        return lines
    }

    private static func writeReport(_ results: [GrammarResult], to path: String, caseSetSHA256: String,
                                    selected: any LanguageModel, experiment: String?, backend: String, mlxPrompt: String) {
        let cases: [[String: Any]] = results.map { result in
            let (dropped, added) = result.faithfulness()
            return [
                "id": result.item.id, "tag": result.item.tag, "split": result.item.split,
                "level": result.item.level, "group": result.item.group,
                "spoken": result.item.spoken, "output": result.output, "usedModel": result.usedModel,
                "rejection": result.rejection as Any, "passed": result.passed,
                "droppedContentWords": dropped, "addedContentWords": added,
                "latencyMs": result.latencyMs,
                "groups": result.groups.map { g -> [String: Any] in
                    ["words": g.words, "outcome": g.outcome.rawValue, "guardCode": g.guardCode?.rawValue as Any? ?? NSNull(),
                     "edited": g.edited, "modelMs": g.modelMs as Any? ?? NSNull()]
                },
                "failureClass": result.passed ? NSNull() : (result.failureClass as Any),
                "polishedExperimentApplied": experiment != nil && result.item.cleanupLevel == .polished
                    && result.modelCalls.contains(where: { $0.schemaName == SmartCleaner.cleanedSchema.name }),
                "modelCalls": result.modelCalls.map(callReport),
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 2, "title": "Grammar repair", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "caseSetSHA256": caseSetSHA256, "backend": backend,
            "modelIdentity": selected.identifier, "mlxPrompt": mlxPrompt,
            "polishedExperiment": experiment ?? "none",
            "total": results.count, "cases": cases,
        ]
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private static func callReport(_ call: CleanupTraceCall) -> [String: Any] {
        [
            "callID": call.callID, "complete": call.complete, "backend": call.backend,
            "instructionsSHA256": call.instructionsSHA256,
            "effectiveSystemSHA256": call.effectiveSystemSHA256 as Any,
            "promptSHA256": call.promptSHA256, "schemaName": call.schemaName,
            "schemaSHA256": call.schemaSHA256, "options": call.options,
            "outputJSON": call.outputJSON as Any, "error": call.error as Any,
            "milliseconds": call.milliseconds as Any,
        ]
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeDiv(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
    private static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
    private static func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
}

// Temporary diagnostic entry point (task: grammar-polish, coordinator-requested check of
// SmartCleaner.isModelAvailable + raw model output). Not part of the permanent public API.
enum ModelDiagnostic {
    static func run(_ args: Arguments) async throws {
        print("SmartCleaner.isModelAvailable: \(SmartCleaner.isModelAvailable) (backend: \(LanguageModels.current.identifier))")
        if args.flag("cancel-probe") {
            let draft = String(repeating: "so the thing is we should really think about the plan and the budget and the team ", count: 3)
            for budget in [200.0, 600.0] {
                let start = Date()
                let answer = await SmartCleaner.debugAsk(draft: draft, budgetMs: budget)
                print("budget \(Int(budget)) ms -> returned after \(Int(Date().timeIntervalSince(start) * 1000)) ms (answer: \(answer == nil ? "nil" : "text"))")
            }
            return
        }
        if args.flag("mlx-probe") {
            try await MLXProbe.run(args)
            return
        }
        if args.string("jev-reports") != nil {
            try await JevReportsJudge.run(args)
            return
        }
        if args.flag("latency-probe") {
            for draft in ["so basically we need to like fix the login", "Okay, bye bye, talk soon.", "the import it it fails on files over like two gigs i think we should not we should never try to load the whole file"] {
                for _ in 0..<2 {
                    let probe = await AppleFoundationModel.latencyProbe(
                        instructions: SmartCleaner.cleanupInstructions(confidenceGuided: false),
                        schema: SmartCleaner.cleanedSchema, draft: draft)
                    print(probe.map { Int($0) })
                }
            }
            return
        }
        if let parallel = args.int("concurrency") {
            try await concurrencyProbe(parallel, polished: args.cleanupLevel == .polished)
            return
        }
        let level = args.cleanupLevel
        let grammarRepair = level == .polished
        print("level: \(level.rawValue) (grammarRepair: \(grammarRepair))")
        let cases = try Runners.loadGolden(args)
        let options = CleanupOptions(level: level)
        for item in cases {
            let start = Date()
            let cleaner = SmartCleaner(budget: .milliseconds(6000), correctionBudget: .milliseconds(6000))
            let result = await cleaner.clean(item.spoken, options: options, strategy: .model, incremental: false)
            let elapsed = Date().timeIntervalSince(start) * 1000
            let ruled = TextCleaner(options: options).clean(item.spoken).text
            let rawAnswer = await SmartCleaner.debugAsk(draft: ruled, budgetMs: 6000, grammarRepair: grammarRepair)
            print("---")
            print("id: \(item.id)")
            print("spoken: \(item.spoken)")
            print("rules draft: \(ruled)")
            print("raw model answer (pre-guard): \(rawAnswer ?? "nil")")
            print("output (post-guard/rank): \(result.text)")
            print("usedModel: \(result.usedModel) rejection: \(result.rejection ?? "none") elapsedMs: \(Int(elapsed))")
            if let rawAnswer, rawAnswer != ruled {
                let assessment = await SmartCleaner.debugRerank(raw: item.spoken, rules: ruled, model: rawAnswer, remainingMs: 6000)
                print("rerank assessment: \(String(describing: assessment))")
            }
        }
    }

    /// `murmur-eval try "<text>" [--level clean|polished] [--raw-model]`: one string through the
    /// production path, with the rules draft and the model's use/rejection printed — a debugging
    /// aid for cleanup work, not a scored eval.
    static func tryText(_ args: Arguments) async throws {
        let options = try args.cleanupOptions(level: args.cleanupLevel)
        let cleaner = args.makeCleaner()
        cleaner.prewarm(prefixesFor: options.level, grammarContract: options.grammarContract)
        for text in args.positional {
            let start = Date()
            let result = await cleaner.clean(text, options: options)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            print("input:  \(text)")
            print("rules:  \(TextCleaner(options: options).clean(text).text)")
            print("groups: \(TextSegmentation.groups(text).map(\.text))")
            if args.flag("raw-model") {
                let ruled = TextCleaner(options: options).clean(text).text
                let raw = await SmartCleaner.debugAsk(draft: ruled, budgetMs: 8000, grammarRepair: options.level == .polished)
                print("model:  \(raw ?? "nil")")
            }
            print("output: \(result.text)")
            print("usedModel: \(result.usedModel) rejection: \(result.rejection ?? "none") \(elapsed) ms\n")
        }
    }

    /// `model-diag --concurrency N`: does the on-device model actually serve N concurrent
    /// requests faster than N serial ones? Decides whether long-dictation chunks are cleaned in
    /// parallel or serially (see `SmartCleaner.cleanSegmented`).
    static func concurrencyProbe(_ count: Int, polished: Bool) async throws {
        let drafts = [
            "So the thing with the pricing page is basically that like it doesn't actually say what's free and what's paid right.",
            "So people like sign up and then they're kind of surprised when voice actions are locked.",
            "And I think we should basically just have a simple table you know so it's it's obvious.",
            "The import it it fails on files over like two gigs and we should stream it in chunks.",
        ]
        let chosen = (0..<count).map { drafts[$0 % drafts.count] }
        _ = await SmartCleaner.debugAsk(draft: "Warm up the model please.", budgetMs: 10_000, grammarRepair: polished)
        let serialStart = Date()
        for draft in chosen { _ = await SmartCleaner.debugAsk(draft: draft, budgetMs: 20_000, grammarRepair: polished) }
        let serial = Date().timeIntervalSince(serialStart) * 1000
        let parallelStart = Date()
        let answers = await withTaskGroup(of: Double.self) { group in
            for draft in chosen {
                group.addTask {
                    let start = Date()
                    _ = await SmartCleaner.debugAsk(draft: draft, budgetMs: 20_000, grammarRepair: polished)
                    return Date().timeIntervalSince(start) * 1000
                }
            }
            var each: [Double] = []
            for await value in group { each.append(value) }
            return each
        }
        let parallel = Date().timeIntervalSince(parallelStart) * 1000
        print("serial \(count) calls: \(Int(serial)) ms (\(Int(serial / Double(count))) ms/call)")
        print("parallel \(count) calls: \(Int(parallel)) ms wall; per-call \(answers.map { Int($0) })")
    }
}
