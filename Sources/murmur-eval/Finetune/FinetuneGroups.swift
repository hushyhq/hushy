import Foundation
import MurmurCore

/// `murmur-eval finetune groups --in rows.jsonl --out groups.jsonl [--level clean] [--prompt-version compact-v2]
/// [--text-key text] [--bundle com.anthropic.claudefordesktop] [--as-spoken]`
///
/// For each row {id, text}: the groups the app cuts the text into (`TextSegmentation.groups`, the same call
/// `SmartCleaner` uses for a dictation without streaming) and each group's rules draft (`TextCleaner` with the
/// training pipeline's options, the same as `finetune prepare`), plus the rules draft of the whole text.
/// With `--bundle` (or a `bundle` field on the row) the drafts are the release route's for that app (`ReleaseRoute`:
/// Polished by default, the app's own cleanup options, so an AI app that reads code writes a spoken file name as code);
/// the row then carries `route`. Without either, the training pipeline's clean/legacy options as before.
/// No model is called and nothing is changed: rows are read, cut and written.
///
///   out row: {id, text, wholeDraft, groupCount, groups: [{index, text, isTail, continuesSentence, words, draft}]}
///
/// The left context of the per-group training contract (the previous group's last sentence) is not computed
/// here: sentence splitting (`Sentences`) is internal to MurmurCore, so the caller derives it from the previous
/// group's `draft`.
enum FinetuneGroups {
    static func run(_ args: Arguments) throws {
        let inPath = try FinetuneRunner.required(args, "in")
        let outPath = try FinetuneRunner.required(args, "out")
        let version = try FinetuneRunner.promptVersion(args)
        try FinetuneRunner.requireExportableVersion(version)
        let level = CleanupLevel(rawValue: args.string("level") ?? "clean") ?? .clean
        let textKey = args.string("text-key") ?? "text"
        let rows = try FinetuneJSONL.read(inPath)
        let defaultBundle = args.string("bundle")
        let asSpoken = args.flag("as-spoken")
        var routes: [String: ReleaseRoute] = [:]
        let out = rows.map { row -> FinetuneJSONL.Row in
            guard let bundle = FinetuneJSONL.string(row, "bundle") ?? defaultBundle else {
                return groupRow(row, level: level, version: version, textKey: textKey)
            }
            let route = routes[bundle] ?? ReleaseRoute(bundleID: bundle, asSpoken: asSpoken)
            routes[bundle] = route
            return groupRow(row, options: route.options, textKey: textKey, route: route.summary)
        }
        try FinetuneJSONL.write(out, to: outPath)
        let groupCounts = out.compactMap { $0["groupCount"] as? Int }
        print("finetune groups: \(out.count) rows, \(groupCounts.reduce(0, +)) groups (most in one row: \(groupCounts.max() ?? 0))")
    }

    static func options(level: CleanupLevel, version: CompactCleanupPrompt.Version) -> CleanupOptions {
        let contract: CleanupOptions.GrammarContract = version == .v3 ? .minimal : .legacy
        return CleanupOptions(level: level, grammarContract: contract)
    }

    static func groupRow(
        _ row: FinetuneJSONL.Row, level: CleanupLevel = .clean, version: CompactCleanupPrompt.Version = .v2, textKey: String = "text"
    ) -> FinetuneJSONL.Row {
        groupRow(row, options: options(level: level, version: version), textKey: textKey, route: nil)
    }

    static func groupRow(
        _ row: FinetuneJSONL.Row, options: CleanupOptions, textKey: String, route: [String: Any]?
    ) -> FinetuneJSONL.Row {
        var out: FinetuneJSONL.Row = [:]
        if let id = row["id"] { out["id"] = id }
        guard let text = FinetuneJSONL.string(row, textKey) ?? FinetuneJSONL.string(row, "spoken") else {
            out["error"] = "missing \(textKey)"
            return out
        }
        let cleaner = TextCleaner(options: options)
        if let route { out["route"] = route }
        let groups = TextSegmentation.groups(text)
        out["text"] = text
        out["wholeDraft"] = cleaner.clean(text).text
        out["groupCount"] = groups.count
        out["groups"] = groups.map { group -> FinetuneJSONL.Row in
            [
                "index": group.index, "text": group.text, "isTail": group.isTail,
                "continuesSentence": group.continuesSentence, "words": TextStats.wordCount(group.text),
                "draft": cleaner.clean(group.text).text,
            ]
        }
        return out
    }
}
