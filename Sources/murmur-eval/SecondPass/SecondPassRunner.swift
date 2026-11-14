import Foundation
import HushyModelsApple
import HushyModelsMLX
import MurmurCore

/// `murmur-eval second-pass --mlx-model <hushy-cleanup dir> --out <dir> [--plan live:on,replay:on,replay:off,replay:500,…]
///   [--sets long,live,long2] [--setting refined|casual|professional|as-spoken|clean] [--path release|prewarmed]
///   [--long <jsonl>] [--live <jsonl>] [--bundle <id>] [--limit N] [--label name] [--text]`
///
/// Measures the second cleanup pass (`SmartCleaner.secondPass`): how often a group is sent to the second model, what
/// that does to the text, and what it costs. Measurement only: it changes nothing the app does.
///
/// The models are the app's: the Hushy fine-tune through `LocalCleanupBackend` (with Apple's model behind it as the
/// fallback) first, Apple's model as the second pass, each dictation through `PipelineSettings.forDictation` and
/// `DictationPipeline.clean`, cleaned after the key release (`--path release`) unless `--path prewarmed`.
///
/// `--plan` lists the arms, run in order in one process so the models load once:
/// - `live:on` the app as it ships; `live:off` no second pass; `live:<ms>` the second pass's one call cut at that many
///   milliseconds (its answer is used if it arrives in time, else the first pass stands).
/// - `replay:on|off|<ms>` the same three with the answers of the last `live:on` arm played back: no model is called, so
///   the only difference from that live arm is whether a second-pass answer is used. `replay:on` is the check that the
///   playback reproduces the live run; replayed waits are not real and are not reported (the report script derives time
///   from the live arm's own timings).
///
/// Sets: `long` = `Evals/long-dictation-dev.jsonl` scored by `LongDictationScorer`; `live` = `Evals/live-dictation-dev.jsonl`
/// scored by `LiveShapeCases.score`; `long2` = the long set joined in pairs (over 150 words). Development sets only.
/// One JSON file per arm goes to `--out`; `scripts/second-pass-report.py` turns them into tables.
enum SecondPassRunner {
    enum Setting: String, CaseIterable {
        case refined, casual, professional
        case asSpoken = "as-spoken"
        /// Not a tone: the Clean level that notes, imported files and the built-in modes run at.
        case clean

        var choice: ToneChoice {
            switch self {
            case .refined, .clean: .refined
            case .casual: .casual
            case .professional: .professional
            case .asSpoken: .asSpoken
            }
        }
    }

    struct Item {
        let set: String
        let id: String
        let spoken: String
        let score: @Sendable (_ output: String) -> (faults: [String: Int], extras: [String: Int])
    }

    struct ArmSpec {
        let live: Bool
        /// nil = second pass off; `.max` = on with the app's own ceiling; else the budget in milliseconds.
        let budgetMs: Int?
        var name: String { "\(live ? "live" : "replay"):\(secondPass)" }
        var secondPass: String { budgetMs.map { $0 == .max ? "on" : String($0) } ?? "off" }

        init?(_ text: String) {
            let parts = text.split(separator: ":").map(String.init)
            guard parts.count == 2, ["live", "replay"].contains(parts[0]) else { return nil }
            live = parts[0] == "live"
            switch parts[1] {
            case "on": budgetMs = .max
            case "off": budgetMs = nil
            default:
                guard let ms = Int(parts[1]), ms > 0 else { return nil }
                budgetMs = ms
            }
        }
    }

    static func settings(_ setting: Setting, bundleID: String) -> PipelineSettings {
        let category = AppCategory.classify(bundleID: bundleID, windowTitle: nil)
        var tones = ToneSettings.standard
        tones.choice = setting.choice
        let mode = MurmurCore.Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        var settings = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: tones.dictationLevel), tone: tones, mode: mode, category: category,
            bundleID: bundleID, windowTitle: nil)
        if setting == .clean {
            settings.cleanupOptions.level = .clean
            settings.tone = nil
            settings.style = nil
        }
        return settings
    }

    static func longItem(_ item: LongDictationCase, set: String) -> Item {
        Item(set: set, id: item.id, spoken: item.spoken) { output in
            let groups = TextSegmentation.groups(item.spoken)
            let result = LongDictationScorer.score(
                item, output: output, groupTexts: groups.map(\.text), groupContinues: groups.map(\.continuesSentence))
            let f = result.faults
            return (
                ["filler": f.filler, "restart": f.restart, "falseStart": f.falseStart, "correction": f.correction,
                 "runOn": f.runOn, "badJoin": f.badJoin, "missingParagraph": f.missingParagraph,
                 "missingItems": f.missingItems, "negationAdded": f.negationAdded, "negationRemoved": f.negationRemoved,
                 "numberChanged": f.numberChanged],
                ["layout": f.layout, "meaning": f.meaning, "wordErrors": result.wordErrors,
                 "referenceWords": result.referenceWords, "longestSentenceWords": f.longestSentenceWords])
        }
    }

    static func liveItem(_ item: LiveShapeCases.Case) -> Item {
        Item(set: "live", id: item.id, spoken: item.spoken) { output in
            let s = LiveShapeCases.score(
                item, output: output, groupTexts: TextSegmentation.groups(item.spoken).map(\.text), outcomes: [])
            return (
                ["hedgeLeft": s.hedgeLeft, "legitRemoved": s.legitRemoved, "doubledLeft": s.doubledLeft, "missing": s.missing,
                 "seams": s.seams, "joinsBroken": s.joinsBroken, "mixedLeft": s.mixedLeft, "trailsMissing": s.trailsMissing,
                 "identifiersMissing": s.identifiersMissing, "fragmentsLeft": s.fragmentsLeft,
                 "notQuestionsWrong": s.notQuestionsWrong],
                ["hedgeIn": s.hedgeIn, "legitIn": s.legitIn, "doubledIn": s.doubledIn, "mustIn": s.mustIn, "joinsIn": s.joinsIn,
                 "mixedIn": s.mixedIn, "trailsIn": s.trailsIn, "identifiersIn": s.identifiersIn, "fragmentsIn": s.fragmentsIn,
                 "notQuestionsIn": s.notQuestionsIn, "questionsIn": s.questionsIn, "questionsKept": s.questionsKept,
                 "contractionsLeft": s.contractionsLeft, "contractionsIn": s.contractionsIn])
        }
    }

    static func loadItems(_ args: Arguments) throws -> [Item] {
        let sets = (args.string("sets") ?? "long,live").split(separator: ",").map(String.init)
        let longPath = args.string("long") ?? Paths.root.appendingPathComponent("long-dictation-dev.jsonl").path
        let livePath = args.string("live") ?? Paths.root.appendingPathComponent("live-dictation-dev.jsonl").path
        var items: [Item] = []
        for set in sets {
            let loaded: [Item]
            switch set {
            case "long": loaded = try LongDictationCase.load(longPath).map { longItem($0, set: "long") }
            case "long2": loaded = LongDictationRunner.pairedUp(try LongDictationCase.load(longPath)).map { longItem($0, set: "long2") }
            case "live": loaded = try LiveShapeCases.load(livePath).map(liveItem)
            default: throw EvalError.missing("--sets takes long, live and long2 (got \(set))")
            }
            items += args.int("limit").map { Array(loaded.prefix($0)) } ?? loaded
        }
        return items
    }

    static func loadAverages() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        getloadavg(&values, 3)
        return values
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// What every arm of one invocation shares.
    struct Session {
        let setting: Setting
        let base: PipelineSettings
        let pathName: String
        let bundleID: String
        let label: String
        let items: [Item]
        let entry: LocalModelEntry
        let chain: LocalCleanupBackend.Chain
        let apple: AppleFoundationModel
        let callLog: ModelCallLog
        let outDirectory: URL
        let printsText: Bool
    }

    static func run(_ args: Arguments) async throws {
        guard let modelPath = args.string("mlx-model") else {
            throw EvalError.missing("second-pass needs --mlx-model <the Hushy cleanup model's folder>")
        }
        guard let outPath = args.string("out") else { throw EvalError.missing("second-pass needs --out <folder for the reports>") }
        guard let setting = Setting(rawValue: args.string("setting") ?? "refined") else {
            throw EvalError.missing("--setting takes \(Setting.allCases.map(\.rawValue).joined(separator: "|"))")
        }
        let pathName = args.string("path") ?? "release"
        guard ["release", "prewarmed"].contains(pathName) else { throw EvalError.missing("--path must be release or prewarmed") }
        let specs = try (args.string("plan") ?? "live:on").split(separator: ",").map { text -> ArmSpec in
            guard let spec = ArmSpec(String(text)) else { throw EvalError.missing("unknown arm \(text) (live|replay : on|off|<ms>)") }
            return spec
        }
        let bundleID = args.string("bundle") ?? "com.anthropic.claudefordesktop"
        let outDirectory = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        // The app's own chain: the fine-tune first, Apple's model behind it, each leg timed (never its text).
        let entry = try args.localModelEntry()
        let callLog = ModelCallLog(capacity: 4_096)
        let session = Session(
            setting: setting, base: settings(setting, bundleID: bundleID), pathName: pathName, bundleID: bundleID,
            label: args.string("label") ?? setting.rawValue, items: try loadItems(args), entry: entry,
            chain: LocalCleanupBackend.chain(
                entry: entry, directory: URL(fileURLWithPath: modelPath, isDirectory: true), fallback: AppleFoundationModel(),
                idleSeconds: nil, callLog: callLog),
            apple: AppleFoundationModel(), callLog: callLog, outDirectory: outDirectory, printsText: args.flag("text"))
        let needsLive = specs.contains(where: \.live)
        if needsLive, case .unavailable(let reason) = session.chain.mlx.availability {
            throw EvalError.missing("the local model cannot run: \(reason)")
        }
        let level = session.base.cleanupOptions.level
        print("### Second pass · \(session.items.count) dictations · setting \(setting.rawValue) · level \(level.rawValue) · tone \(session.base.tone?.rawValue ?? "-") · path \(pathName) · \(bundleID)")
        print("first model \(session.chain.model.identifier) (\(entry.id)); second model \(session.apple.identifier), \(session.apple.isAvailable ? "available" : "NOT available")")
        if needsLive, level != .verbatim { await warmUp(session) }

        // Replay arms answer from the tape of the last live arm that ran with the second pass on.
        var tape = CallTape()
        var liveOutputs: [String: String] = [:]
        for (number, spec) in specs.enumerated() {
            let records = spec.live && spec.budgetMs == .max
            if records { tape = CallTape() }
            let arm = try await runArm(spec, number: number, session: session, tape: tape, records: records, liveOutputs: liveOutputs)
            if records { liveOutputs = Dictionary(arm.dictations.map { ("\($0.set)/\($0.id)", $0.output) }) { first, _ in first } }
        }
    }

    /// Untimed: loads both models so that no measured dictation pays for a cold start.
    static func warmUp(_ session: Session) async {
        guard let first = session.items.first else { return }
        _ = await LiveShapeCases.clean(
            first.spoken, base: session.base, tone: .refined, prewarm: false,
            primary: SmartCleaner(model: session.chain.model, secondOpinion: session.apple), second: nil)
        _ = await SmartCleaner(model: session.apple).clean(
            "so um I think we should like move the the meeting to Thursday you know", options: CleanupOptions(level: .polished))
    }

    /// The two models one arm runs with, and the second pass's live time budget when it has one.
    static func models(
        for spec: ArmSpec, session: Session, tape: CallTape, records: Bool
    ) -> (first: any LanguageModel, second: (any LanguageModel)?, budget: Duration?) {
        // A live arm that is not being recorded calls the models directly; a replay arm answers from the tape.
        let firstRole: TapedModel.Role = spec.live ? .record : .replay(budgetMs: nil)
        let first: any LanguageModel = spec.live && !records
            ? session.chain.model : TapedModel(base: session.chain.model, label: "first", tape: tape, role: firstRole)
        guard let budgetMs = spec.budgetMs else { return (first, nil, nil) }
        // MurmurCore's call timer (the eval has a trace recorder of the same name).
        let timed = MurmurCore.RecordingLanguageModel(session.apple, label: "second", log: session.callLog)
        let cut: Int? = budgetMs == .max ? nil : budgetMs
        guard spec.live else {
            return (first, TapedModel(base: timed, label: "second", tape: tape, role: .replay(budgetMs: cut.map { Double($0) })), nil)
        }
        let second: any LanguageModel = records ? TapedModel(base: timed, label: "second", tape: tape, role: .record) : timed
        return (first, second, cut.map { .milliseconds($0) })
    }

    static func runArm(
        _ spec: ArmSpec, number: Int, session: Session, tape: CallTape, records: Bool, liveOutputs: [String: String]
    ) async throws -> SecondPassRecords.Arm {
        let (firstModel, secondModel, liveBudget) = models(for: spec, session: session, tape: tape, records: records)
        // One count of abandoned calls for the whole arm, as the app keeps one for the session.
        let abandoned = AbandonedCalls()
        let started = Date()
        let loadAtStart = loadAverages()
        _ = tape.drainCounters()
        var rows: [SecondPassRecords.Dictation] = []
        for item in session.items {
            tape.begin(scope: "\(item.set)/\(item.id)")
            session.callLog.clear()
            let cleaner = SmartCleaner(
                model: firstModel, retainsRejectedCandidates: true, abandoned: abandoned, secondOpinion: secondModel,
                secondPassBudget: liveBudget)
            let load = loadAverages()[0]
            let (text, traces, wait) = await LiveShapeCases.clean(
                item.spoken, base: session.base, tone: .refined, prewarm: session.pathName == "prewarmed", primary: cleaner, second: nil)
            let scored = item.score(text)
            rows.append(SecondPassRecords.Dictation(
                set: item.set, id: item.id, spokenWords: TextStats.wordCount(item.spoken),
                plannedGroups: TextSegmentation.groups(item.spoken).count, waitMs: wait * 1_000, output: text,
                faults: scored.faults, extras: scored.extras,
                groups: traces.enumerated().map { SecondPassRecords.group($1, index: $0) },
                calls: session.callLog.recent.map { .init(backend: $0.backend, ms: $0.milliseconds, outcome: $0.outcome.rawValue) },
                load: load, toneMs: tonePassMs(text, context: session.base.style?.context ?? .other)))
            if session.printsText { print("  [\(spec.name)] \(item.set)/\(item.id): \(text.replacingOccurrences(of: "\n", with: "⏎"))") }
        }
        let counters = tape.drainCounters()
        let identical: Int? = !spec.live && spec.budgetMs == .max
            ? rows.filter { liveOutputs["\($0.set)/\($0.id)"] == $0.output }.count : nil
        let arm = SecondPassRecords.Arm(
            label: session.label, kind: spec.live ? "live" : "replay", secondPass: spec.secondPass, setting: session.setting.rawValue,
            level: session.base.cleanupOptions.level.rawValue, path: session.pathName, bundleID: session.bundleID,
            firstModel: "\(session.chain.model.identifier) (\(session.entry.id))",
            secondModel: secondModel == nil ? nil : session.apple.identifier,
            started: ISO8601DateFormatter().string(from: started), seconds: Date().timeIntervalSince(started),
            loadAtStart: loadAtStart, loadAtEnd: loadAverages(), thermalAtEnd: thermal(),
            replayHits: counters.hits, replayMisses: counters.misses, replayLate: counters.late,
            identicalToLive: identical, dictations: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = session.outDirectory.appendingPathComponent(
            "\(session.label)-\(String(format: "%02d", number + 1))-\(spec.name.replacingOccurrences(of: ":", with: "-")).json")
        try encoder.encode(arm).write(to: file)
        print(summary(arm, file: file.lastPathComponent))
        return arm
    }

    /// How long the rule-only tone pass takes on a finished text, by tone, in milliseconds.
    static func tonePassMs(_ text: String, context: StyleContext) -> [String: Double] {
        var result: [String: Double] = [:]
        for tone in [DictationTone.casual, .professional] {
            let start = ContinuousClock.now
            _ = ToneRegister.apply(tone, layout: tone.formattingStyle, to: text, in: context)
            result[tone.rawValue] = ModelPace.ms(ContinuousClock.now - start)
        }
        return result
    }

    static func summary(_ arm: SecondPassRecords.Arm, file: String) -> String {
        let groups = arm.dictations.flatMap(\.groups)
        var fates: [String: Int] = [:]
        for group in groups { fates[group.fate, default: 0] += 1 }
        let waits = arm.dictations.map { $0.waitMs / 1_000 }
        let fateText = SecondPassRecords.Fate.allCases.compactMap { fate in fates[fate.rawValue].map { "\(fate.rawValue) \($0)" } }
            .joined(separator: ", ")
        var line = "- \(arm.kind):\(arm.secondPass) → \(file): \(arm.dictations.count) dictations, \(groups.count) groups (\(fateText)); "
            + "wait median \(String(format: "%.2f", LiveShapeCases.percentile(waits, 0.5))) s, worst \(String(format: "%.2f", waits.max() ?? 0)) s, "
            + "total \(String(format: "%.0f", waits.reduce(0, +))) s; arm took \(String(format: "%.0f", arm.seconds)) s; "
            + "load \(String(format: "%.1f", arm.loadAtStart[0])) → \(String(format: "%.1f", arm.loadAtEnd[0])); thermal \(arm.thermalAtEnd)"
        if arm.kind == "replay" {
            line += "; replay served \(arm.replayHits), no recording for \(arm.replayMisses), withheld as late \(arm.replayLate)"
        }
        if let identical = arm.identicalToLive { line += "; text identical to the live run in \(identical) of \(arm.dictations.count)" }
        return line
    }
}
