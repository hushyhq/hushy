import Foundation
import MurmurCore

extension LearnRunner {
    struct ModeSummary {
        let learned: Int
        let learnable: Int
        let meanEdits: Double
        let maxEdits: Int
        let silent: Int
        let falseLearns: Int
        let readyFalseSuggestions: Int
        let adversarial: Int

        var falseRate: Double { adversarial == 0 ? 0 : Double(falseLearns) / Double(adversarial) }

        init(_ result: ModeResult) {
            let learnable = result.terms.filter(\.term.learnable)
            let counts = learnable.compactMap(\.editsToLearn)
            self.learned = counts.count
            self.learnable = learnable.count
            self.meanEdits = counts.isEmpty ? 0 : Double(counts.reduce(0, +)) / Double(counts.count)
            self.maxEdits = counts.max() ?? 0
            self.silent = result.terms.filter(\.activatedSilently).count
            self.falseLearns = result.adversarial.filter { !$0.activated.isEmpty }.count
            self.readyFalseSuggestions = result.adversarial.filter { !$0.readySuggestions.isEmpty }.count
            self.adversarial = result.adversarial.count
        }
    }

    static func report(_ results: [ModeResult], args: Arguments) {
        let summaries = results.map(ModeSummary.init)
        print("### Learn from corrections · simulation (both policy modes)")
        print("")
        print("| Metric | " + results.map(\.mode.rawValue).joined(separator: " | ") + " |")
        print("|---|" + results.map { _ in "---|" }.joined())
        func row(_ label: String, _ value: (ModeResult, ModeSummary) -> String) {
            print("| \(label) | " + zip(results, summaries).map(value).joined(separator: " | ") + " |")
        }
        row("Learnable terms in use") { "\($1.learned)/\($1.learnable)" }
        row("Fixes before in use: mean / max") { String(format: "%.2f / %d", $1.meanEdits, $1.maxEdits) }
        row("Suggestion shown after 1 fix") { r, s in
            "\(r.terms.filter { $0.term.learnable && $0.suggestedAfterFirstEdit }.count)/\(s.learnable)"
        }
        row("Terms activated without a confirm") { "\($1.silent)/\($0.terms.count)" }
        row("Known-limit terms learned") { r, _ in
            "\(r.terms.filter { !$0.term.learnable && $0.editsToLearn != nil }.count)/\(r.terms.filter { !$0.term.learnable }.count)"
        }
        row("False learns (adversarial → active)") { "\($1.falseLearns)/\($1.adversarial) (\(pct($1.falseRate)))" }
        row("Adversarial → *ready* suggestion") { "\($1.readyFalseSuggestions)/\($1.adversarial)" }
        row("Adversarial → any suggestion") { r, s in "\(r.adversarial.filter { !$0.candidates.isEmpty }.count)/\(s.adversarial)" }
        row("Follow-up term accuracy: baseline → learned") { r, _ in
            let cases = Double(max(1, r.followUp.cases))
            return "\(pct(Double(r.followUp.baselineHits) / cases)) → \(pct(Double(r.followUp.learnedHits) / cases))"
        }
        row("Follow-up WER: baseline → learned") { r, _ in
            let cases = Double(max(1, r.followUp.cases))
            return "\(pct(r.followUp.baselineWER / cases)) → \(pct(r.followUp.learnedWER / cases))"
        }
        row("Control sentences changed") { r, _ in "\(r.followUp.controlChanged)/\(r.followUp.controlCases)" }
        print("")
        printDetails(results)

        if let path = args.string("report") { write(results, summaries, to: path) }
        gate(results, summaries, args: args)
    }

    private static func printDetails(_ results: [ModeResult]) {
        for result in results {
            print("\(result.mode.rawValue) — fixes until in use (— = not in \(maxAttempts); * = known limit):")
            print("  " + result.terms.map { "\($0.term.learnable ? "" : "*")\($0.term.term) \($0.editsToLearn.map(String.init) ?? "—")" }
                .joined(separator: " · "))
            let flagged = result.adversarial.filter { !$0.activated.isEmpty || !$0.candidates.isEmpty }
            for item in flagged {
                let verdict = item.activated.isEmpty ? "ok" : "FALSE LEARN \(item.activated)"
                print("  [\(item.scenario.category)] \(item.scenario.name): \(verdict) · suggestion \(item.candidates)"
                      + (item.readySuggestions.isEmpty ? "" : " (ready: \(item.readySuggestions))"))
            }
            print("  other \(result.adversarial.count - flagged.count) adversarial scenarios: nothing learned or suggested")
        }
    }

    private static func gate(_ results: [ModeResult], _ summaries: [ModeSummary], args: Arguments) {
        for (result, summary) in zip(results, summaries) {
            if result.mode == .suggestOnly, summary.silent > 0 || summary.falseLearns > 0 {
                fail("suggest-only mode activated \(summary.silent + summary.falseLearns) item(s) without a confirm")
            }
            if let limit = args.string("max-false-learn").flatMap(Double.init), summary.falseRate > limit {
                fail("\(result.mode.rawValue): false-learn rate \(pct(summary.falseRate)) above \(pct(limit))")
            }
            if let limit = args.string("max-mean-edits").flatMap(Double.init),
               summary.meanEdits > limit || summary.learned < summary.learnable {
                fail("\(result.mode.rawValue): mean fixes \(summary.meanEdits) above \(limit) or a learnable term was not learned")
            }
            if result.followUp.controlChanged > 0 {
                fail("\(result.mode.rawValue): learned items changed \(result.followUp.controlChanged) control sentence(s)")
            }
        }
    }

    private static func write(_ results: [ModeResult], _ summaries: [ModeSummary], to path: String) {
        let modes: [[String: Any]] = zip(results, summaries).map { result, summary in
            let followUp = result.followUp
            let cases = Double(max(1, followUp.cases))
            return [
                "mode": result.mode.rawValue, "meanEditsToLearn": summary.meanEdits, "falseLearnRate": summary.falseRate,
                "activatedWithoutConfirm": summary.silent, "readyFalseSuggestions": summary.readyFalseSuggestions,
                "terms": result.terms.map { ["term": $0.term.term, "learnable": $0.term.learnable, "editsToLearn": $0.editsToLearn ?? -1] },
                "followUp": [
                    "cases": followUp.cases, "baselineHits": followUp.baselineHits, "learnedHits": followUp.learnedHits,
                    "baselineWER": followUp.baselineWER / cases, "learnedWER": followUp.learnedWER / cases,
                    "controlCases": followUp.controlCases, "controlChanged": followUp.controlChanged,
                ],
                "adversarial": result.adversarial.map {
                    ["name": $0.scenario.name, "category": $0.scenario.category, "activated": $0.activated,
                     "candidates": $0.candidates, "ready": $0.readySuggestions]
                },
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 2, "title": "Learn from corrections",
            "timestamp": ISO8601DateFormatter().string(from: Date()), "modes": modes,
        ]
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("learn: \(message)\n".utf8))
        exit(1)
    }

    static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}
