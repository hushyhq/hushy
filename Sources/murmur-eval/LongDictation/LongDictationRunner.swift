import Foundation
import MurmurCore

/// `murmur-eval long-dictation --cases Evals/long-dictation-dev.jsonl [--path release|prewarmed] [--tone refined] [--double]
///  [--second-opinion] [--neighbour-context] [--whole-dictation-words N] [--paragraph-breaks] [--group-contract] [--report path.json] [--text]`
///
/// Task 142. Runs each whole long dictation through the path the app uses (`LiveShapeRunner.settings`, then
/// `LiveShapeCases.clean`) and scores the whole output with `LongDictationScorer`: faults by kind per 100 spoken words, the
/// dictations with no fault at all, meaning faults on their own line, and the wait after the key release.
/// A per-dictation line prints ids and numbers only; `--text` also prints the output (invented text only).
/// `--double` joins neighbouring dictations in pairs, to see how a longer text behaves.
enum LongDictationRunner {
    struct Row: Codable {
        let id: String
        let spokenWords: Int
        let faults: LongDictationScorer.Faults
        let wordErrors: Int
        let referenceWords: Int
        let waitSeconds: Double
        let groupOutcomes: [String: Int]
        let secondPassRan: Int
        let secondPassUsed: Int
        let output: String
        var details: [String] = []
    }

    static func pairedUp(_ cases: [LongDictationCase]) -> [LongDictationCase] {
        stride(from: 0, to: cases.count - 1, by: 2).map { cases[$0].followed(by: cases[$0 + 1]) }
    }

    static func run(_ args: Arguments) async throws {
        guard let path = args.string("cases") else {
            throw NSError(domain: "long-dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "long-dictation needs --cases <file.jsonl>"])
        }
        var cases = try LongDictationCase.load(path)
        let problems = cases.flatMap { $0.problems() }
        if !problems.isEmpty, !args.flag("skip-key-check") {
            problems.forEach { print("key problem: \($0)") }
            throw NSError(domain: "long-dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(problems.count) problem(s) in the answer key"])
        }
        if args.flag("double") { cases = pairedUp(cases) }
        if let limit = args.int("limit") { cases = Array(cases.prefix(limit)) }
        let tone = DictationTone(rawValue: args.string("tone") ?? "refined") ?? .refined
        let (base, _) = LiveShapeRunner.settings(tone: tone, bundleID: args.string("bundle") ?? "com.anthropic.claudefordesktop")
        let path0 = args.string("path") ?? "release"
        guard ["release", "prewarmed"].contains(path0) else {
            throw NSError(domain: "long-dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "--path must be release or prewarmed"])
        }
        let label = "\(path0)\(args.flag("second-opinion") ? " + second pass" : "")\(args.flag("neighbour-context") ? " + neighbour context" : "")"
            + "\(args.int("whole-dictation-words").map { " + one call up to \($0) words" } ?? "")\(args.flag("paragraph-breaks") ? " + paragraphs" : "")\(args.flag("group-contract") ? " + group contract" : "")"
        print("### Long dictations · \(cases.count) · \(label) · tone \(tone.rawValue) · level \(base.cleanupOptions.level.rawValue) · prompt \(args.string("mlx-prompt") ?? "-")")

        // One untimed dictation first, so the model load is not counted in anyone's wait.
        if let first = cases.first {
            _ = await LiveShapeCases.clean(
                first.spoken, base: base, tone: tone, prewarm: false, primary: args.makeCleaner(), second: nil)
        }

        print("| id | words | filler | restart | false start | correction | run-on | bad join | no paragraph | layout | missing | neg + | neg − | number | meaning | wait |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        var rows: [Row] = []
        for item in cases {
            let primary = args.makeCleaner(retainsRejectedCandidates: args.flag("show-rejected"))
            let (text, traces, wait) = await LiveShapeCases.clean(
                item.spoken, base: base, tone: tone, prewarm: path0 == "prewarmed", primary: primary, second: nil)
            let groups = TextSegmentation.groups(item.spoken)
            let result = LongDictationScorer.score(
                item, output: text, groupTexts: groups.map(\.text), groupContinues: groups.map(\.continuesSentence))
            let f = result.faults
            var outcomes: [String: Int] = [:]
            for trace in traces { outcomes["\(trace.outcome.rawValue)\(trace.guardCode.map { "/\($0.rawValue)" } ?? "")", default: 0] += 1 }
            let ranSecond = traces.filter { $0.secondPass != .none }
            let row = Row(
                id: item.id, spokenWords: item.spokenWordCount, faults: f, wordErrors: result.wordErrors,
                referenceWords: result.referenceWords, waitSeconds: wait, groupOutcomes: outcomes,
                secondPassRan: ranSecond.count, secondPassUsed: ranSecond.filter { $0.secondPass == .used }.count, output: text, details: result.details)
            rows.append(row)
            print("| \(item.id) | \(item.spokenWordCount) | \(f.filler) | \(f.restart) | \(f.falseStart) | \(f.correction) | \(f.runOn) | \(f.badJoin) | \(f.missingParagraph) | \(f.layout) | \(f.missingItems) | \(f.negationAdded) | \(f.negationRemoved) | \(f.numberChanged) | \(f.meaning) | \(String(format: "%.1f", wait)) s |")
            if args.flag("details") { print("    key hits: \(result.details.joined(separator: " · "))") }
            if args.flag("text") { print("    \(text.replacingOccurrences(of: "\n", with: "⏎"))") }
            if args.flag("show-rejected") {
                for t in traces { if let candidate = t.rejectedCandidate { print("    rejected(\(t.label), asked again: \(t.askedAgain.rawValue)): \(candidate)") } }
            }
        }
        print(summary(rows, label: label))
        if let report = args.string("report") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: report))
        }
    }

    static func summary(_ rows: [Row], label: String) -> String {
        let total = rows.reduce(LongDictationScorer.Faults()) { $0 + $1.faults }
        let words = Double(rows.reduce(0) { $0 + $1.spokenWords })
        func per100(_ n: Int) -> String { String(format: "%.2f", words == 0 ? 0 : Double(n) / words * 100) }
        let waits = rows.map(\.waitSeconds)
        let wordErrors = rows.reduce(0) { $0 + $1.wordErrors }
        let referenceWords = rows.reduce(0) { $0 + $1.referenceWords }
        var outcomes: [String: Int] = [:]
        for row in rows { for (k, v) in row.groupOutcomes { outcomes[k, default: 0] += v } }
        return """

        **\(label)** over \(rows.count) dictations, \(Int(words)) spoken words
        | kind | count | per 100 words |
        |---|---|---|
        | leftover filler or hedge | \(total.filler) | \(per100(total.filler)) |
        | unrepaired restart | \(total.restart) | \(per100(total.restart)) |
        | unrepaired false start | \(total.falseStart) | \(per100(total.falseStart)) |
        | unrepaired correction | \(total.correction) | \(per100(total.correction)) |
        | run-on sentence | \(total.runOn) | \(per100(total.runOn)) |
        | bad join at a group seam | \(total.badJoin) | \(per100(total.badJoin)) |
        | missing paragraph break | \(total.missingParagraph) | \(per100(total.missingParagraph)) |
        | **layout faults** | \(total.layout) | \(per100(total.layout)) |
        | must-keep item missing | \(total.missingItems) | \(per100(total.missingItems)) |
        | negation added | \(total.negationAdded) | \(per100(total.negationAdded)) |
        | negation removed | \(total.negationRemoved) | \(per100(total.negationRemoved)) |
        | number changed | \(total.numberChanged) | \(per100(total.numberChanged)) |
        | **meaning faults** | \(total.meaning) | \(per100(total.meaning)) |

        dictations with no fault at all: \(rows.filter { $0.faults.isClean }.count) of \(rows.count); with no fault except the missing paragraph break: \(rows.filter { $0.faults.isCleanBesidesParagraphs }.count); with no layout fault: \(rows.filter { $0.faults.layout == 0 }.count); with no meaning fault: \(rows.filter { $0.faults.meaning == 0 }.count)
        wait after release: median \(String(format: "%.1f", LiveShapeCases.percentile(waits, 0.5))) s, worst \(String(format: "%.1f", waits.max() ?? 0)) s, mean \(String(format: "%.1f", waits.isEmpty ? 0 : waits.reduce(0, +) / Double(waits.count))) s, total \(String(format: "%.1f", waits.reduce(0, +))) s
        words differing from the reference: \(wordErrors) of \(referenceWords) (\(String(format: "%.1f", referenceWords == 0 ? 0 : Double(wordErrors) / Double(referenceWords) * 100)) percent)
        not placed by the scorer: \(total.breaksUnlocated) of \(total.breaksTotal) required sentence ends; \(total.seamsUnlocated) of \(total.seamsTotal) group seams; sentence ends missing where the key requires one: \(total.breaksMissing); extra paragraph breaks: \(total.extraParagraphs); longest sentence: \(total.longestSentenceWords) words
        second pass ran on \(rows.reduce(0) { $0 + $1.secondPassRan }) groups, changed \(rows.reduce(0) { $0 + $1.secondPassUsed })
        groups: \(outcomes.sorted { $0.key < $1.key }.map { "\($0.value)×\($0.key)" }.joined(separator: ", "))
        """
    }
}
