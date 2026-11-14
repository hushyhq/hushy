import Foundation
import MurmurCore

/// `murmur-eval dev-messages [--cases Evals/developer-messages-dev.json] [--level clean|polished|both]
///   [--clean-gate heuristic|always] [--report path.json] [--min-pass 0.NN]`
///
/// Developer messages (Slack, PR and ticket comments, incident updates, email) through the same
/// text path as a real dictation: the target's bundle ID and window title go to the real
/// `AppCategory.classify`, the category decides the style and cleanup options exactly as
/// `DictationController.pipelineSettings` does, and `DictationPipeline.clean` runs cleanup
/// (the level's own strategy: Clean = hybrid, Polished = model) and then styling. Nothing is
/// special-cased per phrase; the checks (DevMessageChecks) are general properties of the output.
///
/// Each case is also run rules-only (`strategy: .rules`, same settings) so a failure can be
/// attributed to a stage. Run with `--backend local --mlx-model <dir>` for the app's own Hushy
/// local model, or `--backend none` for rules only. Development set, not sealed.
enum DevMessagesRunner {
    static let defaultCases = "developer-messages-dev.json"

    /// What the app derives from a category, so the expected and the actual classification can be compared.
    struct Config: Equatable {
        let context: StyleContext?
        let isCode: Bool
        let isCasual: Bool
    }

    /// Mirrors `DictationController.pipelineSettings(for:settings:)` with default app settings
    /// (default style per context, no personalizer, no mode, no project vocabulary).
    static func config(for category: AppCategory) -> Config {
        Config(
            context: StyleContext.from(category), isCode: category == .code,
            isCasual: [.personalMessages, .workMessages].contains(category))
    }

    static func pipelineSettings(
        for category: AppCategory, level: CleanupLevel, bundleID: String? = nil, windowTitle: String? = nil
    ) -> PipelineSettings {
        let derived = config(for: category)
        var options = CleanupOptions(level: level)
        options.isCodeContext = derived.isCode
        options.isCasualContext = derived.isCasual
        options.technicalTokens = TechnicalTokenContext.make(category: category, bundleID: bundleID, windowTitle: windowTitle)
        let style = derived.context.map { ($0, $0.defaultStyle) }
        return PipelineSettings(cleanupOptions: options, style: style)
    }

    struct Record {
        let item: DevMessageChecks.Case
        let level: CleanupLevel
        let category: AppCategory
        let expected: AppCategory
        let output: String
        let rulesOutput: String
        let usedModel: Bool
        let rejection: String?
        let outcomes: [DevMessageChecks.Outcome]
        let rulesOutcomes: [DevMessageChecks.Outcome]

        var passed: Bool { outcomes.allSatisfy(\.passed) }
        var classificationMatches: Bool { category == expected }
        var configMatchesExpected: Bool { DevMessagesRunner.config(for: category) == DevMessagesRunner.config(for: expected) }
        var failed: [DevMessageChecks.Outcome] { outcomes.filter { !$0.passed } }
        /// The model stage was reached (it answered, was guarded out, timed out or failed); only a
        /// missing model counts as "never ran", so rules-only runs report missing features honestly.
        var modelWasAttempted: Bool { usedModel || (rejection != nil && rejection != "model unavailable") }
        var cause: DevMessageChecks.Cause? {
            guard !passed else { return nil }
            return DevMessageChecks.attribute(
                failed: failed, rulesOutcomes: rulesOutcomes, configMatchesExpected: configMatchesExpected,
                modelRan: modelWasAttempted)
        }
    }

    static func loadCases(_ url: URL) throws -> DevMessageChecks.CaseSet {
        let set = try JSONDecoder().decode(DevMessageChecks.CaseSet.self, from: Data(contentsOf: url))
        guard set.format == "hushy.developer-messages/v1" else { throw EvalError.missing("Unknown case format \(set.format)") }
        guard set.split == "dev" else { throw EvalError.missing("dev-messages only runs the dev split (got \(set.split))") }
        guard !set.cases.isEmpty, Set(set.cases.map(\.id)).count == set.cases.count else {
            throw EvalError.missing("Case set must be nonempty with unique IDs")
        }
        for item in set.cases where AppCategory(rawValue: item.target.expectedCategory) == nil {
            throw EvalError.missing("Case \(item.id): unknown expectedCategory \(item.target.expectedCategory)")
        }
        return set
    }

    static func levels(_ args: Arguments) throws -> [CleanupLevel] {
        switch args.string("level") ?? "both" {
        case "clean": return [.clean]
        case "polished": return [.polished]
        case "both": return [.clean, .polished]
        case let other: throw EvalError.missing("--level must be clean, polished or both (got \(other))")
        }
    }

    static func run(_ args: Arguments) async throws {
        let url = args.string("cases").map { URL(fileURLWithPath: $0) } ?? Paths.root.appendingPathComponent(defaultCases)
        let set = try loadCases(url)
        let levels = try levels(args)
        // Production runs SmartCleaner with the default gate (.always); only the eval's own default differs.
        let gate = args.string("clean-gate").flatMap(SmartCleaner.CleanGate.init(rawValue:)) ?? .always
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: SmartCleaner(cleanGate: gate))

        var records: [Record] = []
        for level in levels {
            for item in set.cases {
                let category = AppCategory.classify(bundleID: item.target.bundleID, windowTitle: item.target.windowTitle)
                let expected = AppCategory(rawValue: item.target.expectedCategory) ?? .other
                let settings = pipelineSettings(
                    for: category, level: level, bundleID: item.target.bundleID, windowTitle: item.target.windowTitle)
                let final = await pipeline.clean(item.raw, settings: settings, strategy: nil)
                let rules = await pipeline.clean(item.raw, settings: settings, strategy: .rules)
                records.append(Record(
                    item: item, level: level, category: category, expected: expected, output: final.text,
                    rulesOutput: rules.text, usedModel: final.usedModel, rejection: final.rejection,
                    outcomes: DevMessageChecks.evaluate(item.checks, raw: item.raw, output: final.text),
                    rulesOutcomes: DevMessageChecks.evaluate(item.checks, raw: item.raw, output: rules.text)))
            }
        }

        let summary = DevMessagesReport.Summary(
            records: records, levels: levels, caseFile: url.lastPathComponent, backend: args.string("backend") ?? "apple",
            cleanGate: gate.rawValue)
        DevMessagesReport.print(summary)
        if let path = args.string("report") { try DevMessagesReport.write(summary, to: path, caseFileURL: url) }
        if let minimum = args.string("min-pass") {
            guard let value = Double(minimum), (0...1).contains(value) else { throw EvalError.missing("--min-pass must be a fraction in 0...1") }
            let worst = levels.map { level in
                let rows = records.filter { $0.level == level }
                return rows.isEmpty ? 0 : Double(rows.filter(\.passed).count) / Double(rows.count)
            }.min() ?? 0
            guard worst >= value else {
                FileHandle.standardError.write(Data("dev-messages pass rate \(worst) below required \(value)\n".utf8))
                exit(1)
            }
        }
    }
}
