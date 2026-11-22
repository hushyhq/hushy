import Foundation
import HushyModelsApple
import MurmurCore

/// Long-meeting digest eval: 12 synthetic meetings, 20–70 minutes, with gold decisions and
/// action items spread across the whole meeting (see `MeetingScoring`, `Evals/meeting-eval/`).
///
///   (with --backend local the summaries take the app's route: the loaded 4B, or Apple FM for another entry)
///   murmur-eval meeting [--golden Evals/meeting-eval/golden.json] [--digest legacy|auto|map-reduce|single-pass]
///       [--chunk-words N] [--plain | --app-path [--rename]] [--only m01,m09] [--out outputs.json] [--label text] [--trace]
///       [--extractor [--answers DIR]]   (the facts path; `--answers` keeps the 4B's answers to replay, see `AnswerCache`)
///       [--probe-dictation [--probe-no-yield] [--probe-seconds N] [--probe-speak-seconds N]]   (see `MeetingDictationProbe`)
///
/// `--digest legacy` is the summarizer before map-reduce (`LegacyNoteSummarizer`); the others are
/// `NoteSummarizer` strategies. `--plain` strips speaker labels (the first summary, written before
/// diarization); `--app-path` is the re-summary after diarization (labels as diarization stores
/// them, rendered by `DiarizedDigest`); `--rename` then names every speaker the way the user would
/// (`DigestSpeakerRename`, no model call). `--out` writes every digest for inspection. Eval-only data: never
/// train or tune prompts on it.
enum MeetingRunner {
    struct Row: Codable {
        let id: String
        let minutes: Int
        let words: Int
        let milliseconds: Double
        let calls: Int
        let note: String
        let title: String
        let summary: String
        let actionItems: [String]
        let actionDetails: [ActionItemDetail]?
        let score: MeetingScore
        /// `--extractor`: what the facts path kept and dropped (counts only).
        var facts: FactCounts? = nil
        /// `--extractor`: every stored fact, hidden ones too, so a grounding rule can be tried on the output offline.
        var records: [FactRecord]? = nil
    }

    struct FactRecord: Codable {
        var kind: String
        var text: String
        var quote: String?
        var grounding: String
        var ownerText: String?
        var ownerClaim: String?
        var due: String?
    }

    /// The facts path's own counts for one meeting (`MeetingFactExtractor`).
    struct FactCounts: Codable {
        var chunks: Int
        var failedChunks: Int
        var records: Int
        var verified: Int
        var unsupported: Int
        /// Visible actions with an owner, and those whose owner is neither a speaker label nor a word said in the
        /// meeting (`MeetingScoring.isHallucinated`): the invented-owner count.
        var ownedActions: Int
        var inventedOwners: Int
        /// Owners the model gave that grounding left blank (stored as claims, never shown).
        var ownersDropped: Int
        var visibleWithQuoteAndMoment: Int
        var visible: Int
    }

    static func run(_ args: Arguments) async throws {
        let heldout = args.string("heldout")
        if let heldout {
            // The sealed set: only the pinned file, whole, aggregates only (no per-meeting lines,
            // no --out, no --trace, no --only), so nothing about its content leaves the run.
            try SealedEvalGuard.assertIsSealedMeetingHeldout(URL(fileURLWithPath: heldout))
            guard args.string("out") == nil, args.string("only") == nil, !args.flag("trace"), !args.flag("names") else {
                throw EvalError.missing("meeting --heldout prints aggregates only: drop --out/--only/--trace/--names")
            }
        }
        let path = heldout ?? args.string("golden") ?? "Evals/meeting-eval/golden.json"
        let golden = try JSONDecoder().decode(MeetingGolden.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let only = Set((args.string("only") ?? "").split(separator: ",").map(String.init))
        let meetings = golden.meetings.filter { only.isEmpty || only.contains($0.id) }
        let digest = args.string("digest") ?? "auto"
        var configuration = NoteSummarizer.Configuration()
        if digest != "legacy" {
            guard let strategy = NoteSummarizer.Strategy(rawValue: digest) else {
                throw EvalError.missing("--digest must be legacy|auto|map-reduce|single-pass")
            }
            configuration.strategy = strategy
        }
        if let words = args.int("chunk-words") { configuration.chunkWords = words }
        if args.flag("trace") { configuration.trace = { print("----- merge input -----\n\($0)\n-----------------------") } }
        let activity = ForegroundActivity()
        let model = try appRoute(args, LanguageModels.current, activity: activity)
        await warmUp(model)
        if args.flag("probe-dictation"), args.string("backend") != "local" {
            throw EvalError.missing("meeting --probe-dictation needs --backend local (the instance summaries share with cleanup)")
        }
        let probeEvery = Duration.milliseconds(Int((args.string("probe-seconds").flatMap(Double.init) ?? 7) * 1_000))
        var probeWaits: [MeetingDictationProbe.Wait] = []

        var rows: [Row] = []
        if args.flag("names") {
            for meeting in meetings {
                let truth = meeting.people.filter { $0.label != $0.name && $0.label != "You" }.map { "\($0.label)=\($0.name)" }
                let text = input(args) == .appPath ? meeting.appPathTranscript : meeting.transcript
                print("  \(meeting.id) inferred \(SpeakerNameInference.names(in: text).sorted { $0.key < $1.key }) truth \(truth)")
            }
            return
        }
        let summaryConfiguration = configuration, inputKind = input(args), renameSpeakers = args.flag("rename")
        for meeting in meetings {
            let row: Row
            if args.flag("extractor") {
                row = await extract(meeting, input: inputKind, model: model)
            } else if args.flag("probe-dictation") {
                let (measured, waits) = await MeetingDictationProbe.during(
                    shared: LanguageModels.current, activity: activity, interval: probeEvery, markBusy: !args.flag("probe-no-yield"),
                    speak: .milliseconds(Int((args.string("probe-speak-seconds").flatMap(Double.init) ?? 3) * 1_000))
                ) {
                    await summarize(
                        meeting, digest: digest, configuration: summaryConfiguration, input: inputKind, rename: renameSpeakers, model: model)
                }
                row = measured
                probeWaits += waits
            } else {
                row = await summarize(
                    meeting, digest: digest, configuration: configuration, input: input(args), rename: args.flag("rename"), model: model)
            }
            if heldout == nil {
                print("  \(meeting.id) \(meeting.minutes) min: \(Int(row.milliseconds)) ms, \(row.calls) calls, \(row.note) — missed: \(row.score.missed.joined(separator: ", "))")
            }
            rows.append(row)
        }
        if args.flag("probe-dictation") {
            print(MeetingDictationProbe.summary(probeWaits, label: args.flag("probe-no-yield") ? "no yield" : "yielding"))
        }
        if let out = args.string("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: out))
        }
        var label = args.string("label") ?? "\(model.identifier) · \(args.flag("extractor") ? "facts" : digest) · \(input(args).rawValue)\(args.flag("rename") ? " · renamed" : "")"
        if args.flag("extractor") { Runners.emit(factsSummary(rows)) }
        if heldout != nil { label += " · SEALED HELD-OUT (aggregates only)" }
        Runners.emit(MeetingReport.markdown(rows, label: label, memory: MeetingReport.memory(), perMeeting: heldout == nil))
    }

    /// With `--backend local` summaries go the way the app sends them: the cleanup model's own instance when it is the
    /// 4B (`MeetingLanguageModel`, Apple FM rerun when the digest ends extractive), Apple FM for any other entry.
    /// Every other backend is the model as given, as before.
    static func appRoute(_ args: Arguments, _ current: any LanguageModel, activity: ForegroundActivity) throws -> any LanguageModel {
        guard args.string("backend") == "local" else { return current }
        let entry = try args.localModelEntry()
        let shared = try args.string("answers").map { try AnswerCache(base: current, folder: URL(fileURLWithPath: $0, isDirectory: true)) } ?? current
        let route = MeetingLanguageModel(shared: shared, apple: AppleFoundationModel(), activity: activity)
        route.route(for: .local(entry.id))
        return route
    }

    /// Loads the model off the clock (the app's model is resident when a meeting ends).
    static func warmUp(_ model: any LanguageModel) async {
        _ = try? await model.respond(
            instructions: "Reply briefly.", prompt: "Say hello.", generating: WarmUp.self, options: .greedy)
    }

    struct WarmUp: StructuredOutput {
        var text: String
        static let generationSchema = GenerationSchemaSpec(name: "WarmUp", json: #"""
            {"additionalProperties":false,"properties":{"text":{"type":"string"}},"required":["text"],"title":"WarmUp","type":"object","x-order":["text"]}
            """#)
    }

    enum Input: String {
        /// The golden labels: display names, as if every speaker had been renamed.
        case labelled
        /// No labels: what the app summarized before 2026-09-28's re-summary.
        case plain
        /// What the app now summarizes after diarization (`MeetingGolden.Meeting.appPathTranscript`).
        case appPath = "app-path"
    }

    static func input(_ args: Arguments) -> Input {
        args.flag("plain") ? .plain : args.flag("app-path") ? .appPath : .labelled
    }

    static func summarize(
        _ meeting: MeetingGolden.Meeting, digest: String, configuration: NoteSummarizer.Configuration, input: Input,
        rename: Bool = false, model: any LanguageModel
    ) async -> Row {
        let transcript = switch input {
        case .labelled: meeting.transcript
        case .plain: meeting.plainTranscript
        case .appPath: meeting.appPathTranscript
        }
        let start = ContinuousClock.now
        var output: ExtractiveSummarizer.Output
        let calls: Int
        let note: String
        if digest == "legacy" {
            let (legacy, legacyCalls, failed) = await LegacyNoteSummarizer.summarize(transcript, fallbackTitle: meeting.title, model: model)
            (output, calls, note) = (legacy, legacyCalls, failed ? "failed→extractive" : "ok")
        } else {
            let (result, report) = await NoteSummarizer.summarize(transcript, fallbackTitle: meeting.title, model: model, configuration: configuration)
            (output, calls, note) = (result, report.calls, describe(report))
        }
        let elapsed = ContinuousClock.now - start
        if rename { output = renamed(output, meeting) }
        let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        let score = MeetingScoring.score(meeting: meeting, summary: output.summary, actionItems: output.actionItems, transcript: transcript)
        return Row(
            id: meeting.id, minutes: meeting.minutes, words: meeting.words, milliseconds: milliseconds, calls: calls, note: note,
            title: output.title, summary: output.summary, actionItems: output.actionItems,
            actionDetails: output.actionDetails, score: score)
    }

    /// `--extractor`: the app's facts path (`MeetingFactExtractor` and its grounder, on the model given) over the
    /// meeting's turns. The row has the `--out` shape `score_public.py` reads: decisions as "- Decided:" summary lines,
    /// actions as "Owner: task — due" items with their fields. Only visible facts (verified quotes) are written.
    static func extract(_ meeting: MeetingGolden.Meeting, input: Input, model: any LanguageModel) async -> Row {
        let text = switch input {
        case .labelled: meeting.transcript
        case .plain: meeting.plainTranscript
        case .appPath: meeting.appPathTranscript
        }
        let transcript = Self.transcript(text)
        let start = ContinuousClock.now
        let (facts, report) = await MeetingFactExtractor(model: model).extract(transcript, noteId: 1, title: meeting.title, kind: "meeting")
        let elapsed = ContinuousClock.now - start
        let visible = facts.filter(\.isVisible)
        let decisions = visible.filter { $0.kind == .decision }.map { "- Decided: \($0.text)" }
        let actions = visible.filter { $0.kind == .action }
        let details = actions.map(MeetingFactText.detail)
        let owned = actions.compactMap(\.ownerText)
        let invented = owned.filter { MeetingScoring.isHallucinated(owner: $0, transcript: text) }.count
        let score = MeetingScoring.score(meeting: meeting, summary: decisions.joined(separator: "\n"), actionItems: details.map(\.line), transcript: text)
        let counts = FactCounts(
            chunks: report.chunks, failedChunks: report.failedChunks, records: report.records, verified: report.verified,
            unsupported: report.unsupported, ownedActions: owned.count, inventedOwners: invented, ownersDropped: report.ownersDropped,
            visibleWithQuoteAndMoment: visible.filter { $0.quote != nil && $0.t0 != nil }.count, visible: visible.count)
        let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        return Row(
            id: meeting.id, minutes: meeting.minutes, words: meeting.words, milliseconds: milliseconds, calls: report.calls,
            note: "facts: \(report.chunks) chunks, \(report.verified) verified, \(report.unsupported) unsupported, \(report.failedChunks) failed",
            title: meeting.title, summary: decisions.joined(separator: "\n"), actionItems: details.map(\.line), actionDetails: details,
            score: score, facts: counts,
            records: facts.map {
                FactRecord(kind: $0.kind.rawValue, text: $0.text, quote: $0.quote, grounding: $0.grounding.rawValue,
                           ownerText: $0.ownerText, ownerClaim: $0.ownerClaim, due: $0.due)
            })
    }

    /// "Label: text" lines as stored turns: one speaker per label (ids by first appearance), times one second per line.
    static func transcript(_ text: String) -> NoteTranscript {
        var ids: [String: Int64] = [:]
        var names: [Int64: String] = [:]
        var turns: [NoteTurn] = []
        for (index, raw) in text.split(separator: "\n").enumerated() {
            let line = String(raw)
            var label: String?
            var body = line
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 40 {
                label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                body = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            var speakerId: Int64?
            if let label {
                let id = ids[label] ?? Int64(ids.count + 1)
                ids[label] = id
                names[id] = label
                speakerId = id
            }
            turns.append(NoteTurn(
                id: Int64(index + 1), noteId: 1, ordinal: index, stream: .unknown, speakerId: speakerId,
                t0: Double(index), t1: Double(index) + 1, text: body, origin: .capture))
        }
        return NoteTranscript(turns: turns, names: names)
    }

    /// Totals for `--extractor`: unsupported and invented-owner rates, and how many shown items carry a quote and a moment.
    static func factsSummary(_ rows: [Row]) -> String {
        let counts = rows.compactMap(\.facts)
        let sum = { (key: KeyPath<FactCounts, Int>) in counts.map { $0[keyPath: key] }.reduce(0, +) }
        let records = sum(\.records), unsupported = sum(\.unsupported), owned = sum(\.ownedActions), invented = sum(\.inventedOwners)
        return """
            ### Meeting facts (extractor) · \(rows.count) meetings

            | records | verified (shown) | unsupported (hidden) | owned actions | invented owners | owners left blank | shown with quote + moment | failed chunks |
            |---|---|---|---|---|---|---|---|
            | \(records) | \(sum(\.verified)) | \(unsupported) (\(MeetingReport.pct(unsupported, records))) | \(owned) | \(invented) (\(MeetingReport.pct(invented, owned))) | \(sum(\.ownersDropped)) | \(sum(\.visibleWithQuoteAndMoment))/\(sum(\.visible)) | \(sum(\.failedChunks))/\(sum(\.chunks)) |
            """
    }

    /// `--rename`: the user names every speaker after reading the digest — the app's rename
    /// path (`DigestSpeakerRename`, no model call), one speaker at a time.
    static func renamed(_ output: ExtractiveSummarizer.Output, _ meeting: MeetingGolden.Meeting) -> ExtractiveSummarizer.Output {
        var note = Note(title: output.title, summary: output.summary, actionItems: output.actionItems)
        for (label, name) in meeting.renames {
            note = DigestSpeakerRename.rewrite(note, from: [label], to: name) ?? note
        }
        return ExtractiveSummarizer.Output(title: note.title, summary: note.summary, actionItems: note.actionItems)
    }

    static func describe(_ report: NoteSummarizer.Report) -> String {
        var parts = [report.strategy.rawValue]
        if report.pieces > 0 { parts.append("\(report.pieces) pieces") }
        if report.retries > 0 { parts.append("\(report.retries) retries") }
        if report.extractivePieces > 0 { parts.append("\(report.extractivePieces) extractive pieces") }
        if report.deterministicMerge { parts.append("deterministic merge") }
        if report.singlePassFellBack { parts.append("single-pass fell back") }
        if report.extractiveOnly { parts.append("extractive only") }
        if !report.failures.isEmpty { parts.append("failed calls: \(report.failures.map { "\($0)" }.joined(separator: "/"))") }
        return parts.joined(separator: ", ")
    }
}
