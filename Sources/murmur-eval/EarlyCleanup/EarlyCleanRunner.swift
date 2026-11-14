import Foundation
import HushyModelsApple
import HushyModelsMLX
import MurmurCore

/// `murmur-eval early-clean --out <dir> (--events <events.json> | --sets long,live [--wps 2.5]) --mlx-model <dir>
///   [--arms ref,legacy,early:prefix:1] [--first 10] [--stretch 0] [--limit N] [--label name] [--bundle id] [--dry]`
///
/// The wait after the key release with and without cleaning sentence groups while the person is still speaking, on the
/// app's own models, and the check that the delivered text is the same either way.
///
/// Input is either `events.json` from `murmur-eval early-text` (dev dictations spoken aloud: the recogniser's real
/// transcripts on the way and at the end) or the dev text itself (`--sets`), arriving at `--wps` words a second with
/// no recogniser at all. Arms, run in order on every dictation:
/// - `ref`: nothing is cleaned early; the final transcript is cleaned after the release. Every other arm's text is
///   compared with this one's.
/// - `legacy`: the app before this change. The while-speaking recogniser starts at the first two-second tick at or
///   after 15 s, its confirmed text has its closed groups cleaned (`SmartCleaner.prewarmGroup`, matched at the release
///   by their words), and the release waits for that recogniser's last chunk.
/// - `early:<source>:<sightings>`: `SmartCleaner.cleanEarly` through `DictationPipeline`. `prefix` hears a pass over
///   the recording so far (first at `--first` seconds, then every `max(2 s, --stretch × length)`); `volatile` reads the
///   while-speaking recogniser from the start, unconfirmed text included. A group is cleaned once that many
///   transcripts in a row have shown it closed and unchanged.
///
/// The speech is not replayed in real time (see `EarlySimulation`): each pass and each model call takes the time it
/// really took and the gaps are skipped. `--dry` loads no model and only counts which groups each source would have
/// had ready, assuming 0.3 s a group.
enum EarlyCleanRunner {
    enum Source: String { case prefix, volatile }

    enum Kind: Equatable {
        case ref, legacy
        case early(Source, sightings: Int)
    }

    struct ArmSpec {
        let name: String
        let kind: Kind

        init?(_ text: String) {
            let parts = text.split(separator: ":").map(String.init)
            name = text
            switch parts.first {
            case "ref" where parts.count == 1: kind = .ref
            case "legacy" where parts.count == 1: kind = .legacy
            case "early" where parts.count == 3:
                guard let source = Source(rawValue: parts[1]), let sightings = Int(parts[2]), sightings > 0 else { return nil }
                kind = .early(source, sightings: sightings)
            default: return nil
            }
        }
    }

    /// One dictation as the recogniser saw it, from audio or stood in for by its text.
    struct Input {
        let set: String
        let id: String
        let spokenWords: Int
        let seconds: Double
        let final: String
        let confidences: [WordConfidence]?
        let finalMs: Double
        let prefixes: [EarlyRecords.Heard]
        let sliding: [EarlyRecords.Sliding]
        let stopMs: Double
    }

    struct Config {
        let first: Double
        let stretch: Double
        let tick: Double
        /// Today's app starts the while-speaking recogniser at the first tick at or after this many seconds.
        let activation = 15.0
        let dry: Bool
        static let dryGroupSeconds = 0.3
    }

    static func loadInputs(_ args: Arguments) throws -> (inputs: [Input], described: String) {
        if let path = args.string("events") {
            let file = try JSONDecoder().decode(EarlyRecords.EventsFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let clips = args.int("limit").map { Array(file.clips.prefix($0)) } ?? file.clips
            return (clips.map { clip in
                Input(set: clip.set, id: clip.id, spokenWords: clip.spokenWords, seconds: clip.seconds, final: clip.final,
                      confidences: clip.finalConfidences?.map { WordConfidence(word: $0.word, confidence: $0.confidence) },
                      finalMs: clip.finalMs, prefixes: clip.prefixes, sliding: clip.sliding, stopMs: clip.slidingStopMs)
            }, "spoken (\(file.voice) at \(file.rate) words a minute\((file.pauseMs ?? 0) > 0 ? ", a \(file.pauseMs ?? 0) ms pause every \(file.pauseEvery ?? 0) words" : ""), recogniser \(file.recogniser))")
        }
        let wps = Double(args.string("wps") ?? "2.5") ?? 2.5
        let tick = EarlyTextRunner.tick
        return (try SecondPassRunner.loadItems(args).map { item in
            let heard = EarlySimulation.spokenSoFar(item.spoken, wordsPerSecond: wps, tick: tick)
            return Input(set: item.set, id: item.id, spokenWords: TextStats.wordCount(item.spoken), seconds: heard.seconds,
                         final: item.spoken, confidences: nil, finalMs: 0, prefixes: heard.transcripts,
                         sliding: EarlySimulation.slidingSoFar(item.spoken, wordsPerSecond: wps, tick: tick), stopMs: 0)
        }, "text at \(wps) words a second, no recogniser")
    }

    static func run(_ args: Arguments) async throws {
        guard let outPath = args.string("out") else { throw EvalError.missing("early-clean needs --out <folder for the reports>") }
        let specs = try (args.string("arms") ?? "ref,legacy,early:prefix:1").split(separator: ",").map { text -> ArmSpec in
            guard let spec = ArmSpec(String(text)) else {
                throw EvalError.missing("unknown arm \(text) (ref | legacy | early:prefix|volatile:<sightings>)")
            }
            return spec
        }
        let config = Config(
            first: Double(args.string("first") ?? "10") ?? 10, stretch: Double(args.string("stretch") ?? "0") ?? 0,
            tick: EarlyTextRunner.tick, dry: args.flag("dry"))
        let (inputs, described) = try loadInputs(args)
        let bundleID = args.string("bundle") ?? "com.anthropic.claudefordesktop"
        let settings = SecondPassRunner.settings(.refined, bundleID: bundleID)
        let outDirectory = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        let label = args.string("label") ?? (args.string("events") == nil ? "text" : "spoken")
        print("### Early cleanup · \(inputs.count) dictations · \(described) · first pass at \(config.first) s, stretch \(config.stretch)\(config.dry ? " · dry (no model)" : "")")

        if config.dry {
            for spec in specs where spec.kind != .ref && spec.kind != .legacy {
                let rows = await dryRows(spec, inputs: inputs, settings: settings, config: config)
                print(drySummary(spec, rows: rows))
            }
            return
        }
        guard let modelPath = args.string("mlx-model") else {
            throw EvalError.missing("early-clean needs --mlx-model <the Hushy cleanup model's folder> (or --dry)")
        }
        let entry = try args.localModelEntry()
        let callLog = ModelCallLog(capacity: 4_096)
        let warmItem = SecondPassRunner.Item(set: "warm", id: "warm", spoken: inputs.first?.final ?? "") { _ in ([:], [:]) }
        let session = SecondPassRunner.Session(
            setting: .refined, base: settings, pathName: "release", bundleID: bundleID, label: label, items: [warmItem],
            entry: entry,
            chain: LocalCleanupBackend.chain(
                entry: entry, directory: URL(fileURLWithPath: modelPath, isDirectory: true), fallback: AppleFoundationModel(),
                idleSeconds: nil, callLog: callLog, speculation: try args.speculationOverride(),
                tuning: args.speculationTuning()),
            apple: AppleFoundationModel(), callLog: callLog, outDirectory: outDirectory, printsText: args.flag("text"))
        if case .unavailable(let reason) = session.chain.mlx.availability {
            throw EvalError.missing("the local model cannot run: \(reason)")
        }
        print("first model \(session.chain.model.identifier) (\(entry.id)); second model \(session.apple.identifier), \(session.apple.isAvailable ? "available" : "NOT available")")
        await SecondPassRunner.warmUp(session)

        var reference: [String: EarlyRecords.Row] = [:]
        for (number, spec) in specs.enumerated() {
            let arm = await runArm(spec, inputs: inputs, session: session, config: config, described: described)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = outDirectory.appendingPathComponent(
                "\(label)-\(String(format: "%02d", number + 1))-\(spec.name.replacingOccurrences(of: ":", with: "-")).json")
            try encoder.encode(arm).write(to: file)
            if spec.kind == .ref { reference = Dictionary(arm.dictations.map { ("\($0.set)/\($0.id)", $0) }) { first, _ in first } }
            print(summary(arm, file: file.lastPathComponent, reference: spec.kind == .ref ? [:] : reference))
        }
    }

    static func time(_ work: () async -> Void) async -> Double {
        let start = ContinuousClock.now
        await work()
        return ModelPace.ms(ContinuousClock.now - start) / 1_000
    }

    /// The transcripts an arm's early cleaning hears, and what the release must wait for before its own pass.
    static func heard(
        _ kind: Kind, input: Input, config: Config
    ) -> (transcripts: [EarlySimulation.Transcript], blockSeconds: Double, passes: Int, passMs: Double) {
        switch kind {
        case .ref:
            return ([], 0, 0, 0)
        case .legacy:
            let started = input.sliding.contains { $0.t >= config.activation }
            return (EarlySimulation.legacyTranscripts(input.sliding, activation: config.activation),
                    started ? input.stopMs / 1_000 : 0, 0, 0)
        case .early(.volatile, _):
            return (EarlySimulation.volatileTranscripts(input.sliding), 0, 0, 0)
        case .early(.prefix, _):
            let passes = EarlySimulation.passes(input.prefixes, first: config.first, stretch: config.stretch, tick: config.tick)
            let ran = passes.filter { $0.start < input.seconds }
            return (passes, EarlySimulation.blocked(passes, release: input.seconds), ran.count,
                    ran.reduce(0) { $0 + ($1.ready - $1.start) * 1_000 })
        }
    }

    static func runArm(
        _ spec: ArmSpec, inputs: [Input], session: SecondPassRunner.Session, config: Config, described: String
    ) async -> EarlyRecords.Arm {
        let abandoned = AbandonedCalls()
        let started = Date()
        let loadAtStart = SecondPassRunner.loadAverages()
        let second = MurmurCore.RecordingLanguageModel(session.apple, label: "second", log: session.callLog)
        var rows: [EarlyRecords.Row] = []
        for input in inputs {
            let cleaner = SmartCleaner(
                model: session.chain.model, retainsRejectedCandidates: true,
                // As the app does (CleanupModelController): an intent model cleans the whole transcript in one call.
                wholeTranscript: { session.entry.promptProfile == .intent },
                abandoned: abandoned, secondOpinion: second)
            let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
            let settings = session.base
            let load = SecondPassRunner.loadAverages()[0]
            let clockStart = Date().timeIntervalSince1970
            session.callLog.clear()
            let (raw, blockSeconds, passes, passMs) = heard(spec.kind, input: input, config: config)
            var outcome = EarlySimulation.Outcome()
            switch spec.kind {
            case .ref:
                break
            case .legacy:
                outcome = await EarlySimulation.runLegacy(raw, release: input.seconds) { group, previous in
                    await time {
                        await cleaner.prewarmGroup(
                            group.text, options: settings.cleanupOptions, continuesSentence: group.continuesSentence, previousRaw: previous)
                    }
                }
            case .early(_, let sightings):
                await pipeline.openEarlyCleaning()
                let fixed = raw.map {
                    EarlySimulation.Transcript(start: $0.start, ready: $0.ready, text: pipeline.earlyTranscript($0.text, settings: settings))
                }
                outcome = await EarlySimulation.run(fixed, release: input.seconds, sightings: sightings) { group in
                    await time { _ = await pipeline.cleanEarly(group: group, settings: settings) }
                }
            }
            let earlyCalls = counts(session.callLog)
            session.callLog.clear()
            let releaseStart = ContinuousClock.now
            let result = await pipeline.clean(input.final, confidences: input.confidences, settings: settings, released: releaseStart)
            let cleanMs = ModelPace.ms(ContinuousClock.now - releaseStart)
            let sources = result.groupSources.map(\.rawValue)
            let used = result.early?.used ?? result.groupSources.filter { $0 == .prewarmHit || $0 == .prewarmAwaited }.count
            rows.append(EarlyRecords.Row(
                set: input.set, id: input.id, finalWords: TextStats.wordCount(input.final), spokenWords: input.spokenWords,
                seconds: input.seconds, plannedGroups: result.groups.count, output: result.text,
                waitMs: max(blockSeconds * 1_000 + input.finalMs, outcome.inFlight * 1_000) + cleanMs,
                asrMs: input.finalMs, blockMs: blockSeconds * 1_000, inFlightMs: outcome.inFlight * 1_000, cleanMs: cleanMs,
                sources: sources, earlyStarted: outcome.started.count, earlyUsed: used, withdrawn: outcome.withdrawn,
                transcripts: outcome.transcripts, passes: passes, passMs: passMs, earlyCalls: outcome.calls,
                modelCallsEarly: earlyCalls, modelCallsRelease: counts(session.callLog),
                groups: result.groups.enumerated().map { SecondPassRecords.group($1, index: $0) }, load: load,
                clockStart: clockStart, clockEnd: Date().timeIntervalSince1970))
            if session.printsText { print("  [\(spec.name)] \(input.set)/\(input.id): \(result.text.replacingOccurrences(of: "\n", with: "⏎"))") }
        }
        return EarlyRecords.Arm(
            label: session.label, arm: spec.name, input: described, setting: session.setting.rawValue,
            firstModel: "\(session.chain.model.identifier) (\(session.entry.id))", secondModel: session.apple.identifier,
            started: ISO8601DateFormatter().string(from: started), seconds: Date().timeIntervalSince(started),
            loadAtStart: loadAtStart, loadAtEnd: SecondPassRunner.loadAverages(), thermalAtEnd: SecondPassRunner.thermal(),
            dictations: rows)
    }

    static func counts(_ log: ModelCallLog) -> [String: Int] {
        var out: [String: Int] = [:]
        for call in log.recent { out[call.backend, default: 0] += 1 }
        return out
    }

    static func summary(_ arm: EarlyRecords.Arm, file: String, reference: [String: EarlyRecords.Row]) -> String {
        let waits = arm.dictations.map { $0.waitMs / 1_000 }
        func p(_ q: Double) -> String { String(format: "%.2f", LiveShapeCases.percentile(waits, q)) }
        let started = arm.dictations.reduce(0) { $0 + $1.earlyStarted }
        let used = arm.dictations.reduce(0) { $0 + $1.earlyUsed }
        var line = "- \(arm.arm) → \(file): \(arm.dictations.count) dictations; wait median \(p(0.5)) s, 90th \(p(0.9)) s, "
            + "worst \(String(format: "%.2f", waits.max() ?? 0)) s; groups cleaned early \(started), used \(used), thrown away \(started - used); "
            + "arm took \(Int(arm.seconds)) s; load \(String(format: "%.1f", arm.loadAtStart[0])) → \(String(format: "%.1f", arm.loadAtEnd[0])); thermal \(arm.thermalAtEnd)"
        if !reference.isEmpty {
            let pairs = arm.dictations.compactMap { row in reference["\(row.set)/\(row.id)"].map { (row, $0) } }
            let sameText = pairs.filter { $0.0.output == $0.1.output }.count
            let sameSecond = pairs.filter { $0.0.groups.map(\.fate) == $0.1.groups.map(\.fate) }.count
            line += "; text identical to ref in \(sameText) of \(pairs.count); second-pass fates identical in \(sameSecond) of \(pairs.count)"
        }
        return line
    }

    // MARK: Dry counting

    struct DryRow {
        let input: Input
        let closedInFinal: Int
        let started: Int
        let used: Int
        let withdrawn: Int
        let passes: Int
        let passMs: Double
    }

    static func dryRows(_ spec: ArmSpec, inputs: [Input], settings: PipelineSettings, config: Config) async -> [DryRow] {
        guard case .early(_, let sightings) = spec.kind else { return [] }
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: SmartCleaner(model: NullLanguageModel()))
        var rows: [DryRow] = []
        for input in inputs {
            let (raw, _, passes, passMs) = heard(spec.kind, input: input, config: config)
            let fixed = raw.map {
                EarlySimulation.Transcript(start: $0.start, ready: $0.ready, text: pipeline.earlyTranscript($0.text, settings: settings))
            }
            let outcome = await EarlySimulation.run(fixed, release: input.seconds, sightings: sightings) { _ in Config.dryGroupSeconds }
            let plan = TextSegmentation.groups(pipeline.earlyTranscript(input.final, settings: settings))
            let planned = plan.count > 1 ? plan.map(\.text) : []
            let startedTexts = Set(outcome.started)
            rows.append(DryRow(
                input: input, closedInFinal: max(0, planned.count - 1), started: outcome.started.count,
                used: planned.filter(startedTexts.contains).count, withdrawn: outcome.withdrawn, passes: passes, passMs: passMs))
        }
        return rows
    }

    static func band(_ words: Int) -> String {
        switch words {
        case ..<20: "under 20"
        case ..<60: "20 to 59"
        case ...150: "60 to 150"
        default: "over 150"
        }
    }

    static func drySummary(_ spec: ArmSpec, rows: [DryRow]) -> String {
        var lines = ["", "#### \(spec.name)", "| words spoken | dictations | closed groups in the final text | cleaned early | used | thrown away | withdrawn before starting | passes | pass time, s |", "|---|---|---|---|---|---|---|---|---|"]
        for name in ["under 20", "20 to 59", "60 to 150", "over 150", "all"] {
            let some = rows.filter { name == "all" || band($0.input.spokenWords) == name }
            guard !some.isEmpty else { continue }
            func sum(_ value: (DryRow) -> Int) -> Int { some.reduce(0) { $0 + value($1) } }
            let closed = sum(\.closedInFinal), started = sum(\.started), used = sum(\.used)
            let share = closed > 0 ? String(format: " (%.0f%%)", 100 * Double(used) / Double(closed)) : ""
            lines.append("| \(name) | \(some.count) | \(closed) | \(started) | \(used)\(share) | \(started - used) | \(sum(\.withdrawn)) | \(sum(\.passes)) | \(String(format: "%.1f", some.reduce(0) { $0 + $1.passMs } / 1_000)) |")
        }
        return lines.joined(separator: "\n")
    }
}
