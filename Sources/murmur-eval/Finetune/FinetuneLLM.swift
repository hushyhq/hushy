import CryptoKit
import MurmurCore
import Foundation

/// `finetune llm`: runs generation prompts through the dev-only CLI judges (`claude -p` with no
/// tools and no MCP, or `codex exec` read-only at low effort — the same sandboxed invocation as
/// `ClaudeCLIJudge`/`CodexCLIJudge`, sanctioned for synthetic data in DECISIONS 2026-09-26).
/// Answers are cached under `.build/finetune-cache/llm/` by (backend, model, prompt hash), so a
/// rerun is free and reproducible; `--max-calls` caps uncached calls.
enum FinetuneLLM {
    static func run(_ args: Arguments) async throws {
        let rows = try FinetuneJSONL.read(try FinetuneRunner.required(args, "in"))
        let outPath = try FinetuneRunner.required(args, "out")
        guard let maxCalls = args.int("max-calls") else { throw EvalError.missing("finetune llm: --max-calls is required") }
        let backend = args.string("llm") ?? "claude"
        let timeout = TimeInterval(args.int("timeout") ?? 300)
        let complete: @Sendable (String) async throws -> String
        let model: String
        switch backend {
        case "claude":
            model = args.string("model") ?? "haiku"
            let judge = ClaudeCLIJudge(model: model, cache: nil, timeout: timeout)
            complete = { try await judge.completeText(prompt: $0) }
        case "codex":
            model = args.string("model") ?? "gpt-6-luna"
            let judge = CodexCLIJudge(model: model, cache: nil, timeout: timeout)
            complete = { try await judge.completeText(prompt: $0) }
        default:
            throw EvalError.missing("finetune llm: --llm must be claude or codex")
        }
        let cache = TextCache(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/finetune-cache/llm", isDirectory: true))
        let budget = CallBudget(name: "llm", limit: maxCalls)

        let prompts = rows.enumerated().map { index, row in (index, row["prompt"] as? String) }
        let results = try await JudgeClient.mapConcurrently(prompts) { index, prompt -> (Int, String?, String?, Bool) in
            guard let prompt else { return (index, nil, "missing prompt", false) }
            let key = cache.key(backend: backend, model: model, prompt: prompt)
            if let cached = cache.load(key) { return (index, cached, nil, true) }
            guard await budget.take() else { return (index, nil, "budget", false) }
            do {
                let text = try await complete(prompt)
                cache.store(text, key: key)
                return (index, text, nil, false)
            } catch {
                return (index, nil, error.localizedDescription, false)
            }
        }
        var out = rows
        var fresh = 0, cachedCount = 0, failed = 0
        for (index, text, error, wasCached) in results {
            if let text {
                out[index]["text"] = text
                if wasCached { cachedCount += 1 } else { fresh += 1 }
            } else {
                failed += 1
                out[index]["error"] = error ?? "unknown"
            }
            out[index]["llm"] = "\(backend):\(model)"
            out[index].removeValue(forKey: "prompt")
        }
        try FinetuneJSONL.write(out, to: outPath)
        print("finetune llm (\(backend):\(model)): \(fresh) new calls, \(cachedCount) cached, \(failed) failed or over budget")
    }

    /// Plain-text answer cache (the judge cache stores verdicts, not free text).
    struct TextCache: Sendable {
        let directory: URL

        func key(backend: String, model: String, prompt: String) -> String {
            let digest = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
            return "\(backend)__\(model)__\(digest)"
        }

        func load(_ key: String) -> String? {
            try? String(contentsOf: directory.appendingPathComponent("\(key).txt"), encoding: .utf8)
        }

        func store(_ text: String, key: String) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? text.write(to: directory.appendingPathComponent("\(key).txt"), atomically: true, encoding: .utf8)
        }
    }
}

/// `finetune export`: the training files, rendered from the Swift source of truth so the prompt
/// the model is trained on is byte-identical to what `MLXLanguageModel` sends under
/// `promptProfile = .compact`.
enum FinetuneExport {
    static func run(_ args: Arguments) throws {
        let version = try FinetuneRunner.promptVersion(args)
        try FinetuneRunner.requireExportableVersion(version)
        let rows = try FinetuneJSONL.read(try FinetuneRunner.required(args, "in"))
        let outDir = try FinetuneRunner.required(args, "out-dir")
        _ = try FinetunePathGuard.checked(outDir)
        var splits: [String: [FinetuneJSONL.Row]] = ["train": [], "valid": []]
        for row in rows {
            guard let example = chatExample(row, version: version) else { continue }
            let split = row["split"] as? String == "valid" ? "valid" : "train"
            splits[split, default: []].append(example)
        }
        var files: [String: [String: Any]] = [:]
        for (split, examples) in splits {
            let path = outDir + "/\(split).jsonl"
            try FinetuneJSONL.write(examples, to: path)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            files[split] = [
                "rows": examples.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            ]
        }
        let summary: [String: Any] = [
            "promptVersion": version.rawValue,
            "systemClean": CompactCleanupPrompt.systemText(level: .clean, version: version),
            "systemPolished": CompactCleanupPrompt.systemText(level: .polished, version: version),
            "files": files,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: try FinetunePathGuard.checked(outDir + "/export.json"))
        print("finetune export: train \(splits["train"]?.count ?? 0), valid \(splits["valid"]?.count ?? 0) → \(outDir)")
    }

    /// One `{"messages": [system, user, assistant]}` row, or nil when the row lacks a draft or
    /// target.
    static func chatExample(
        _ row: FinetuneJSONL.Row, version: CompactCleanupPrompt.Version = .v2
    ) -> FinetuneJSONL.Row? {
        guard let draft = row["draft"] as? String, let target = row["target"] as? String else { return nil }
        let level = CleanupLevel(rawValue: row["level"] as? String ?? "clean") ?? .clean
        return [
            "id": row["id"] as? String ?? "",
            "messages": [
                ["role": "system", "content": CompactCleanupPrompt.systemText(level: level, version: version)],
                ["role": "user", "content": CompactCleanupPrompt.userPrompt(draft: draft)],
                ["role": "assistant", "content": CompactCleanupPrompt.answerJSON(target)],
            ],
        ]
    }
}
