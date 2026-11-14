import Foundation
import MurmurCore

/// `murmur-eval discard-audit --golden <dev.json> [--level clean|polished] [--strategy hybrid|model]
///   [--report out.json]`
///
/// Task 110. For every dev case where a guard threw the model's whole answer away, asks Jev v2 whether
/// the discarded answer was actually good, so the checks that over-reject can be loosened or turned into
/// span repair first. Jev is the second opinion `Evals/JUDGES.md` describes; the checks still gate.
///
/// Per case it judges (a) the answer the guard discarded, and (b) the text that was pasted instead, with
/// the case's own reference. Every answer that was used is judged too, which gives the judge's agreement
/// with the deterministic checks on this very set. Eval only: dev text, the existing remote judge path,
/// no key material printed. The discarded answer is held in memory by the cleaner only because this
/// command builds it with `retainsRejectedCandidates`.
enum DiscardAuditRunner {
    struct Row {
        let item: Runners.GoldenCase
        let pasted: String
        let pastedChecks: Bool
        let outcome: ModelOutcome
        let guardCode: GuardCode?
        let discarded: String?
        let discardedChecks: Bool?
        var pastedJudgment: JevJudgment?
        var discardedJudgment: JevJudgment?
        var smallJudge: SmallSpanJudge.Result?
    }

    /// The three questions the founder asked, from Jev's typed answers.
    enum Role: String, CaseIterable {
        case meaning = "meaning kept", content = "nothing added or dropped", register = "register and layout"

        func score(_ j: JevJudgment) -> Double {
            switch self {
            case .meaning: max(j.meaningBroken, j.changedFact)
            case .content: max(j.droppedContent, j.overEdited)
            case .register: max(1 - j.readsClean, j.layoutWrong, j.disfluencyLeft, j.correctionLeft)
            }
        }
    }

    static func run(_ args: Arguments) async throws {
        guard let apiKey = JudgeRunner.loadAPIKey() else {
            print("### Discard audit · skipped\nNo TypeSafe API key found; the strong judge is eval-only and needs one.")
            return
        }
        let cases = try Runners.loadGolden(args)
        let options = try args.cleanupOptions(level: args.cleanupLevel)
        let cleaner = args.makeCleaner(retainsRejectedCandidates: true)
        cleaner.prewarm(prefixesFor: options.level, grammarContract: options.grammarContract)
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        let settings = PipelineSettings(cleanupOptions: options)
        var rows: [Row] = []
        for item in cases {
            let result = await pipeline.clean(item.spoken, settings: settings, strategy: args.strategy)
            guard result.groups.count == 1, let group = result.groups.first else { continue }
            let candidate = group.rejectedCandidate.map {
                SmartCleaner.presentable($0, raw: item.spoken, options: options)
            }
            let probe = Runners.CaseResult(
                item: item, input: item.spoken,
                output: SmartCleaner.Output(text: result.text, pressEnter: result.pressEnter, usedModel: result.usedModel,
                                            rejection: nil), latency: 0)
            rows.append(Row(
                item: item, pasted: result.text, pastedChecks: probe.passed, outcome: group.outcome,
                guardCode: group.guardCode, discarded: candidate, discardedChecks: candidate.map(probe.matches)))
        }
        let judge = JevJudge(apiKey: apiKey)
        let level = args.cleanupLevel.rawValue
        // One judgment per distinct (spoken, output) pair.
        struct Job: Sendable { let spoken: String; let output: String; let reference: String }
        var jobs: [Job] = []
        var seen = Set<String>()
        func add(_ item: Runners.GoldenCase, _ text: String) {
            let key = item.id + "\u{1}" + text
            if seen.insert(key).inserted { jobs.append(Job(spoken: item.spoken, output: text, reference: item.expected)) }
        }
        for row in rows { add(row.item, row.pasted); if let d = row.discarded { add(row.item, d) } }
        let judged = try await JudgeClient.mapConcurrently(jobs) { job in
            try await judge.judge(level: level, spoken: job.spoken, output: job.output, reference: job.reference).value
        }
        var byJob: [String: JevJudgment] = [:]
        for (job, judgment) in zip(jobs, judged) { byJob[job.spoken + "\u{1}" + job.output] = judgment }
        for index in rows.indices {
            rows[index].pastedJudgment = byJob[rows[index].item.spoken + "\u{1}" + rows[index].pasted]
            rows[index].discardedJudgment = rows[index].discarded.flatMap { byJob[rows[index].item.spoken + "\u{1}" + $0] }
        }
        if args.flag("small-judge") {
            // The pasted text of a discarded answer is the rules draft, which is what the answer is compared with.
            for index in rows.indices {
                guard let candidate = rows[index].discarded else { continue }
                rows[index].smallJudge = await SmallSpanJudge.ask(model: LanguageModels.current, draft: rows[index].pasted, answer: candidate)
            }
        }
        try report(rows, args: args)
    }

    /// The small on-device judge against Jev (a "bad" answer is one Jev fails) and against the golden answer.
    private static func smallJudgeLines(_ discards: [Row]) -> [String] {
        let asked = discards.filter { $0.smallJudge != nil && $0.discardedJudgment != nil }
        guard !asked.isEmpty else { return [] }
        func line(_ title: String, _ list: [Row]) -> String {
            let accept = list.filter { $0.smallJudge?.accepts == true }
            let reject = list.filter { $0.smallJudge?.accepts != true }
            let falseAccept = accept.filter { $0.discardedJudgment?.band == .fail }.count
            let falseReject = reject.filter { $0.discardedJudgment?.band == .pass }.count
            let falseAcceptGolden = accept.filter { $0.discardedChecks == false }.count
            let agreed = list.filter { row in
                switch row.discardedJudgment?.band {
                case .pass?: row.smallJudge?.accepts == true
                case .fail?: row.smallJudge?.accepts != true
                default: false
                }
            }.count
            let decided = list.filter { $0.discardedJudgment?.band != .unsure }.count
            return "| \(title) | \(list.count) | \(accept.count) | \(agreed)/\(decided) | \(falseAccept) | \(falseReject) | \(falseAcceptGolden) |"
        }
        var lines = ["", "Small on-device judge (same question asked of each changed span; every span must be \"same\" to accept):",
                     "| group | answers | accepted | agrees with Jev (pass/fail only) | false accepts vs Jev | false rejects vs Jev | accepts an answer the golden rejects |",
                     "|---|---|---|---|---|---|---|"]
        lines.append(line("all", asked))
        lines.append(line("a changed number", asked.filter { $0.smallJudge?.spans.contains { $0.touchesNumber } == true }))
        lines.append(line("a changed or new \"not\"", asked.filter { $0.smallJudge?.spans.contains { $0.touchesNegation } == true }))
        lines.append(line("a changed name", asked.filter { $0.smallJudge?.spans.contains { $0.touchesName } == true }))
        let other = asked.filter { row in
            row.smallJudge?.spans.contains { $0.touchesNumber || $0.touchesNegation || $0.touchesName } != true }
        lines.append(line("none of those three", other))
        let times = asked.compactMap { $0.smallJudge?.milliseconds }.sorted()
        if !times.isEmpty {
            func percentile(_ p: Double) -> Int { times[min(times.count - 1, Int(Double(times.count - 1) * p))] }
            lines.append("- added time per rewrite: p50 \(percentile(0.5)) ms, p95 \(percentile(0.95)) ms (\(times.count) rewrites, \(asked.compactMap { $0.smallJudge?.spans.count }.reduce(0, +)) spans)")
        }
        return lines
    }

    private static func report(_ rows: [Row], args: Arguments) throws {
        let everyDiscard = rows.filter { $0.discardedJudgment != nil }
        // A discarded answer that, once laid out, is the very text that was pasted cost the person nothing.
        let discards = everyDiscard.filter { $0.discarded != $0.pasted }
        var lines = ["### Discard audit · \(args.cleanupLevel.rawValue) · \(rows.count) single-group cases · \(everyDiscard.count) discarded answers, "
            + "\(everyDiscard.count - discards.count) identical to what was pasted (no cost), \(discards.count) differ and are judged below"]
        // Jev against the checks on the answers that were pasted: how far to trust the judge on this set.
        let pastedJudged = rows.compactMap { row in row.pastedJudgment.map { (row, $0) } }
        let agree = pastedJudged.filter { $0.0.pastedChecks == ($0.1.band == .pass || ($0.1.band == .unsure && $0.0.pastedChecks)) }.count
        let checksPassJevFail = pastedJudged.filter { $0.0.pastedChecks && $0.1.band == .fail }.count
        let checksFailJevPass = pastedJudged.filter { !$0.0.pastedChecks && $0.1.band == .pass }.count
        lines.append("- Judge against the checks on pasted text: \(agree)/\(pastedJudged.count) agree (unsure counted with the checks); "
            + "checks pass and Jev fails \(checksPassJevFail); checks fail and Jev passes \(checksFailJevPass)")
        // Table per guard.
        var byGuard: [String: [Row]] = [:]
        for row in discards { byGuard[row.guardCode?.rawValue ?? "unknown", default: []].append(row) }
        lines.append("")
        lines.append("| guard | fired | judged good (false reject) | unsure | judged bad (true reject) | checks say answer was right |")
        lines.append("|---|---|---|---|---|---|")
        for (name, group) in byGuard.sorted(by: { $0.value.count > $1.value.count }) {
            let bands = group.compactMap { $0.discardedJudgment?.band }
            lines.append("| \(name) | \(group.count) | \(bands.filter { $0 == .pass }.count) | \(bands.filter { $0 == .unsure }.count) | "
                + "\(bands.filter { $0 == .fail }.count) | \(group.filter { $0.discardedChecks == true }.count) |")
        }
        let allBands = discards.compactMap { $0.discardedJudgment?.band }
        lines.append("| **all** | \(discards.count) | \(allBands.filter { $0 == .pass }.count) | \(allBands.filter { $0 == .unsure }.count) | "
            + "\(allBands.filter { $0 == .fail }.count) | \(discards.filter { $0.discardedChecks == true }.count) |")
        // Per Jev question: how often it objects (>= 0.5) to the discarded answers, by guard.
        lines += ["", "Which question objects to the discarded answers (count with p ≥ 0.5, of the guard's fired):"]
        let questions: [(String, (JevJudgment) -> Double)] = [
            ("meaning", { $0.meaningBroken }), ("changed_fact", { $0.changedFact }),
            ("dropped_content", { $0.droppedContent }), ("over_edited", { $0.overEdited }),
            ("reads_clean(no)", { 1 - $0.readsClean }), ("list_layout(no)", { $0.layoutWrong }),
            ("disfluency_left", { $0.disfluencyLeft }), ("correction_left", { $0.correctionLeft }),
        ]
        lines.append("| guard | " + questions.map(\.0).joined(separator: " | ") + " |")
        lines.append("|---|" + String(repeating: "---|", count: questions.count))
        for (name, group) in byGuard.sorted(by: { $0.value.count > $1.value.count }) {
            let cells = questions.map { q in "\(group.compactMap(\.discardedJudgment).filter { q.1($0) >= 0.5 }.count)" }
            lines.append("| \(name) (\(group.count)) | " + cells.joined(separator: " | ") + " |")
        }
        // The three roles and how they agree with each other.
        lines += ["", "Roles (a role objects when its worst question is ≥ 0.5):"]
        let judgments = discards.compactMap(\.discardedJudgment)
        var flags: [Role: [Bool]] = [:]
        for role in Role.allCases {
            flags[role] = judgments.map { role.score($0) >= 0.5 }
            lines.append("- \(role.rawValue): objects to \(flags[role]!.filter { $0 }.count) of \(judgments.count)")
        }
        let roles = Role.allCases
        for i in roles.indices { for j in roles.indices where j > i {
            let a = flags[roles[i]]!, b = flags[roles[j]]!
            let same = zip(a, b).filter { $0 == $1 }.count
            lines.append("- agreement \(roles[i].rawValue) vs \(roles[j].rawValue): \(same)/\(a.count)")
        } }
        if !judgments.isEmpty {
            let jevBad = judgments.map { $0.band == .fail }
            let checksBad = discards.map { $0.discardedChecks == false }
            lines.append("- agreement Jev fail vs checks (answer does not match expected): \(zip(jevBad, checksBad).filter { $0 == $1 }.count)/\(jevBad.count)")
        }
        // The pasted text next to the discarded answer.
        let better = discards.filter { ($0.discardedJudgment?.pBad ?? 1) + 0.1 < ($0.pastedJudgment?.pBad ?? 0) }.count
        let worse = discards.filter { ($0.discardedJudgment?.pBad ?? 0) > ($0.pastedJudgment?.pBad ?? 1) + 0.1 }.count
        lines.append("- Discarded answer judged clearly better than what was pasted: \(better); clearly worse: \(worse); about equal: \(discards.count - better - worse)")
        // Examples: the clearest false rejects and true rejects.
        func show(_ title: String, _ list: [Row]) {
            guard !list.isEmpty else { return }
            lines += ["", title]
            for row in list.prefix(3) {
                lines.append("  \(row.item.id) [\(row.guardCode?.rawValue ?? "?")] pBad discarded \(String(format: "%.2f", row.discardedJudgment?.pBad ?? 0)) vs pasted \(String(format: "%.2f", row.pastedJudgment?.pBad ?? 0))")
                lines.append("    spoken:    \(row.item.spoken)")
                lines.append("    discarded: \(row.discarded ?? "")")
                lines.append("    pasted:    \(row.pasted)")
            }
        }
        show("Clearest false rejects (Jev: answer was good):",
             discards.filter { $0.discardedJudgment?.band == .pass }.sorted { ($0.discardedJudgment?.pBad ?? 0) < ($1.discardedJudgment?.pBad ?? 0) })
        show("Clearest true rejects (Jev: answer was bad):",
             discards.filter { $0.discardedJudgment?.band == .fail }.sorted { ($0.discardedJudgment?.pBad ?? 0) > ($1.discardedJudgment?.pBad ?? 0) })
        lines += smallJudgeLines(discards)
        print(lines.joined(separator: "\n"))
        if let path = args.string("report") {
            let payload: [[String: Any]] = rows.map { row in
                var entry: [String: Any] = [
                    "id": row.item.id, "outcome": row.outcome.rawValue, "guard": row.guardCode?.rawValue as Any? ?? NSNull(),
                    "pastedChecks": row.pastedChecks, "pasted": row.pasted,
                    "pastedFaults": row.pastedJudgment?.faults as Any? ?? NSNull(),
                ]
                if let d = row.discarded {
                    entry["discarded"] = d
                    entry["discardedChecks"] = row.discardedChecks as Any? ?? NSNull()
                    entry["discardedFaults"] = row.discardedJudgment?.faults as Any? ?? NSNull()
                    entry["discardedPBad"] = row.discardedJudgment?.pBad as Any? ?? NSNull()
                    entry["discardedBand"] = row.discardedJudgment?.band.rawValue as Any? ?? NSNull()
                }
                return entry
            }
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
    }
}
