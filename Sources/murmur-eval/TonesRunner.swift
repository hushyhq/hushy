import Foundation
import MurmurCore

/// `murmur-eval tones [--set Evals/tones-dev.json] [--path rules|hybrid|wired] [--report path.json]`
///
/// The tone layer (`ToneRegister`) on the development messages. Each case is cleaned the way
/// `dev-messages` does for the Clean level, with the pipeline's own styling switched off so the
/// tone owns the styling, and then every tone is applied to that same cleaned text. The score
/// (ToneEvalChecks) separates exact matches, checks and faithfulness.
///
/// `--path rules` (the default) runs cleanup without a model. `--path hybrid` runs the shipping
/// Clean strategy and only runs if a model is already available; it never downloads one.
/// `--jev` adds a second opinion from Jev (rubric `tone-v1`, `ToneJudge/`) on every output; `--jev-calibrate`
/// instead scores that rubric against the expected outputs in the case file. Both are off by default,
/// send only the invented case text, and never gate (`Evals/JUDGES.md`). `--jev-calls N` caps real calls.
///
/// `--path wired` runs each tone the way the app does since task 112: the tone setting makes the
/// plan (`ToneSettings.plan`: the model level, the tone, the layout), and `DictationPipeline.clean`
/// does cleanup and tone in one call. The base shown for a case is the same cleanup at the same
/// level with no tone, so faithfulness is still judged on what the tone changed.
/// Run with `--backend none` for the rules path. Development set, not sealed.
enum TonesRunner {
    static let defaultCases = "tones-dev.json"

    enum CleanupPath: String {
        case rules, hybrid, wired

        var strategy: SmartCleaner.Strategy? { self == .rules ? .rules : nil }
    }

    struct Row {
        let item: ToneEvalChecks.Case
        let context: StyleContext
        let base: String
        let usedModel: Bool
        let rejection: String?
        let outputs: [DictationTone: String]
        let scores: [DictationTone: ToneEvalChecks.Score]
    }

    static func loadCases(_ url: URL) throws -> ToneEvalChecks.CaseSet {
        let set = try JSONDecoder().decode(ToneEvalChecks.CaseSet.self, from: Data(contentsOf: url))
        guard ["hushy.tones/v1", "hushy.tones/v2"].contains(set.format) else {
            throw EvalError.missing("Unknown case format \(set.format)")
        }
        guard set.split == "dev" else { throw EvalError.missing("tones only runs the dev split (got \(set.split))") }
        guard !set.cases.isEmpty, Set(set.cases.map(\.id)).count == set.cases.count else {
            throw EvalError.missing("Case set must be nonempty with unique IDs")
        }
        for item in set.cases {
            guard AppCategory(rawValue: item.target.expectedCategory) != nil else {
                throw EvalError.missing("Case \(item.id): unknown expectedCategory \(item.target.expectedCategory)")
            }
            for tone in DictationTone.allCases {
                guard let expectation = item.toneExpectations[tone.rawValue] else {
                    throw EvalError.missing("Case \(item.id): no expectation for \(tone.rawValue)")
                }
                if let problem = expectation.writingProblem {
                    throw EvalError.missing("Case \(item.id): \(tone.rawValue) has \(problem)")
                }
                guard expectation.hasEffectiveCheck else {
                    throw EvalError.missing("Case \(item.id): \(tone.rawValue) has no effective check (an empty checks object passes nothing)")
                }
            }
        }
        return set
    }

    /// Tone processing never sees the pipeline's own style: the tone chooses the formatting.
    static func baseSettings(for category: AppCategory, item: ToneEvalChecks.Case, level: CleanupLevel = .clean) -> PipelineSettings {
        var settings = DevMessagesRunner.pipelineSettings(
            for: category, level: level, bundleID: item.target.bundleID, windowTitle: item.target.windowTitle)
        settings.style = nil
        return settings
    }

    /// One dictation through the real pipeline with the tone chosen as the default tone: exactly the
    /// settings `DictationController.pipelineSettings` builds from `ToneSettings.plan`.
    static func wiredOutput(
        _ tone: DictationTone, item: ToneEvalChecks.Case, category: AppCategory, pipeline: DictationPipeline
    ) async -> String {
        // The tone is the person's own choice for this kind of app too, so a place that starts on a
        // different tone (Email starts on Professional) does not hide the choice being measured.
        var tones = ToneSettings.standard
        tones.choice = ToneChoice(tone: tone)
        if let context = StyleContext.from(category) { tones = tones.settingTone(tone, for: context) }
        let plan = tones.plan(for: category)
        var settings = DevMessagesRunner.pipelineSettings(
            for: category, level: plan.level, bundleID: item.target.bundleID, windowTitle: item.target.windowTitle)
        settings.style = plan.style
        settings.tone = plan.tone
        return await pipeline.clean(item.raw, settings: settings).text
    }

    static func run(_ args: Arguments) async throws {
        let url = args.string("set").map { URL(fileURLWithPath: $0) } ?? Paths.root.appendingPathComponent(defaultCases)
        // The remote judge sees only the invented text of the dev sets that ship in the repo.
        if args.flag("jev") || args.flag("jev-calibrate") || args.string("jev-also") != nil {
            try ToneJevSets.requireShipped(url)
            if let also = args.string("jev-also") { try ToneJevSets.requireShipped(URL(fileURLWithPath: also)) }
        }
        let set = try loadCases(url)
        if args.flag("jev-calibrate") {
            try await ToneJevRunner.calibrate(set: set, args: args)
            return
        }
        guard let path = CleanupPath(rawValue: args.string("path") ?? "rules") else {
            throw EvalError.missing("--path must be rules, hybrid or wired")
        }
        if path != .rules, !SmartCleaner.isModelAvailable {
            print("tones --path \(path.rawValue): SKIPPED, no model is available on this machine (nothing was downloaded)")
            return
        }
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: SmartCleaner(cleanGate: .always))

        var rows: [Row] = []
        for item in set.cases {
            let category = AppCategory.classify(bundleID: item.target.bundleID, windowTitle: item.target.windowTitle)
            let context = StyleContext.from(category) ?? .other
            let cleaned = await pipeline.clean(
                item.raw, settings: baseSettings(for: category, item: item, level: path == .wired ? .polished : .clean),
                strategy: path.strategy)
            let base = cleaned.text
            var outputs: [DictationTone: String] = [:]
            var scores: [DictationTone: ToneEvalChecks.Score] = [:]
            for tone in DictationTone.allCases {
                let output: String
                if path == .wired {
                    output = await wiredOutput(tone, item: item, category: category, pipeline: pipeline)
                } else {
                    output = ToneRegister.apply(tone, to: base, in: context)
                }
                outputs[tone] = output
                if let expectation = item.toneExpectations[tone.rawValue] {
                    scores[tone] = ToneEvalChecks.score(tone: tone, expectation: expectation, base: base, output: output)
                }
            }
            rows.append(Row(item: item, context: context, base: base, usedModel: cleaned.usedModel, rejection: cleaned.rejection, outputs: outputs, scores: scores))
        }

        let records = rows.flatMap { row in
            DictationTone.allCases.compactMap { tone in
                row.scores[tone].map { ToneEvalChecks.Record(id: row.item.id, tone: tone, contested: row.item.isContested, score: $0) }
            }
        }
        TonesReport.print(rows: rows, records: records, caseFile: url.lastPathComponent, path: path)
        if let report = args.string("report") {
            try TonesReport.write(rows: rows, records: records, to: report, caseFileURL: url, path: path)
        }
        if args.flag("jev") { try await ToneJevRunner.judge(rows: rows, args: args) }
    }
}
