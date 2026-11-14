import Foundation
import MurmurCore

/// `murmur-eval external …` — Hushy's cleanup on public disfluency-removal sets, scored with the
/// DRES metric (primary, comparable in kind to the paper's table) plus Hushy's own guards.
///
///   murmur-eval external list
///   murmur-eval external import <disfluencyspeech|disflqa> [--split test]
///   murmur-eval external <name> [--split test] [--sample N | --limit N] [--strategy hybrid]
///       [--level clean] [--oracle gold|identity] [--outputs outputs.json] [--label text]
///       [--report path.json] [--backend …]
///   murmur-eval external rescore <report.json> [--emit]
///
/// Cleanup runs through `DictationPipeline.clean` (production rules → gate → model → OutputGuard)
/// exactly as `murmur-eval cleanup` does. `--oracle gold` scores the gold fluent text (the
/// scorer's ceiling, should be 100), `--oracle identity` scores the input unchanged, and
/// `--outputs` scores someone else's outputs (a JSON object of row id → text, e.g. a cloud
/// model's answers produced elsewhere) on the same rows and metric. `rescore` re-prints a saved
/// report's summary with the current metrics (appended to Evals/results.md only with `--emit`).
enum ExternalRunner {
    static func run(_ args: Arguments) async throws {
        guard let first = args.positional.first else {
            throw EvalError.missing("usage: murmur-eval external list|import <name>|<name> [options] (see ExternalRunner.swift)")
        }
        switch first {
        case "list": list()
        case "rescore": try rescore(args)
        case "import":
            let benchmark = try named(args.positional.dropFirst().first)
            let split = args.string("split") ?? benchmark.defaultSplit
            let set = try await ExternalImporter.importSet(benchmark, split: split, root: Paths.data)
            print("imported \(set.items.count) rows of \(set.huggingFaceID) \(split) → "
                + ExternalImporter.file(benchmark, split: split, root: Paths.data).path)
            print("licence: \(set.license)")
        default:
            try await evaluate(try named(first), args: args)
        }
    }

    private static func named(_ name: String?) throws -> ExternalBenchmark {
        guard let name, let benchmark = ExternalBenchmark(rawValue: name) else {
            throw EvalError.missing("unknown external benchmark \(name ?? "") (expected \(ExternalBenchmark.allCases.map(\.rawValue).joined(separator: "|")))")
        }
        return benchmark
    }

    private static func list() {
        for benchmark in ExternalBenchmark.allCases {
            print("\(benchmark.rawValue): \(benchmark.summary)\n  \(benchmark.huggingFaceID) · \(benchmark.license)\n  cite: \(benchmark.citation)")
        }
        print("\nDRES paper reference (Switchboard Treebank-3, LDC licence; E_F, segmented, zero-shot):")
        for row in PublishedDRES.zeroShotSegmented { print("  \(row.model): \(row.f1) (P \(row.precision), R \(row.recall))") }
    }

    // MARK: Evaluation

    struct CaseOutcome: Codable {
        let id: String
        let input: String
        let output: String
        let fluent: String
        /// Gold tokens and DRES tags, so a run can be re-scored with the paper's Python.
        let goldTokens: [String]
        let goldTags: [DRESScorer.Tag]
        let counts: DRESScorer.Counts
        let exactMatch: Bool
        let usedModel: Bool
        let rejection: String?
        let latencyMs: Double
    }

    private static func evaluate(_ benchmark: ExternalBenchmark, args: Arguments) async throws {
        let split = args.string("split") ?? benchmark.defaultSplit
        let existing = try ExternalImporter.load(benchmark, split: split, root: Paths.data)
        let set = if let existing { existing } else {
            try await ExternalImporter.importSet(benchmark, split: split, root: Paths.data)
        }
        var items = set.items
        if let sample = args.int("sample") { items = ExternalImporter.evenSample(items, count: sample) }
        if let limit = args.int("limit") { items = Array(items.prefix(limit)) }

        let loadBefore = loadAverage()
        let outcomes = try await clean(items, benchmark: benchmark, args: args)
        let loadAfter = loadAverage()

        let summary = ExternalSummary(benchmark: benchmark, outcomes: outcomes.scored, skipped: outcomes.skipped)
        let label = runLabel(args)
        let header = "### External · \(benchmark.rawValue) \(split) · \(label) · \(outcomes.scored.count) rows"
            + (outcomes.skipped > 0 ? " (\(outcomes.skipped) skipped: gold not derivable by deletion or no supplied output)" : "")
        Runners.emit(header + "\n" + summary.markdown(loadBefore: loadBefore, loadAfter: loadAfter))
        if let path = args.string("report") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(outcomes.scored.map(\.outcome)).write(to: URL(fileURLWithPath: path), options: .atomic)
            print("report → \(path)")
        }
    }

    struct Scored {
        let outcome: CaseOutcome
        let scores: DRESScorer.Scores
        let outputWords: Int
    }

    /// Re-summarises a saved `--report` with the current metric code (load average unknown).
    private static func rescore(_ args: Arguments) throws {
        guard let path = args.positional.dropFirst().first else { throw EvalError.missing("usage: external rescore <report.json>") }
        let cases = try JSONDecoder().decode([CaseOutcome].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let benchmark: ExternalBenchmark = cases.first?.id.hasPrefix("dqa-") == true ? .disflQA : .disfluencySpeech
        let scored = cases.map { Scored(outcome: $0, scores: DRESScorer.scores($0.counts), outputWords: DRESScorer.outputTokens($0.output).count) }
        let summary = ExternalSummary(benchmark: benchmark, outcomes: scored, skipped: 0)
        let text = "### External · \(benchmark.rawValue) · rescored \(URL(fileURLWithPath: path).lastPathComponent) · \(scored.count) rows\n"
            + summary.markdown(loadBefore: "n/a", loadAfter: "n/a")
        if args.flag("emit") { Runners.emit(text) } else { print(text) }
    }

    /// `--outputs <file>`: row id → output text produced outside Hushy.
    private static func externalOutputs(_ args: Arguments) throws -> [String: String]? {
        guard let path = args.string("outputs") else { return nil }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private static func clean(
        _ items: [ExternalItem], benchmark: ExternalBenchmark, args: Arguments
    ) async throws -> (scored: [Scored], skipped: Int) {
        let oracle = args.string("oracle")
        if let oracle, oracle != "gold", oracle != "identity" {
            throw EvalError.missing("--oracle must be gold or identity")
        }
        let supplied = try externalOutputs(args)
        let cleaner = args.makeCleaner()
        if oracle == nil && supplied == nil { cleaner.prewarm() }
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: args.cleanupLevel))
        var scored: [Scored] = []
        var skipped = 0
        for (index, item) in items.enumerated() {
            let gold = benchmark.gold(for: item)
            // DisfluencySpeech tags need B and C to be deletions of A; Disfl-QA keeps rewrites.
            if benchmark == .disfluencySpeech && !gold.derivedByDeletion {
                skipped += 1
                continue
            }
            let start = Date()
            let output: String, usedModel: Bool, rejection: String?
            switch oracle {
            case "gold": (output, usedModel, rejection) = (item.fluent, false, nil)
            case "identity": (output, usedModel, rejection) = (item.disfluent, false, nil)
            case _ where supplied != nil:
                guard let text = supplied?[item.id] else {
                    skipped += 1
                    continue
                }
                (output, usedModel, rejection) = (text, false, nil)
            default:
                let result = await pipeline.clean(item.disfluent, settings: settings, strategy: args.strategy)
                (output, usedModel, rejection) = (result.text, result.usedModel, result.rejection)
            }
            let latency = Date().timeIntervalSince(start) * 1000
            let rows = DRESScorer.align(tokens: gold.tokens, tags: gold.tags, generated: output)
            let counts = DRESScorer.counts(rows)
            let outcome = CaseOutcome(
                id: item.id, input: item.disfluent, output: output, fluent: item.fluent,
                goldTokens: gold.tokens, goldTags: gold.tags, counts: counts,
                exactMatch: DRESScorer.goldTokens(output) == DRESScorer.goldTokens(item.fluent),
                usedModel: usedModel, rejection: rejection, latencyMs: latency)
            scored.append(Scored(outcome: outcome, scores: DRESScorer.scores(counts), outputWords: DRESScorer.outputTokens(output).count))
            if (index + 1) % 100 == 0 { FileHandle.standardError.write(Data("  \(index + 1)/\(items.count)\n".utf8)) }
        }
        return (scored, skipped)
    }

    private static func runLabel(_ args: Arguments) -> String {
        if let label = args.string("label") { return label }
        if let oracle = args.string("oracle") { return "oracle-\(oracle)" }
        if let outputs = args.string("outputs") { return "outputs \(URL(fileURLWithPath: outputs).lastPathComponent)" }
        var parts = ["backend \(args.string("backend") ?? "apple")"]
        if let entry = args.string("local-model") { parts.append(entry) }
        if let directory = args.string("mlx-model") { parts.append(URL(fileURLWithPath: directory).lastPathComponent) }
        if let prompt = args.string("mlx-prompt") { parts.append("prompt \(prompt)") }
        parts.append("\(args.strategy.rawValue)/\(args.cleanupLevel.rawValue)")
        if args.string("clean-gate") == "always" { parts.append("gate always") }
        return parts.joined(separator: " · ")
    }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "n/a" }
        return loads.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }
}

/// The paper's aggregate, the pooled view, and Hushy's guards for one run.
struct ExternalSummary {
    let benchmark: ExternalBenchmark
    let outcomes: [ExternalRunner.Scored]
    let skipped: Int

    var paper: DRESScorer.Aggregate { DRESScorer.Aggregate(rows: outcomes.map(\.scores)) }
    var pooledCounts: DRESScorer.Counts { outcomes.map(\.outcome.counts).reduce(DRESScorer.Counts(), +) }
    var pooled: DRESScorer.Aggregate { DRESScorer.Aggregate(pooled: pooledCounts) }

    /// Share of fluent gold tokens the output removed — Hushy's "never drop the user's words" guard.
    var overDeletionRate: Double {
        let c = pooledCounts
        return c.fp + c.tn == 0 ? 0 : Double(c.fp) / Double(c.fp + c.tn)
    }

    /// Output tokens aligned to no input token (rewrites, hallucinations), per output token.
    var insertionRate: Double {
        let words = outcomes.map(\.outputWords).reduce(0, +)
        return words == 0 ? 0 : Double(pooledCounts.inserted) / Double(words)
    }

    var casesWithOverDeletion: Int { outcomes.filter { $0.outcome.counts.fp > 0 }.count }
    var exactMatches: Int { outcomes.filter(\.outcome.exactMatch).count }
    var modelUses: Int { outcomes.filter(\.outcome.usedModel).count }

    /// Why the model's answer was not used, by `ModelOutcome` (not-asked and used excluded):
    /// e.g. "rejected-by-guard 12, timeout 3".
    var fallbackBreakdown: String {
        var counts: [ModelOutcome: Int] = [:]
        for item in outcomes {
            let outcome = ModelOutcome(usedModel: item.outcome.usedModel, rejection: item.outcome.rejection)
            if outcome != .used && outcome != .notAsked { counts[outcome, default: 0] += 1 }
        }
        let parts = ModelOutcome.allCases.compactMap { outcome in counts[outcome].map { "\(outcome.rawValue) \($0)" } }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    /// Gold-fluent words missing from the output after Whisper normalisation (so "seventeen" vs
    /// "17" or "ten dollars" vs "$10" is not a loss): the meaning-preservation guard, independent
    /// of DRES's tags. Deleted or rewritten reference words count as missing.
    var fluentWordsMissing: Double {
        var missing = 0, total = 0
        for item in outcomes {
            let reference = WhisperEnglishNormalizer.words(item.outcome.fluent)
            let hypothesis = WhisperEnglishNormalizer.words(item.outcome.output)
            total += reference.count
            for op in SequenceMatcher(reference, hypothesis).opcodes where op.tag == .delete || op.tag == .replace {
                missing += op.i2 - op.i1
            }
        }
        return total == 0 ? 0 : Double(missing) / Double(total)
    }

    var werVsFluent: Double {
        WhisperEnglishNormalizer.corpusWER(outcomes.map { ($0.outcome.fluent, $0.outcome.output) })
    }

    var latencyP50: Double {
        let sorted = outcomes.map(\.outcome.latencyMs).sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    func markdown(loadBefore: String, loadAfter: String) -> String {
        let p = paper, q = pooled
        let n = max(1, outcomes.count)
        func f(_ value: Double) -> String { value.isNaN ? "–" : String(format: "%.2f", value) }
        func pct(_ value: Double) -> String { String(format: "%.1f%%", 100 * value) }
        let zPq = benchmark == .disflQA ? "" : " · Z_P \(f(q.zPrn))"
        return """
            - DRES metric, pooled over all tokens (headline): **E_F \(f(q.f1))** · E_P \(f(q.precision)) · E_R \(f(q.recall)) · Z_E \(f(q.zEdited)) · Z_I \(f(q.zIntj))\(zPq) (TP \(pooledCounts.tp), FP \(pooledCounts.fp), FN \(pooledCounts.fn))
            - DRES per-row mean (the paper's aggregation; rows with nothing removed drop out of E_P/E_F): E_F \(f(p.f1)) · E_P \(f(p.precision)) · E_R \(f(p.recall))
            - Hushy guards: DRES-fluent tokens removed \(pct(overDeletionRate)), in \(casesWithOverDeletion)/\(outcomes.count) rows · gold-fluent words missing after number/spelling normalisation \(pct(fluentWordsMissing)) · inserted/rewritten tokens \(pct(insertionRate)) of output · exact match \(exactMatches)/\(outcomes.count) (\(pct(Double(exactMatches) / Double(n)))) · WER vs gold fluent (Whisper-normalised) \(pct(werVsFluent))
            - Model output used on \(modelUses)/\(outcomes.count) rows · not used: \(fallbackBreakdown) · cleanup p50 \(Int(latencyP50)) ms · load average \(loadBefore) → \(loadAfter)
            """
    }
}

/// Published DRES numbers (arXiv 2509.20321v1, Table 3, "ss" = segmented input, k = 0), ×100.
/// No Claude or Gemini model is in the paper.
enum PublishedDRES {
    struct Row { let model: String; let f1: Double; let precision: Double; let recall: Double }

    static let zeroShotSegmented: [Row] = [
        Row(model: "gpt-4o", f1: 78.17, precision: 78.44, recall: 78.30),
        Row(model: "gpt-4o-mini", f1: 72.69, precision: 75.61, recall: 70.48),
        Row(model: "Llama-3.3-70B-Instruct", f1: 76.14, precision: 77.87, recall: 75.10),
        Row(model: "Llama-3.1-8B-Instruct", f1: 68.30, precision: 63.97, recall: 74.22),
        Row(model: "Llama-3.2-3B-Instruct", f1: 67.52, precision: 65.81, recall: 70.20),
        Row(model: "Qwen3-8B", f1: 71.46, precision: 78.32, recall: 66.17),
        Row(model: "Qwen3-4B", f1: 68.48, precision: 67.96, recall: 69.95),
        Row(model: "Qwen3-1.7B", f1: 36.00, precision: 71.41, recall: 24.79),
        Row(model: "Phi-4-mini-instruct", f1: 36.91, precision: 25.42, recall: 70.73),
        Row(model: "MobileLLM-1B", f1: 33.38, precision: 22.40, recall: 68.78),
    ]
}
