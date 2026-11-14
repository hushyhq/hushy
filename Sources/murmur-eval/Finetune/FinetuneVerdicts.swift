import Foundation
import MurmurCore

/// `murmur-eval finetune verdicts --in rows.jsonl --out verdicts.jsonl [--bundle com.apple.mail] [--as-spoken] [--allow-paragraph-breaks]`
///
/// Rows {id, raw, target[, bundle]}: the first rejection from `TrainingPairCheck` for a pair on the release
/// route's rules draft. The app can prepare, repair, or retry an answer after this check. No model call.
///
/// What can be reached from here, and what cannot (MurmurCore keeps the rest internal):
///   - `TrainingPairCheck.check` is the only public door to `OutputGuard`, `SpokenLayoutGuard`, `ListStructureGuard` and
///     `ProtectedTermGuard`. It builds the rules draft itself from the level alone, so it does not know the app's code
///     options (a code editor's `isCodeContext` turns "auth dot swift" into "auth.swift" in the release draft).
///   - `pairCheckDraftMatchesReleaseDraft` records draft equality; it does not establish app acceptance parity.
///   - Where the drafts differ, `approx*` re-runs the same check with the release draft passed as `raw`, which makes
///     the check's own draft the release draft (`approxDraftReproduced`); `OutputGuard` then misses the words the rules
///     removed from the real raw. It is an approximation and is labelled so.
///   - Not reachable: `TrailOffGuard`, `DroppedClauseGuard`, the answer preparation
///     (`restoringFlattenedBreaks`, `droppingBareRetraction`, `Punctuation.tidy`, `splitInlineBullets`), and the runtime
///     order (layout and list checks before `OutputGuard`): `TrainingPairCheck` runs `OutputGuard` first and the layout and
///     list checks only when it accepts, and it reports the first reason only.
enum FinetuneVerdicts {
    static func run(_ args: Arguments) throws {
        let rows = try FinetuneJSONL.read(try FinetuneRunner.required(args, "in"))
        let defaultBundle = args.string("bundle") ?? "com.anthropic.claudefordesktop"
        let asSpoken = args.flag("as-spoken")
        let allowingParagraphBreaks = args.flag("allow-paragraph-breaks")
        var routes: [String: ReleaseRoute] = [:]
        let out = rows.map { row -> FinetuneJSONL.Row in
            let bundle = FinetuneJSONL.string(row, "bundle") ?? defaultBundle
            let route = routes[bundle] ?? ReleaseRoute(bundleID: bundle, asSpoken: asSpoken)
            routes[bundle] = route
            return verdictRow(row, route: route, allowingParagraphBreaks: allowingParagraphBreaks)
        }
        try FinetuneJSONL.write(out, to: try FinetuneRunner.required(args, "out"))
        let summary = counts(out)
        print("finetune verdicts: \(summary.checked) pairs checked, \(summary.malformed) malformed input rows, \(summary.exact) matching release drafts, \(summary.rejected) first pair-check rejections")
    }

    static func counts(_ rows: [FinetuneJSONL.Row]) -> (checked: Int, malformed: Int, exact: Int, rejected: Int) {
        let checked = rows.filter { $0["error"] == nil }
        return (checked.count, rows.count - checked.count,
                checked.filter { $0["pairCheckDraftMatchesReleaseDraft"] as? Bool == true }.count,
                checked.filter { ($0["rejection"] as? String) != nil }.count)
    }

    static func verdictRow(_ row: FinetuneJSONL.Row, route: ReleaseRoute, allowingParagraphBreaks: Bool = false) -> FinetuneJSONL.Row {
        var out: FinetuneJSONL.Row = [:]
        if let id = row["id"] { out["id"] = id }
        guard let raw = FinetuneJSONL.string(row, "raw"), let target = FinetuneJSONL.string(row, "target") else {
            out["error"] = "missing raw/target"
            return out
        }
        let level = route.options.level
        let releaseDraft = TextCleaner(options: route.options).clean(raw).text
        let own = TrainingPairCheck.check(raw: raw, target: target, level: level, allowingParagraphBreaks: allowingParagraphBreaks)
        out["route"] = route.summary
        out["releaseDraft"] = releaseDraft
        out["ownDraft"] = own.draft
        let exact = own.draft == releaseDraft
        out["pairCheckDraftMatchesReleaseDraft"] = exact
        out["verdictScope"] = "first_training_pair_check_rejection"
        out["rejection"] = own.rejection ?? NSNull()
        out["modelAsked"] = own.modelAsked
        if level != .clean {
            out["rejectionAtClean"] = TrainingPairCheck.check(raw: raw, target: target, level: .clean,
                                                               allowingParagraphBreaks: allowingParagraphBreaks).rejection ?? NSNull()
        }
        if !exact {
            let approx = TrainingPairCheck.check(raw: releaseDraft, target: target, level: level,
                                                 allowingParagraphBreaks: allowingParagraphBreaks)
            out["approxDraftReproduced"] = approx.draft == releaseDraft
            out["approxRejection"] = approx.rejection ?? NSNull()
        }
        return out
    }
}
