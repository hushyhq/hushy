import Foundation
import MurmurCore

/// Jev as a second opinion on tones (`Evals/JUDGES.md`, tone rubric `tone-v1`). Two entry points,
/// both flagged on `murmur-eval tones` and off by default:
///
/// - `--jev-calibrate`: asks about the **expected** outputs in the dev set and about deliberately
///   mismatched pairs, and prints the confusion table for `tone_read` and the pass and false-alarm
///   rates for the fault questions. Needs only the case file and a key; no cleanup model.
/// - `--jev`: asks about the outputs of this run (one `tone_read` and the two fault questions per
///   tone and case) and lists every place the deterministic checks and Jev disagree.
///
/// Policy stays as in JUDGES.md: the deterministic checks gate, Jev is a triage aid. Skips cleanly
/// without a key. Only the invented dev-set text is ever sent; nothing here touches app data, and the
/// key is never printed.
enum ToneJevRunner {
    static let defaultCalls = 450

    private static func setup(_ args: Arguments) -> ToneJevJudge? {
        guard let apiKey = JudgeRunner.loadAPIKey() else {
            print("tones jev: skipped, no TypeSafe API key (TYPESAFE_API_KEY or ~/.config/hushy/typesafe_api_key)")
            return nil
        }
        return ToneJevJudge(apiKey: apiKey, budget: CallBudget(name: "Jev", limit: args.int("jev-calls") ?? defaultCalls))
    }

    private static func note(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

    // MARK: Calibration

    static func calibrate(set: ToneEvalChecks.CaseSet, args: Arguments) async throws {
        guard let judge = setup(args) else { return }
        var extraCases = set.cases
        if let also = args.string("jev-also") {
            try ToneJevSets.requireShipped(URL(fileURLWithPath: also))
            extraCases += try TonesRunner.loadCases(URL(fileURLWithPath: also)).cases
        }
        let samples = ToneJevCalibration.expectedSamples(set.cases)
            + ToneJevCalibration.ruleMadeSamples(extraCases, limit: args.int("jev-rule-samples") ?? 12)
        let reads = ToneJevCalibration.readItems(samples)
        let fits = ToneJevCalibration.fitItems(samples)
        // One tone_read per distinct (spoken, text); the answer is shared by every tone with that text.
        let uniqueReads = Dictionary(grouping: reads, by: { $0.spoken + "\u{1}" + $0.text }).values.compactMap(\.first)
        let readAnswers = try await JudgeClient.mapConcurrently(uniqueReads) { item in
            (item.spoken + "\u{1}" + item.text, try await judge.read(spoken: item.spoken, output: item.text))
        }
        let readByText = Dictionary(readAnswers, uniquingKeysWith: { first, _ in first })
        let readResults = reads.compactMap { item in
            readByText[item.spoken + "\u{1}" + item.text].map { (item: item, read: $0) }
        }
        let fitResults = try await JudgeClient.mapConcurrently(fits) { item in
            (item: item, fit: try await judge.fit(tone: item.requested, spoken: item.spoken, output: item.text))
        }
        let used = await judge.budget?.used ?? 0
        let requests = uniqueReads.count + fits.count
        print("### Tone judge calibration (Jev \(ToneJevRubric.model), rubric \(ToneJevRubric.version)) · \(set.name)")
        let made = samples.filter { $0.source == .ruleMade }.count
        print("- Samples: \(samples.count - made) from the case file's expected strings, \(made) made by the tone rules from the cases' cleaned text (their words differ between tones)")
        print("- Outputs: \(reads.count) (distinct texts asked about: \(uniqueReads.count)); fault pairs: \(fits.count)")
        print("- Requests: \(requests); real API calls this run: \(used) (the rest came from the cache)\n")
        for source in [ToneJevCalibration.Sample.Source.expected, .ruleMade] {
            let mine = readResults.filter { $0.item.source == source }
            let label = source == .expected ? "case file's expected strings" : "made by the tone rules"
            for (kind, title) in [(ToneJevCalibration.ReadItem.Kind.distinct, "words differ between tones"),
                                  (.shared, "same words in every tone, so no register to read (not an error either way)")] {
                let table = ToneJevCalibration.readTable(mine, kind: kind)
                guard table.total > 0 else { continue }
                print(ToneJevCalibration.formatReadTable(table, title: "tone_read · \(label) · \(title)"))
                print()
            }
        }
        for source in [ToneJevCalibration.Sample.Source.expected, .ruleMade] {
            print("#### Fault questions · \(source == .expected ? "case file's expected strings" : "made by the tone rules")")
            print(ToneJevCalibration.formatFitSummary(ToneJevCalibration.fitSummary(fitResults.filter { $0.item.source == source })))
        }
        for (item, fit) in fitResults where item.difference == .none && fit.flagged {
            print("  false alarm · \(item.caseID) · \(item.requested.rawValue) · ruleBroken \(String(format: "%.2f", fit.ruleBroken)) overreach \(String(format: "%.2f", fit.overreach))\n    \(item.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        for (item, fit) in fitResults where item.difference == .words && !fit.flagged {
            print("  missed · \(item.caseID) · text for \(item.from.rawValue) judged as \(item.requested.rawValue) · pBad \(String(format: "%.2f", fit.pBad))\n    \(item.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        if let report = args.string("jev-report") { try writeCalibration(readResults, fitResults, to: report) }
    }

    private static func writeCalibration(
        _ reads: [(item: ToneJevCalibration.ReadItem, read: ToneRead)],
        _ fits: [(item: ToneJevCalibration.FitItem, fit: ToneFit)], to path: String
    ) throws {
        let readRows: [[String: Any]] = reads.map {
            ["id": $0.item.caseID, "sample": $0.item.source.rawValue, "intended": $0.item.intended.rawValue, "kind": $0.item.kind.rawValue, "text": $0.item.text,
             "read": $0.read.choice, "probabilities": $0.read.probabilities]
        }
        let fitRows: [[String: Any]] = fits.map {
            ["id": $0.item.caseID, "requested": $0.item.requested.rawValue, "from": $0.item.from.rawValue, "text": $0.item.text,
             "difference": $0.item.difference.rawValue, "sample": $0.item.source.rawValue, "ruleBroken": $0.fit.ruleBroken, "overreach": $0.fit.overreach]
        }
        let body: [String: Any] = ["rubric": ToneJevRubric.version, "model": ToneJevRubric.model, "reads": readRows, "fits": fitRows]
        try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        print("\nJev tone calibration written to \(path)")
    }

    // MARK: A run's outputs

    struct Judged {
        let row: TonesRunner.Row
        let tone: DictationTone
        let read: ToneRead
        let fit: ToneFit
    }

    static func judge(rows: [TonesRunner.Row], args: Arguments) async throws {
        guard let judge = setup(args) else { return }
        let jobs = rows.flatMap { row in DictationTone.allCases.compactMap { tone in row.outputs[tone].map { (row, tone, $0) } } }
        let judged = try await JudgeClient.mapConcurrently(jobs) { job -> Judged in
            let (row, tone, output) = job
            async let read = judge.read(spoken: row.item.raw, output: output)
            async let fit = judge.fit(tone: tone, spoken: row.item.raw, output: output)
            return Judged(row: row, tone: tone, read: try await read, fit: try await fit)
        }
        let used = await judge.budget?.used ?? 0
        print("\n### Tone judge (Jev \(ToneJevRubric.model), rubric \(ToneJevRubric.version)): a second opinion, never a gate")
        print("- Outputs judged: \(judged.count); real API calls this run: \(used)")
        print("| Tone | Read as the requested tone | Read as unclear | Read as another tone | Fault flagged (pBad ≥ 0.5) |")
        print("|---|---:|---:|---:|---:|")
        for tone in DictationTone.allCases {
            let mine = judged.filter { $0.tone == tone }
            let own = mine.filter { $0.read.choice == tone.rawValue }.count
            let unclear = mine.filter { $0.read.choice == "unclear" }.count
            print("| \(tone.rawValue) | \(own)/\(mine.count) | \(unclear)/\(mine.count) | \(mine.count - own - unclear)/\(mine.count) | \(mine.filter(\.fit.flagged).count)/\(mine.count) |")
        }
        print("\n#### Where the checks and Jev disagree")
        var disagreements = 0
        for entry in judged {
            guard let score = entry.row.scores[entry.tone] else { continue }
            let checksOK = score.meetsExpectation && score.faithful
            guard checksOK == entry.fit.flagged else { continue }
            disagreements += 1
            print("  \(checksOK ? "checks✔ jev✘" : "checks✘ jev✔") \(entry.row.item.id) · \(entry.tone.rawValue) · ruleBroken \(String(format: "%.2f", entry.fit.ruleBroken)) overreach \(String(format: "%.2f", entry.fit.overreach)) · read as \(entry.read.choice)")
            print("    output: \(entry.row.outputs[entry.tone] ?? "")")
        }
        if disagreements == 0 { print("  none") }
    }
}
