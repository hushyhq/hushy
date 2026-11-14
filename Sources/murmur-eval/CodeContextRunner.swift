import Foundation
import MurmurCore

/// `murmur-eval code-context [--cases Evals/code-context-dev.jsonl] [--level default|clean|polished] [--bundle <id>] [--text] [--report path.json]`
///
/// Task 143. Prose dictated into a code editor or terminal, and dictated code that must not be touched, through
/// the settings the app builds for a code app (`PipelineSettings.forDictation`). `--level default` (the default)
/// uses what the app does; `clean` and `polished` force a level so the two can be compared from one build.
/// A cases file has one JSON object per line: `id`, `group` (`prose` or `protect`), `field`, `spoken`, `expected`,
/// `must_keep`, and for prose `gone` (phrases that must be absent), `want` (phrases that must be present) and
/// `min_sentences`. A group `mixed` is a command or a line of prose that names code, scored on an exact match to `expected`. A third group, `chat`, is a short ordinary message with no code in it; it is scored on whether the
/// text keeps its capital and its final stop (`expected` is the message as it should read). Scoring reads no meaning:
/// - prose: a fault is fixed when each `gone` phrase is absent and each `want` phrase is present (whole words,
///   ignoring case); `must_keep` is matched ignoring case and punctuation; `min_sentences` counts `. ? !` ends.
/// - protect: `must_keep` is matched exactly, with case (a command's first word turned into a capital counts).
/// Invented text only.
enum CodeContextRunner {
    struct Item: Decodable {
        let id: String
        let group: String
        let field: String
        let spoken: String
        let expected: String
        let mustKeep: [String]
        let gone: [String]
        let want: [String]
        let minSentences: Int
        enum CodingKeys: String, CodingKey {
            case id, group, field, spoken, expected, gone, want
            case mustKeep = "must_keep", minSentences = "min_sentences"
        }
    }

    struct Outcome {
        let item: Item
        let output: String
        let usedModel: Bool
        let rejection: String?
        var seconds: Double = 0
        /// Whether the rules draft's lines read as commands (the model gets none of them) or as prose (see `CodeContextGuard`).
        var readAsCommand = false
        let faultsIn: Int
        let faultsFixed: Int
        let missing: [String]
        let sentencesShort: Bool
        var isDamaged: Bool { item.group == "protect" && !missing.isEmpty }
        var lostCapital: Bool { output.first(where: \.isLetter).map(\.isLowercase) ?? false }
        var lostStop: Bool { !(output.last.map { ".?!".contains($0) } ?? false) }
        var isProseClean: Bool { item.group == "prose" && faultsFixed == faultsIn && missing.isEmpty && !sentencesShort }
        var exact: Bool { output == item.expected }
    }

    static func load(_ path: String) throws -> [Item] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = JSONDecoder()
        let items = try text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(Item.self, from: Data($0.utf8)) }
        guard !items.isEmpty, Set(items.map(\.id)).count == items.count else {
            throw EvalError.missing("code-context cases must be nonempty with unique IDs")
        }
        return items
    }

    private static func normalised(_ text: String) -> String {
        let kept = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return " " + kept.split(separator: " ").joined(separator: " ") + " "
    }

    private static func hasPhrase(_ text: String, _ phrase: String) -> Bool {
        let key = normalised(phrase)
        return key.count > 2 && normalised(text).contains(key)
    }

    private static func sentenceEnds(_ text: String) -> Int {
        text.ranges(of: /[.?!](?=\s|$)/).count
    }

    static func score(_ item: Item, output: String, usedModel: Bool, rejection: String?) -> Outcome {
        var fixed = 0
        for phrase in item.gone where !hasPhrase(output, phrase) { fixed += 1 }
        for phrase in item.want where hasPhrase(output, phrase) { fixed += 1 }
        let missing: [String]
        if item.group == "protect" {
            missing = item.mustKeep.filter { !output.contains($0) }
        } else {
            let flat = normalised(output)
            missing = item.mustKeep.filter { !output.lowercased().contains($0.lowercased()) && !flat.contains(normalised($0)) }
        }
        return Outcome(
            item: item, output: output, usedModel: usedModel, rejection: rejection,
            faultsIn: item.gone.count + item.want.count, faultsFixed: fixed, missing: missing,
            sentencesShort: item.minSentences > 1 && sentenceEnds(output) < item.minSentences)
    }

    static func run(_ args: Arguments) async throws {
        let path = args.string("cases") ?? Paths.root.appendingPathComponent("code-context-dev.jsonl").path
        let items = try load(path)
        let bundle = args.string("bundle") ?? "com.apple.Terminal"
        var (settings, category) = LiveShapeRunner.settings(tone: .refined, bundleID: bundle)
        guard category == .code else {
            throw EvalError.missing("\(bundle) does not get the code handling (\(category.rawValue))")
        }
        let levelName = args.string("level") ?? "default"
        if levelName != "default" {
            guard let forced = CleanupLevel(rawValue: levelName) else { throw EvalError.missing("--level must be default|clean|polished") }
            settings.cleanupOptions.level = forced
        }
        let level = settings.cleanupOptions.level
        print("### Code context · \(items.count) cases · \(bundle) → \(category.rawValue) · level \(level.rawValue) (\(levelName)) · code context \(settings.cleanupOptions.isCodeContext)")

        var outcomes: [Outcome] = []
        for item in items {
            let cleaner = args.makeCleaner(retainsRejectedCandidates: true)
            let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
            let started = ContinuousClock.now
            let result = await pipeline.clean(item.spoken, settings: settings, strategy: nil)
            var outcome = score(item, output: result.text, usedModel: result.usedModel, rejection: result.rejection)
            outcome.seconds = ModelPace.ms(ContinuousClock.now - started) / 1000
            let draft = TextCleaner(options: settings.cleanupOptions).clean(item.spoken).text
            outcome.readAsCommand = settings.cleanupOptions.isCodeContext
                && draft.split(separator: "\n", omittingEmptySubsequences: true).allSatisfy { CodeContextGuard.readsAsCommand(String($0)) }
            outcomes.append(outcome)
            let status = item.group == "mixed"
                ? (outcome.exact ? "ok" : "DIFFERS")
                : item.group == "chat"
                ? (outcome.lostCapital || outcome.lostStop ? "LOST\(outcome.lostCapital ? " capital" : "")\(outcome.lostStop ? " stop" : "")" : "ok")
                : item.group == "prose"
                ? (outcome.isProseClean ? "ok" : "FAULT \(outcome.faultsFixed)/\(outcome.faultsIn) missing \(outcome.missing.count)\(outcome.sentencesShort ? " run-on" : "")")
                : (outcome.isDamaged ? "DAMAGED missing \(outcome.missing.joined(separator: " | "))" : "ok")
            print("- \(item.id) [\(item.group)] \(outcome.readAsCommand ? "command" : "prose") · model \(result.usedModel ? "used" : "no")\(result.rejection.map { " (\($0))" } ?? ""): \(status)")
            if args.flag("text") {
                print("    spoken: \(item.spoken)\n    got:    \(result.text)\n    want:   \(item.expected)")
                for group in result.groups { if let rejected = group.rejectedCandidate { print("    model answer that a check threw away: \(rejected)") } }
            }
        }
        report(outcomes, args: args)
    }

    private static func report(_ outcomes: [Outcome], args: Arguments) {
        let prose = outcomes.filter { $0.item.group == "prose" }
        let protect = outcomes.filter { $0.item.group == "protect" }
        let chat = outcomes.filter { $0.item.group == "chat" }
        let mixed = outcomes.filter { $0.item.group == "mixed" }
        let faultsIn = prose.reduce(0) { $0 + $1.faultsIn }
        let faultsFixed = prose.reduce(0) { $0 + $1.faultsFixed }
        let modelUsed = outcomes.filter(\.usedModel).count
        var reasons: [String: Int] = [:]
        for outcome in outcomes { if let reason = outcome.rejection { reasons[reason, default: 0] += 1 } }
        print("\n| set | cases | measure | result |\n|---|---|---|---|")
        print("| prose | \(prose.count) | faults fixed (fillers, restarts, grammar) | \(faultsFixed)/\(faultsIn) |")
        print("| prose | \(prose.count) | cases with every fault fixed, nothing lost, run-ons split | \(prose.filter(\.isProseClean).count)/\(prose.count) |")
        print("| prose | \(prose.count) | must_keep missing | \(prose.reduce(0) { $0 + $1.missing.count }) |")
        print("| prose | \(prose.count) | exact match to the expected text | \(prose.filter(\.exact).count)/\(prose.count) |")
        print("| protect | \(protect.count) | cases with an identifier, flag, path or number changed | \(protect.filter(\.isDamaged).count)/\(protect.count) |")
        print("| protect | \(protect.count) | exact match to the expected text | \(protect.filter(\.exact).count)/\(protect.count) |")
        if !chat.isEmpty {
            print("| chat | \(chat.count) | short messages that lost the capital or the final stop | \(chat.filter { $0.lostCapital || $0.lostStop }.count)/\(chat.count) |")
            print("| chat | \(chat.count) | lost the capital / lost the stop | \(chat.filter(\.lostCapital).count) / \(chat.filter(\.lostStop).count) |")
            print("| chat | \(chat.count) | read as a command by the guard | \(chat.filter(\.readAsCommand).count)/\(chat.count) |")
        }
        if !mixed.isEmpty {
            print("| mixed | \(mixed.count) | commands and prose naming code: output exactly as expected | \(mixed.filter(\.exact).count)/\(mixed.count) |")
            print("| mixed | \(mixed.count) | not as expected | \(mixed.filter { !$0.exact }.map(\.item.id).joined(separator: " ")) |")
        }
        print("| all | \(outcomes.count) | model answer used | \(modelUsed)/\(outcomes.count) |")
        let commands = outcomes.filter(\.readAsCommand)
        print("| all | \(outcomes.count) | lines read as commands / as prose | \(commands.count) / \(outcomes.count - commands.count) |")
        print("| prose | \(prose.count) | prose read as a command (repair lost) | \(prose.filter(\.readAsCommand).map(\.item.id).joined(separator: " ")) |")
        print("| protect | \(protect.count) | dictated code read as prose (protection by shape only) | \(protect.filter { !$0.readAsCommand }.map(\.item.id).joined(separator: " ")) |")
        let waits = outcomes.map(\.seconds).sorted()
        if let middle = waits[safe: waits.count / 2], let worst = waits.last {
            print("| all | \(outcomes.count) | seconds per dictation (median, worst; a quality run, no release deadline) | \(String(format: "%.1f", middle)), \(String(format: "%.1f", worst)) |")
        }
        if !reasons.isEmpty {
            print("\nModel answers not used: " + reasons.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }.joined(separator: ", "))
        }
        let damaged = protect.filter(\.isDamaged)
        if !damaged.isEmpty {
            print("\nDamaged (protect):")
            for outcome in damaged {
                print("  ✘ \(outcome.item.id)\n      spoken: \(outcome.item.spoken)\n      got:    \(outcome.output)\n      want:   \(outcome.item.expected)\n      missing: \(outcome.missing.joined(separator: " | "))")
            }
        }
        guard let path = args.string("report") else { return }
        let cases: [[String: Any]] = outcomes.map {
            ["id": $0.item.id, "group": $0.item.group, "spoken": $0.item.spoken, "expected": $0.item.expected,
             "actual": $0.output, "usedModel": $0.usedModel, "rejection": $0.rejection ?? "",
             "faultsIn": $0.faultsIn, "faultsFixed": $0.faultsFixed, "missing": $0.missing,
             "damaged": $0.isDamaged, "seconds": $0.seconds, "readAsCommand": $0.readAsCommand, "proseClean": $0.isProseClean, "exact": $0.exact]
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["cases": cases], options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
