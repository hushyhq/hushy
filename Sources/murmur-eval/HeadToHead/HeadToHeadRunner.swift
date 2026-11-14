import Foundation
import MurmurCore

/// `murmur-eval head-to-head` — the blind Hushy-vs-competitor harness for gate 12.
///
///   murmur-eval head-to-head template --out <dir> [--count 100] [--other-name "Wispr Flow"]
///   murmur-eval head-to-head record --out <dir with p-NNN.wav> [--count 100] [--overwrite]
///       (records the founder's own voice once; see docs/guide/HEAD-TO-HEAD-VIRTUAL-MIC.md)
///   murmur-eval head-to-head play --audio-dir <dir with p-NNN.wav> --device "BlackHole" --out <filled.md>
///       [--product "Wispr Flow"] [--cases p-001,p-002,…] [--silence-timeout 90]
///       (plays the same recorded WAVs to a virtual mic so both apps hear identical audio)
///   murmur-eval head-to-head build --hushy <filled.md> --other <filled.md> --out pairs.json
///       [--other-name "Wispr Flow"] [--audio-dir <dir with p-NNN.wav>]
///   murmur-eval head-to-head --pairs pairs.json [--seed 42] [--form review.html]
///       [--votes a.json,b.json,c.json] [--report report.json] [--no-judge] [--judge-calls 60]
///       [--judge-model gpt-6-luna]
///
/// Report-only: exit status is 0 whatever the numbers say (gate 12 is read from the report by
/// a human). The judge stage skips cleanly when `codex` is not logged in or the call fails.
enum HeadToHeadRunner {
    static func run(_ args: Arguments) async throws {
        switch args.positional.first {
        case "template": try template(args)
        case "build": try build(args)
        case "record": try await HeadToHeadRecordRunner.run(args)
        case "play": try await HeadToHeadPlaybackRunner.run(args)
        case nil: try await compare(args)
        case let other?: throw EvalError.missing("unknown head-to-head subcommand \(other); expected template, build, record, play, or no subcommand")
        }
    }

    // MARK: template

    private static func template(_ args: Arguments) throws {
        guard let out = args.string("out") else { throw EvalError.missing("--out <directory> is required") }
        let otherName = args.string("other-name") ?? "Wispr Flow"
        let slots = HeadToHeadTemplate.plan(count: args.int("count") ?? HeadToHeadTemplate.defaultCount)
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hushyURL = directory.appendingPathComponent("hushy.md")
        let otherURL = directory.appendingPathComponent(slug(otherName) + ".md")
        try HeadToHeadTemplate.render(slots: slots, product: "Hushy").write(to: hushyURL, atomically: true, encoding: .utf8)
        try HeadToHeadTemplate.render(slots: slots, product: otherName).write(to: otherURL, atomically: true, encoding: .utf8)
        let long = slots.filter(\.isLong).count
        print("Wrote \(slots.count) slots (\(long) long) to:\n  \(hushyURL.path)\n  \(otherURL.path)")
        print("Next: dictate every slot into hushy.md with Hushy and into \(otherURL.lastPathComponent) with \(otherName), then run `murmur-eval head-to-head build`.")
    }

    private static func slug(_ name: String) -> String {
        let lowered = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return lowered.split(separator: "-").joined(separator: "-")
    }

    // MARK: build

    private static func build(_ args: Arguments) throws {
        guard let hushyPath = args.string("hushy"), let otherPath = args.string("other") else {
            throw EvalError.missing("--hushy <file> and --other <file> are required")
        }
        guard let out = args.string("out") else { throw EvalError.missing("--out pairs.json is required") }
        let otherName = args.string("other-name") ?? "Wispr Flow"
        let hushy = HeadToHeadTemplate.parse(try String(contentsOfFile: hushyPath, encoding: .utf8))
        let other = HeadToHeadTemplate.parse(try String(contentsOfFile: otherPath, encoding: .utf8))
        let audioDirectory = args.string("audio-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let result = HeadToHeadTemplate.build(hushy: hushy, other: other, otherName: otherName, audioDirectory: audioDirectory)
        guard !result.pairs.isEmpty else {
            throw EvalError.missing("No slot is filled on both sides (Hushy filled \(hushy.outputs.count), \(otherName) filled \(other.outputs.count))")
        }
        let outURL = URL(fileURLWithPath: out)
        try HeadToHeadPairs.write(result.pairs, to: outURL)
        print("Wrote \(result.pairs.count) pairs to \(outURL.path)")
        if !result.missingHushy.isEmpty { print("  filled only in \(otherName) (skipped): \(result.missingHushy.joined(separator: ", "))") }
        if !result.missingOther.isEmpty { print("  filled only in Hushy (skipped): \(result.missingOther.joined(separator: ", "))") }
        let withAudio = result.pairs.filter { $0.audioPath != nil }.count
        if audioDirectory != nil { print("  audio attached for \(withAudio)/\(result.pairs.count) pairs") }
    }

    // MARK: compare (judge + form + votes)

    private static func compare(_ args: Arguments) async throws {
        guard let pairsPath = args.string("pairs") else { throw EvalError.missing("--pairs <file.json> is required") }
        let pairs = try HeadToHeadPairs.load(from: URL(fileURLWithPath: pairsPath))
        let seed = UInt64(args.int("seed") ?? Int(HeadToHeadBlinding.defaultSeed))
        let otherName = pairs.first?.otherName ?? "other"
        let blinded = HeadToHeadBlinding.blind(pairs, seed: seed)
        let scores = Dictionary(uniqueKeysWithValues: pairs.map { ($0.id, HeadToHeadScoring.score($0)) })

        if let formPath = args.string("form") {
            let url = URL(fileURLWithPath: formPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HeadToHeadReviewForm.render(blinded, seed: seed).write(to: url, atomically: true, encoding: .utf8)
        }

        let judgeOutcome: HeadToHeadJudge.Outcome? = args.flag("no-judge") ? nil : await runJudge(blinded, args: args)
        let byID = Dictionary(uniqueKeysWithValues: blinded.map { ($0.id, $0) })
        let judgePreferences: [String: Preference] = Dictionary(uniqueKeysWithValues: (judgeOutcome?.verdicts ?? []).compactMap { verdict in
            byID[verdict.id].map { (verdict.id, $0.unblind(verdict.choice)) }
        })

        let voteFiles = (args.string("votes") ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let humans = try voteFiles.map { path -> HeadToHeadVotes.Unblinded in
            let url = URL(fileURLWithPath: path)
            return try HeadToHeadVotes.unblind(try HeadToHeadVotes.load(from: url), fileName: url.lastPathComponent, blinded: blinded, seed: seed)
        }

        let summary = Summary(pairs: pairs, otherName: otherName, seed: seed, scores: scores,
                              judge: judgeOutcome, judgePreferences: judgePreferences, humans: humans,
                              judgeModel: args.string("judge-model") ?? "gpt-6-luna")
        Runners.emit(summary.markdown(formPath: args.string("form"), reportPath: args.string("report")), details: summary.details())
        if let reportPath = args.string("report") {
            try summary.writeReport(to: URL(fileURLWithPath: reportPath), blinded: blinded)
        }
    }

    private static func runJudge(_ blinded: [BlindedPair], args: Arguments) async -> HeadToHeadJudge.Outcome {
        let backend = CodexCLIJudge(model: args.string("judge-model") ?? "gpt-6-luna")
        let judge = HeadToHeadJudge(backend: backend, maxCalls: args.int("judge-calls") ?? HeadToHeadJudge.defaultMaxCalls)
        return await judge.judge(blinded)
    }
}

// MARK: - Summary

extension HeadToHeadRunner {
    struct Summary {
        let pairs: [HeadToHeadPair]
        let otherName: String
        let seed: UInt64
        let scores: [String: HeadToHeadScoring.PairScore]
        let judge: HeadToHeadJudge.Outcome?
        let judgePreferences: [String: Preference]
        let humans: [HeadToHeadVotes.Unblinded]
        let judgeModel: String

        var judgeTally: HeadToHeadScoring.Tally { .of(Array(judgePreferences.values)) }

        /// Pair id -> majority of the human votes on that pair (pairs with no votes omitted).
        var humanMajority: [String: Preference] {
            var result: [String: Preference] = [:]
            for pair in pairs {
                let votes = humans.compactMap { $0.preferences[pair.id] }
                if let majority = HeadToHeadScoring.majority(votes) { result[pair.id] = majority }
            }
            return result
        }

        /// Judge + every human as equal voters, majority per pair.
        var combinedMajority: [String: Preference] {
            var result: [String: Preference] = [:]
            for pair in pairs {
                var votes = humans.compactMap { $0.preferences[pair.id] }
                if let judgeVote = judgePreferences[pair.id] { votes.append(judgeVote) }
                if let majority = HeadToHeadScoring.majority(votes) { result[pair.id] = majority }
            }
            return result
        }

        var judgeHumanAgreement: (agree: Int, total: Int) {
            let majority = humanMajority
            let shared = judgePreferences.keys.filter { majority[$0] != nil }
            return (shared.filter { judgePreferences[$0] == majority[$0] }.count, shared.count)
        }

        var flagged: [HeadToHeadScoring.PairScore] {
            pairs.compactMap { scores[$0.id] }.filter { $0.lostContent.hasAny }
        }

        func markdown(formPath: String?, reportPath: String?) -> String {
            var lines = ["### Head-to-head · Hushy vs \(otherName) · \(pairs.count) pairs · seed \(seed)"]
            lines.append(judgeLine())
            if humans.isEmpty {
                lines.append("- Humans: no --votes files yet (generate the form with --form and collect 3 reviewers)")
            } else {
                for human in humans {
                    let tally = HeadToHeadScoring.Tally.of(Array(human.preferences.values))
                    lines.append("  - \(human.reviewer.isEmpty ? "(unnamed)" : human.reviewer): \(tallyText(tally)) over \(tally.total) voted")
                }
                let majority = HeadToHeadScoring.Tally.of(Array(humanMajority.values))
                lines.insert("- Humans (\(humans.count) reviewer\(humans.count == 1 ? "" : "s"), majority per pair): \(tallyText(majority))", at: 2)
                let agreement = judgeHumanAgreement
                if agreement.total > 0 {
                    lines.append("- Judge vs human majority agreement: \(Runners.percent(Double(agreement.agree) / Double(agreement.total))) (\(agreement.agree)/\(agreement.total))")
                }
                let combined = HeadToHeadScoring.Tally.of(Array(combinedMajority.values))
                lines.append("- Combined (judge + humans, majority): \(tallyText(combined))")
            }
            lines.append(gateLine())
            let distances = pairs.compactMap { scores[$0.id] }
            let meanDistance = distances.isEmpty ? 0 : Double(distances.map(\.editDistance).reduce(0, +)) / Double(distances.count)
            let medianRate = EvalMetrics.percentile(distances.map(\.editRate), 0.5)
            lines.append("- Word-level edit distance between outputs: mean \(String(format: "%.1f", meanDistance)) words · median \(Runners.percent(medianRate)) of the longer output")
            let flags = flagged
            let numbers = flags.filter { !$0.lostContent.numbersOnlyInHushy.isEmpty || !$0.lostContent.numbersOnlyInOther.isEmpty }.count
            let names = flags.filter { !$0.lostContent.namesOnlyInHushy.isEmpty || !$0.lostContent.namesOnlyInOther.isEmpty }.count
            let negations = flags.filter(\.lostContent.negationMismatch)
            lines.append("- Lost-content flags: \(flags.count)/\(pairs.count) pairs (numbers \(numbers) · names \(names) · negations \(negations.count)\(negations.isEmpty ? "" : " [" + negations.map(\.id).joined(separator: ", ") + "]"))")
            if let formPath { lines.append("- Review form: \(formPath)") }
            if let reportPath { lines.append("- Report (includes the unblinding key — do not send to reviewers): \(reportPath)") }
            return lines.joined(separator: "\n")
        }

        private func judgeLine() -> String {
            guard let judge else { return "- Judge: skipped (--no-judge)" }
            var line = "- Judge (codex-cli \(judgeModel), \(HeadToHeadJudge.pairsPerCall) pairs/call, \(judge.callsMade) calls, \(judge.callsFailed) failed)"
            if let reason = judge.skippedReason { return line + ": skipped — \(reason)" }
            line += ": \(tallyText(judgeTally))"
            let unjudged = pairs.count - judgeTally.total
            if unjudged > 0 {
                line += " · \(unjudged) unjudged" + (judge.unjudgedForBudget.isEmpty ? "" : " (\(judge.unjudgedForBudget.count) over the \(HeadToHeadJudge.defaultMaxCalls)-call budget)")
            }
            return line
        }

        private func gateLine() -> String {
            let source: (String, HeadToHeadScoring.Tally)? = if !humans.isEmpty {
                ("human majority", .of(Array(humanMajority.values)))
            } else if judgeTally.total > 0 {
                ("judge only — humans still needed", judgeTally)
            } else {
                nil
            }
            guard let (label, tally) = source, tally.total > 0 else { return "- Gate 12 (Hushy ≥ 50% preferred): unmeasured" }
            let verdict = tally.hushyPreferredOfDecisive >= 0.5 ? "PASS" : "FAIL"
            return "- Gate 12 (Hushy ≥ 50% preferred, \(label)): **\(verdict)** at \(Runners.percent(tally.hushyPreferredOfDecisive)) of decisive votes"
        }

        private func tallyText(_ tally: HeadToHeadScoring.Tally) -> String {
            "Hushy preferred \(Runners.percent(tally.hushyPreferredOfDecisive)) of decisive (Hushy \(tally.hushy) · \(otherName) \(tally.other) · tie \(tally.tie)) · \(Runners.percent(tally.hushyPreferredWithTiesAsHalf)) with ties as half"
        }

        /// Per-pair lines for stdout only (never appended to results.md): which side each judge
        /// and reviewer preferred plus the lost-content flags — ids and flags, no paragraph text.
        func details() -> [String] {
            let majority = humanMajority
            var lines: [String] = []
            for pair in pairs {
                var parts: [String] = []
                if let judgeVote = judgePreferences[pair.id] { parts.append("judge=\(judgeVote.rawValue)") }
                if let human = majority[pair.id] { parts.append("humans=\(human.rawValue)") }
                if let score = scores[pair.id] {
                    parts.append("edits=\(score.editDistance)")
                    let lost = score.lostContent
                    if !lost.numbersOnlyInHushy.isEmpty { parts.append("numbers only in Hushy: \(lost.numbersOnlyInHushy.joined(separator: " "))") }
                    if !lost.numbersOnlyInOther.isEmpty { parts.append("numbers only in \(otherName): \(lost.numbersOnlyInOther.joined(separator: " "))") }
                    if !lost.namesOnlyInHushy.isEmpty { parts.append("names only in Hushy: \(lost.namesOnlyInHushy.joined(separator: " "))") }
                    if !lost.namesOnlyInOther.isEmpty { parts.append("names only in \(otherName): \(lost.namesOnlyInOther.joined(separator: " "))") }
                    if !lost.negationsOnlyInHushy.isEmpty { parts.append("NEGATION only in Hushy: \(lost.negationsOnlyInHushy.joined(separator: " "))") }
                    if !lost.negationsOnlyInOther.isEmpty { parts.append("NEGATION only in \(otherName): \(lost.negationsOnlyInOther.joined(separator: " "))") }
                }
                lines.append("  \(pair.id): " + parts.joined(separator: " · "))
            }
            return ["Per pair:"] + lines
        }

        func writeReport(to url: URL, blinded: [BlindedPair]) throws {
            let hushyIsA = Dictionary(uniqueKeysWithValues: blinded.map { ($0.id, $0.hushyIsA) })
            let majority = humanMajority
            let combined = combinedMajority
            let entries: [[String: Any]] = pairs.map { pair in
                let score = scores[pair.id]
                var entry: [String: Any] = [
                    "id": pair.id, "hushyOutput": pair.hushyOutput, "otherOutput": pair.otherOutput,
                    "hushyIsA": hushyIsA[pair.id] ?? false,
                    "editDistance": score?.editDistance ?? 0, "editRate": score?.editRate ?? 0,
                    "judge": judgePreferences[pair.id]?.rawValue as Any? ?? NSNull(),
                    "humanMajority": majority[pair.id]?.rawValue as Any? ?? NSNull(),
                    "combinedMajority": combined[pair.id]?.rawValue as Any? ?? NSNull(),
                    "humans": humans.map { ["reviewer": $0.reviewer, "preference": $0.preferences[pair.id]?.rawValue as Any? ?? NSNull()] },
                ]
                if let lost = score?.lostContent {
                    entry["lostContent"] = [
                        "numbersOnlyInHushy": lost.numbersOnlyInHushy, "numbersOnlyInOther": lost.numbersOnlyInOther,
                        "namesOnlyInHushy": lost.namesOnlyInHushy, "namesOnlyInOther": lost.namesOnlyInOther,
                        "negationsOnlyInHushy": lost.negationsOnlyInHushy, "negationsOnlyInOther": lost.negationsOnlyInOther,
                    ]
                }
                if let audioPath = pair.audioPath { entry["audioPath"] = audioPath }
                if let reasoning = judge?.verdicts.first(where: { $0.id == pair.id })?.reasoning, !reasoning.isEmpty {
                    entry["judgeReasoning"] = reasoning
                }
                return entry
            }
            let tally = judgeTally
            let payload: [String: Any] = [
                "schemaVersion": 1, "kind": "head-to-head", "otherName": otherName, "seed": seed,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "arguments": Array(CommandLine.arguments.dropFirst()),
                "judge": [
                    "model": judgeModel, "callsMade": judge?.callsMade ?? 0, "callsFailed": judge?.callsFailed ?? 0,
                    "skipped": judge?.skippedReason as Any? ?? NSNull(),
                    "hushy": tally.hushy, "other": tally.other, "tie": tally.tie,
                    "hushyPreferredOfDecisive": tally.hushyPreferredOfDecisive,
                ],
                "humanReviewers": humans.map(\.reviewer),
                "pairs": entries,
            ]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
    }
}
