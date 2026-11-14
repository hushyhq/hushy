import Foundation

/// `finetune jev`: Jev rubric v2, pointwise, over arbitrary JSONL rows — used for the MLX vs
/// Apple FM A/B (compare pBad distributions, `Evals/JUDGES.md` policy), for filtering synthetic
/// pairs (keep pBad < 0.3) and for scoring fine-tuned outputs.
///
/// Budget: `--max-calls` caps this run's *uncached* calls; `--ledger` is a small JSON file that
/// accumulates uncached calls across runs and `--cap` (default 400) caps the total, so every
/// pipeline step shares one Jev allowance. Cached answers (`.build/judge-cache/jev/`, keyed by the
/// full request) are free and never counted. Rows the budget can't cover get `jevSkipped`.
enum FinetuneJev {
    struct Ledger: Codable {
        var uncachedCalls = 0
        var runs: [Run] = []

        struct Run: Codable {
            let label: String
            let uncachedCalls: Int
            let cachedCalls: Int
            let skipped: Int
            let timestamp: String
        }
    }

    static func run(_ args: Arguments) async throws {
        let rows = try FinetuneJSONL.read(try FinetuneRunner.required(args, "in"))
        let outPath = try FinetuneRunner.required(args, "out")
        guard let maxCalls = args.int("max-calls") else { throw EvalError.missing("finetune jev: --max-calls is required") }
        guard let apiKey = JudgeRunner.loadAPIKey() else {
            throw EvalError.missing("finetune jev: no TypeSafe API key (TYPESAFE_API_KEY or ~/.config/hushy/typesafe_api_key)")
        }
        let ledgerURL = try args.string("ledger").map(FinetunePathGuard.checked)
        var ledger = ledgerURL.flatMap { try? JSONDecoder().decode(Ledger.self, from: Data(contentsOf: $0)) } ?? Ledger()
        let cap = args.int("cap") ?? 400
        let allowance = max(0, min(maxCalls, cap - ledger.uncachedCalls))
        let budget = CallBudget(name: "jev", limit: allowance)
        let judge = JevJudge(apiKey: apiKey, budget: budget)

        let keys = Keys(
            spoken: args.string("spoken-key") ?? "raw", output: args.string("output-key") ?? "target",
            reference: args.string("reference-key"), level: args.string("level-key") ?? "level")
        let only = args.string("only")
        let indexed = rows.enumerated().filter { _, row in only.map { row[$0] as? Bool ?? false } ?? true }
        let jobs = indexed.map { index, row in Job(index: index, request: keys.request(row)) }

        let useCache = !args.flag("no-cache")
        let answers = try await JudgeClient.mapConcurrently(jobs) { job -> (Int, Outcome) in
            guard let request = job.request else { return (job.index, .invalid) }
            do {
                let timed = try await judge.judge(
                    level: request.level, spoken: request.spoken, output: request.output, reference: request.reference, useCache: useCache)
                return (job.index, .judged(timed.value, cached: timed.seconds == nil))
            } catch is CallBudget.Exhausted {
                return (job.index, .skipped)
            } catch {
                return (job.index, .failed(error.localizedDescription))
            }
        }

        var out = rows
        var uncached = 0, cached = 0, skipped = 0
        for (index, outcome) in answers {
            switch outcome {
            case .judged(let judgment, let wasCached):
                if wasCached { cached += 1 } else { uncached += 1 }
                out[index]["pBad"] = judgment.pBad
                out[index]["jevBand"] = judgment.band.rawValue
                out[index]["jevMeaning"] = judgment.meaning
                out[index]["jevFaults"] = judgment.faults.filter { $0.value >= 0.3 }
            case .skipped:
                skipped += 1
                out[index]["jevSkipped"] = "budget"
            case .invalid:
                out[index]["jevSkipped"] = "missing fields"
            case .failed(let message):
                skipped += 1
                out[index]["jevSkipped"] = "error: \(message)"
            }
        }
        try FinetuneJSONL.write(out, to: outPath)

        ledger.uncachedCalls += uncached
        ledger.runs.append(.init(
            label: args.string("label") ?? outPath, uncachedCalls: uncached, cachedCalls: cached, skipped: skipped,
            timestamp: ISO8601DateFormatter().string(from: Date())))
        if let ledgerURL {
            try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
        }
        print("finetune jev: judged \(uncached + cached) of \(jobs.count) (uncached \(uncached), cached \(cached), skipped \(skipped)); ledger total \(ledger.uncachedCalls)/\(cap)")
    }

    private enum Outcome: Sendable {
        case judged(JevJudgment, cached: Bool)
        case skipped
        case invalid
        case failed(String)
    }

    private struct Request: Sendable {
        let level: String
        let spoken: String
        let output: String
        let reference: String?
    }

    private struct Job: Sendable {
        let index: Int
        let request: Request?
    }

    private struct Keys {
        let spoken: String
        let output: String
        let reference: String?
        let level: String

        func request(_ row: FinetuneJSONL.Row) -> Request? {
            guard let spoken = row[spoken] as? String, let output = row[output] as? String else { return nil }
            return Request(
                level: row[level] as? String ?? "clean", spoken: spoken, output: output,
                reference: reference.flatMap { row[$0] as? String }.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}
