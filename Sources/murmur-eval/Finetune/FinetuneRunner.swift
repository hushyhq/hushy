import Foundation
import MurmurCore

/// `murmur-eval finetune …` — the Swift half of the M7 fine-tune pipeline (`scripts/finetune`,
/// `docs/product/FINETUNE.md`). Python builds seeds, templates and the manifest; these
/// subcommands do the parts that must match the shipping runtime exactly:
///
///   finetune prompt --level clean|polished
///       print the compact system prompt (`CompactCleanupPrompt`)
///   finetune prepare --in cand.jsonl --out prepared.jsonl
///       rows {id, level, raw, target[, protected]} → + draft (the rules text the model sees),
///       rejection (production guards on target-as-answer), modelAsked, unchanged
///   finetune jev --in rows.jsonl --out judged.jsonl --max-calls N [--ledger file] [--cap 400]
///       [--only <bool field>] [--spoken-key raw] [--output-key target] [--reference-key k]
///       Jev rubric v2 pointwise → + pBad, jevBand, jevFaults; uncached calls are budgeted and
///       added to the ledger so the whole pipeline stays under one cap
///   finetune llm --in prompts.jsonl --out responses.jsonl --max-calls N [--llm claude|codex]
///       [--model haiku] [--timeout 300]
///       rows {id, prompt} → + text, through the CLI-judge plumbing (sandboxed, no tools), cached
///   finetune groups --in rows.jsonl --out groups.jsonl [--level clean] [--text-key text]
///       rows {id, text} → the groups the app cuts the text into (`TextSegmentation.groups`) with each
///       group's rules draft and the whole text's rules draft; no model call (`FinetuneGroups.swift`)
///   finetune verdicts --in rows.jsonl --out verdicts.jsonl [--bundle id] [--as-spoken] [--allow-paragraph-breaks]
///       rows {id, raw, target[, bundle]} → the first `TrainingPairCheck` rejection on the release route's draft
///       (Polished by default). The app may prepare, repair or retry later; no model call
///   finetune export --in rows.jsonl --out-dir dir
///       rows {id, level, draft, target, split} → train.jsonl / valid.jsonl in chat format with
///       the compact prompt and the exact compact-JSON answer, plus export.json
///   finetune tools-prompt | tools-check | tools-export
///       the voice-actions (tools-v1) training data: labels checked by the shipping validators and
///       the grammar, rendered in the runtime's exact prompt and envelope (`FinetuneTools.swift`)
///
/// Every path goes through `FinetunePathGuard` (no held-out, Voice Lab or app-data paths).
enum FinetuneRunner {
    static func run(_ args: Arguments) async throws {
        switch args.positional.first ?? "" {
        case "prompt":
            let version = try promptVersion(args)
            print(CompactCleanupPrompt.systemText(
                level: CleanupLevel(rawValue: args.string("level") ?? "clean") ?? .clean, version: version))
        case "prepare": try prepare(args)
        case "groups": try FinetuneGroups.run(args)
        case "verdicts": try FinetuneVerdicts.run(args)
        case "jev": try await FinetuneJev.run(args)
        case "llm": try await FinetuneLLM.run(args)
        case "export": try FinetuneExport.run(args)
        case "broad-export": try BroadCleanTraining.run(args)
        case "broad-review-packet": try BroadCleanReviewPacket.run(args)
        case "broad-validate-v2": try BroadCleanSupervisionValidation.run(args)
        case "tools-prompt", "tools-check", "tools-export": try FinetuneTools.run(args.positional[0], args)
        default:
            throw EvalError.missing("usage: murmur-eval finetune prompt|prepare|groups|verdicts|jev|llm|export|broad-export|broad-review-packet|broad-validate-v2|tools-prompt|tools-check|tools-export … (see FinetuneRunner.swift, FinetuneTools.swift)")
        }
    }

    static func required(_ args: Arguments, _ key: String) throws -> String {
        guard let value = args.string(key) else { throw EvalError.missing("finetune: --\(key) is required") }
        return value
    }

    static func promptVersion(_ args: Arguments) throws -> CompactCleanupPrompt.Version {
        let raw = args.string("prompt-version") ?? CompactCleanupPrompt.version
        guard let version = CompactCleanupPrompt.Version(rawValue: raw) else {
            throw EvalError.missing("finetune: --prompt-version must be compact-v2, compact-v3, compact-v4, or compact-v4-polished-bridge")
        }
        return version
    }

    static func requireExportableVersion(_ version: CompactCleanupPrompt.Version) throws {
        guard version == .v2 || version == .v3 else {
            throw EvalError.missing("v4 training preparation/export requires an independent semantic review pipeline; hard checks alone cannot approve targets")
        }
    }

    // MARK: - prepare

    static func prepare(_ args: Arguments) throws {
        let version = try promptVersion(args)
        try requireExportableVersion(version)
        let rows = try FinetuneJSONL.read(try required(args, "in"))
        var reasons: [String: Int] = [:]
        let prepared = rows.map { row in
            let result = prepareRow(row, version: version)
            let reason = (result["rejection"] as? String).map { $0.components(separatedBy: ":").first ?? $0 } ?? "accepted"
            reasons[reason, default: 0] += 1
            return result
        }
        try FinetuneJSONL.write(prepared, to: try required(args, "out"))
        let accepted = reasons["accepted"] ?? 0
        print("finetune prepare: \(prepared.count) rows, \(accepted) accepted by the guards")
        for (reason, count) in reasons.sorted(by: { $0.value > $1.value }) where reason != "accepted" {
            print("  rejected \(count): \(reason)")
        }
    }

    /// One candidate row plus the rules draft and the guard verdict.
    static func prepareRow(
        _ row: FinetuneJSONL.Row, version: CompactCleanupPrompt.Version = .v2
    ) -> FinetuneJSONL.Row {
        var row = row
        guard let raw = FinetuneJSONL.string(row, "raw"), let target = FinetuneJSONL.string(row, "target") else {
            row["rejection"] = "missing raw/target"
            return row
        }
        let level = CleanupLevel(rawValue: FinetuneJSONL.string(row, "level") ?? "clean") ?? .clean
        let protected = row["protected"] as? [String] ?? []
        let result = TrainingPairCheck.check(
            raw: raw, target: target, level: level, protectedTerms: protected, version: version)
        row["draft"] = result.draft
        row["rejection"] = result.rejection ?? NSNull()
        row["modelAsked"] = result.modelAsked
        row["unchanged"] = target == result.draft
        return row
    }
}
