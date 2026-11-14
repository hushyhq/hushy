import CryptoKit
import Foundation
import MurmurCore

/// `murmur-eval judge calibrate [--set Evals/judge-calibration.json] [--build-set [--seed 7]]
///     [--jev-calls 300] [--codex-calls 60] [--skip-jev] [--skip-codex] [--report path]
///     [--repeats 20] [--repeat-tag repeat-1]`
///
/// Reproduces the judge calibration in `Evals/JUDGES.md`: scores Jev (rubric v2, with and
/// without the reference; rubric v1 for comparison), Codex (gpt-6-luna, low effort, today's
/// CLI-judge prompt) and the deterministic checks against the labeled dev-set reference
/// (`CalibrationSetBuilder`). Every answer is cached (`.build/judge-cache/`), so a rerun with a
/// warm cache makes zero calls; budgets cap *uncached* calls only. DEV sets only.
enum JudgeCalibrationRunner {
    static let defaultSetPath = "Evals/judge-calibration.json"

    struct Subsets {
        /// Codex pointwise subset (stratified by kind).
        let codex: [CalibrationItem]
        /// Ablation subset for Jev v1 and v2-without-reference (prefix of `codex`).
        let ablation: [CalibrationItem]
        /// Determinism probe (prefix of `codex`).
        let repeats: [CalibrationItem]
        /// (good reference, bad perturbation) pairs for pairwise judging.
        let pairs: [(good: CalibrationItem, bad: CalibrationItem)]
    }

    static func run(_ args: Arguments) async throws {
        let setPath = args.string("set") ?? defaultSetPath
        if args.flag("build-set") {
            try await buildSet(path: setPath, seed: args.int("seed") ?? 7, args: args)
            return
        }
        let file = try JSONDecoder().decode(CalibrationSetFile.self, from: Data(contentsOf: URL(fileURLWithPath: setPath)))
        let items = file.items
        let subsets = makeSubsets(items, repeats: args.int("repeats") ?? 20)
        let repeatTag = args.string("repeat-tag") ?? "repeat-1"
        var results = CalibrationResults(items: items)

        if !args.flag("skip-jev") {
            if let apiKey = JudgeRunner.loadAPIKey() {
                let budget = CallBudget(name: "Jev", limit: args.int("jev-calls") ?? 300)
                try await runJev(apiKey: apiKey, budget: budget, repeatTag: repeatTag, items: items, subsets: subsets, into: &results)
                results.jevCallsUsed = await budget.used
            } else {
                print("Jev skipped: no TypeSafe API key (TYPESAFE_API_KEY or ~/.config/hushy/typesafe_api_key)")
            }
        }
        if !args.flag("skip-codex") {
            let budget = CallBudget(name: "Codex", limit: min(args.int("codex-calls") ?? 60, 60))
            await runCodex(budget: budget, subsets: subsets, into: &results)
            results.codexCallsUsed = await budget.used
        }
        CalibrationReport.emit(results, subsets: subsets)
        let reportPath = args.string("report") ?? ".build/judge-calibration/report.json"
        try CalibrationReport.writeJSON(results, path: reportPath)
        print("Per-item results: \(reportPath)")
    }

    // MARK: Set building

    static func buildSet(path: String, seed: Int, args: Arguments) async throws {
        let sources = try CalibrationSetBuilder.loadSources(evals: Paths.root)
        let cleaner = args.makeCleaner()
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: .clean))
        var rules: [String: String] = [:]
        for source in sources where source.level == "clean" && !source.isNegative {
            let result = await pipeline.clean(source.spoken, settings: settings, strategy: .rules)
            rules["\(source.source)/\(source.caseID)/\(source.level)"] = result.text
        }
        let all = CalibrationSetBuilder.candidates(sources, rulesOutputs: rules)
        let overridesURL = Paths.root.appendingPathComponent("judge-calibration-labels.json")
        let overrides = (try? JSONDecoder().decode(
            [String: CalibrationLabelOverride].self, from: Data(contentsOf: overridesURL))) ?? [:]
        let sampled = CalibrationSetBuilder.applyOverrides(CalibrationSetBuilder.sample(all, seed: seed), overrides)
        let file = CalibrationSetFile(
            schemaVersion: 1, generatedAt: ISO8601DateFormatter().string(from: Date()), seed: seed, items: sampled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: URL(fileURLWithPath: path), options: .atomic)
        let counts = Dictionary(grouping: sampled, by: \.kind).mapValues(\.count).sorted { $0.key < $1.key }
        print("Wrote \(sampled.count) items (of \(all.count) candidates) to \(path): "
            + counts.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let unreviewed = sampled.filter { $0.labelSource == "checks" }.map(\.id)
        if !unreviewed.isEmpty {
            print("Hand-review these real_rules items and add them to \(overridesURL.path): \(unreviewed.joined(separator: ", "))")
        }
    }

    // MARK: Subsets

    /// Round-robin over kinds (each kind ordered by a stable hash) so every subset is stratified.
    static func stratified(_ items: [CalibrationItem], count: Int, salt: String) -> [CalibrationItem] {
        var queues = Dictionary(grouping: items, by: \.kind).mapValues {
            $0.sorted { CalibrationSetBuilder.stableHash(salt + $0.id) < CalibrationSetBuilder.stableHash(salt + $1.id) }
        }
        let kinds = queues.keys.sorted()
        var chosen: [CalibrationItem] = []
        while chosen.count < count, queues.values.contains(where: { !$0.isEmpty }) {
            for kind in kinds where chosen.count < count {
                if var queue = queues[kind], !queue.isEmpty {
                    chosen.append(queue.removeFirst())
                    queues[kind] = queue
                }
            }
        }
        return chosen
    }

    static func makeSubsets(_ items: [CalibrationItem], repeats: Int = 20) -> Subsets {
        let codex = stratified(items, count: 45, salt: "codex|")
        let goods = Dictionary(
            items.filter { $0.kind == "correct" }.map { ("\($0.source)/\($0.caseID)/\($0.level)", $0) },
            uniquingKeysWith: { first, _ in first })
        let pairable = items.filter { $0.isBad && $0.kind != "real_rules" && goods["\($0.source)/\($0.caseID)/\($0.level)"] != nil }
        let pairs = stratified(pairable, count: 15, salt: "pair|").map { bad in
            (good: goods["\(bad.source)/\(bad.caseID)/\(bad.level)"]!, bad: bad)
        }
        return Subsets(codex: codex, ablation: Array(codex.prefix(30)), repeats: Array(codex.prefix(repeats)), pairs: pairs)
    }

    // MARK: Jev

    private static func runJev(
        apiKey: String, budget: CallBudget, repeatTag: String, items: [CalibrationItem], subsets: Subsets, into results: inout CalibrationResults
    ) async throws {
        let judge = JevJudge(apiKey: apiKey, budget: budget)
        @Sendable func attempt<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async -> T? {
            do { return try await body() } catch {
                FileHandle.standardError.write(Data("  jev: \(error.localizedDescription)\n".utf8))
                return nil
            }
        }

        let v2 = try await JudgeClient.mapConcurrently(items) { item in
            await attempt { try await judge.judge(level: item.level, spoken: item.spoken, output: item.output, reference: item.reference) }
        }
        for (item, timed) in zip(items, v2) {
            guard let timed else { continue }
            results.jevV2[item.id] = timed.value
            if let seconds = timed.seconds { results.jevLatencies.append(seconds) }
        }
        let noRef = try await JudgeClient.mapConcurrently(subsets.ablation) { item in
            await attempt { try await judge.judge(level: item.level, spoken: item.spoken, output: item.output, reference: nil) }
        }
        for (item, timed) in zip(subsets.ablation, noRef) { results.jevV2NoRef[item.id] = timed?.value }

        let v1 = try await JudgeClient.mapConcurrently(subsets.ablation) { item in
            await attempt {
                let timed = try await judge.cachedAsk(
                    state: JevRubricV1.state(spoken: item.spoken, output: item.output, expected: item.reference),
                    questions: JevRubricV1.questions, useCache: true)
                return try JevRubricV1.decode(timed.value)
            }
        }
        for (item, judgment) in zip(subsets.ablation, v1) { results.jevV1[item.id] = judgment }

        let repeats = try await JudgeClient.mapConcurrently(subsets.repeats) { item in
            await attempt {
                try await judge.judge(level: item.level, spoken: item.spoken, output: item.output, reference: item.reference, repeatTag: repeatTag)
            }
        }
        for (item, timed) in zip(subsets.repeats, repeats) {
            guard let timed else { continue }
            results.jevRepeats[item.id] = timed.value
            if let seconds = timed.seconds { results.jevLatencies.append(seconds) }
        }

        let orders = subsets.pairs.flatMap { pair in [(pair, true), (pair, false)] }
        let pairwise = try await JudgeClient.mapConcurrently(orders) { entry in
            let (pair, goodFirst) = entry
            return await attempt {
                try await judge.prefer(
                    level: pair.good.level, spoken: pair.good.spoken, reference: nil,
                    first: goodFirst ? pair.good.output : pair.bad.output,
                    second: goodFirst ? pair.bad.output : pair.good.output)
            }
        }
        for ((pair, goodFirst), timed) in zip(orders, pairwise) {
            guard let timed else { continue }
            results.jevPairwise.append(.init(badID: pair.bad.id, goodFirst: goodFirst, choice: timed.value.choice))
        }
        results.jevTokens = results.jevV2.values.compactMap(\.inputTokens)
    }

    // MARK: Codex

    private static func runCodex(budget: CallBudget, subsets: Subsets, into results: inout CalibrationResults) async {
        let judge = CodexCLIJudge()
        let cache = JudgeCache()
        @Sendable func isCached(_ item: CalibrationItem) -> Bool {
            let prompt = JudgePrompt.prompt(input: item.spoken, output: item.output, reference: item.reference, rubric: nil)
            return cache.load(cache.key(backend: judge.name, model: judge.model, prompt: prompt)) != nil
        }
        do {
            let verdicts = try await JudgeClient.mapConcurrently(subsets.codex) { item -> (JudgeVerdict, Double?)? in
                let cached = isCached(item)
                if !cached, !(await budget.take()) { return nil }
                let started = Date()
                guard let verdict = try? await judge.judge(input: item.spoken, output: item.output, reference: item.reference, rubric: nil)
                else { return nil }
                return (verdict, cached ? nil : Date().timeIntervalSince(started))
            }
            for (item, entry) in zip(subsets.codex, verdicts) {
                guard let entry else { continue }
                results.codex[item.id] = entry.0
                if let seconds = entry.1 { results.codexLatencies.append(seconds) }
            }
            let uncachedJudge = CodexCLIJudge(cache: nil)
            let repeats = try await JudgeClient.mapConcurrently(Array(subsets.repeats.prefix(5))) { item -> JudgeVerdict? in
                guard await budget.take() else { return nil }
                return try? await uncachedJudge.judge(input: item.spoken, output: item.output, reference: item.reference, rubric: nil)
            }
            for (item, verdict) in zip(subsets.repeats.prefix(5), repeats) { results.codexRepeats[item.id] = verdict }

            let orders = subsets.pairs.prefix(5).flatMap { pair in [(pair, true), (pair, false)] }
            let choices = try await JudgeClient.mapConcurrently(Array(orders)) { entry -> String? in
                let (pair, goodFirst) = entry
                return await codexPairwise(
                    judge: judge, budget: budget, spoken: pair.good.spoken, level: pair.good.level,
                    first: goodFirst ? pair.good.output : pair.bad.output, second: goodFirst ? pair.bad.output : pair.good.output)
            }
            for ((pair, goodFirst), choice) in zip(orders, choices) {
                guard let choice else { continue }
                results.codexPairwise.append(.init(badID: pair.bad.id, goodFirst: goodFirst, choice: choice))
            }
        } catch {
            print("Codex skipped: \(error.localizedDescription)")
        }
    }

    /// Blind A/B through `codex exec`, the same shape as the Clean-gate experiment: returns
    /// "a", "b" or "same"; cached by prompt hash under `.build/judge-cache/calibration-pairwise/`.
    private static func codexPairwise(
        judge: CodexCLIJudge, budget: CallBudget, spoken: String, level: String, first: String, second: String
    ) async -> String? {
        let prompt = """
            You are comparing two cleanups of the same dictation at the \(JevRubric.displayLevel(level)) level. \
            Level rules: \(JevRubric.promise(for: level))
            Faithfulness comes first: an output that drops or changes something the speaker meant is worse \
            than one that keeps a filler. Respond with ONLY a JSON object: {"better": "A" | "B" | "same"}.

            spoken: \(spoken)
            A: \(first)
            B: \(second)
            """
        let directory = JudgeCache.defaultDirectory.appendingPathComponent("calibration-pairwise", isDirectory: true)
        let hex = SHA256.hash(data: Data((judge.model + prompt).utf8)).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("\(hex).txt")
        let text: String
        if let cached = try? String(contentsOf: url, encoding: .utf8) {
            text = cached
        } else {
            guard await budget.take(), let fresh = try? await judge.completeText(prompt: prompt) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fresh.write(to: url, atomically: true, encoding: .utf8)
            text = fresh
        }
        let lower = text.lowercased()
        if lower.contains("\"a\"") { return "a" }
        if lower.contains("\"b\"") { return "b" }
        if lower.contains("same") { return "same" }
        return nil
    }
}

/// Everything one calibration run produced, keyed by item id.
struct CalibrationResults {
    struct PairwiseAnswer: Codable {
        let badID: String
        let goodFirst: Bool
        let choice: String
        /// The judge picked the known-good output.
        var correct: Bool { choice == (goodFirst ? "a" : "b") }
    }

    let items: [CalibrationItem]
    var jevV2: [String: JevJudgment] = [:]
    var jevV2NoRef: [String: JevJudgment] = [:]
    var jevV1: [String: JevRubricV1.Judgment] = [:]
    var jevRepeats: [String: JevJudgment] = [:]
    var jevPairwise: [PairwiseAnswer] = []
    var jevLatencies: [Double] = []
    var jevTokens: [Int] = []
    var jevCallsUsed = 0
    var codex: [String: JudgeVerdict] = [:]
    var codexRepeats: [String: JudgeVerdict] = [:]
    var codexPairwise: [PairwiseAnswer] = []
    var codexLatencies: [Double] = []
    var codexCallsUsed = 0
}
