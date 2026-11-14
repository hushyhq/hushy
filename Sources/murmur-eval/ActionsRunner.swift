import Foundation
import MurmurCore

/// Evaluates the voice-actions intent/slot pipeline (`ActionExtractor`) against a golden set of
/// utterances, per docs/research/voice-actions.md §6. Text-only (no audio/ASR involved) — this
/// scores the trigger→structured-action path exactly as the pill would see it after ASR already
/// produced a transcript, mirroring how `cleanup` scores `SmartCleaner` on already-transcribed
/// text rather than through the microphone.
///
///   murmur-eval actions [--dataset Evals/actions-golden.json] [--limit N] [--budget-ms N]
///
/// `--budget-ms`: the extractor's per-call budget (default: the shipping 2.5 s); a longer one
/// measures the answers apart from timeouts on a loaded machine.
enum ActionsRunner {
    struct ExpectedIntent: Codable {
        let kind: String
        let titleContains: String?
        let hasDate: Bool?
        let calendar: String?
        let list: String?
        let location: Bool?
        let inputContains: String?

        enum CodingKeys: String, CodingKey {
            case kind, calendar, list, location
            case titleContains = "title_contains"
            case hasDate = "has_date"
            case inputContains = "input_contains"
        }
    }

    struct GoldenCase: Codable {
        let utterance: String
        let triggerHeld: Bool
        let expectedIntents: [ExpectedIntent]
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case utterance, notes
            case triggerHeld = "trigger_held"
            case expectedIntents = "expected_intents"
        }
    }

    struct CaseOutcome {
        let item: GoldenCase
        let result: ActionExtractionResult
        let latencyMs: Double
        /// Whether the "is this even an action" call was correct: both expected-and-got an
        /// action, or both expected-and-got no action (negative rejection).
        let intentCallCorrect: Bool
        let isNegative: Bool
        /// For a positive case: whether every expected intent kind was produced, in any order,
        /// among the returned actions (recall over kinds).
        let intentKindsMatched: Bool
        /// Slot accuracy per matched action (title substring, presence of a date when expected).
        let slotChecks: [Bool]
    }

    static func run(_ args: Arguments) async throws {
        let datasetPath = args.string("dataset") ?? "Evals/actions-golden.json"
        let url = URL(fileURLWithPath: datasetPath)
        let data = try Data(contentsOf: url)
        let allCases = try JSONDecoder().decode([GoldenCase].self, from: data)
        let cases = Array(allCases.prefix(args.int("limit") ?? .max))

        guard ActionExtractor.isModelAvailable else {
            print("""
                ### Voice Actions · \(cases.count) cases
                SKIPPED: Apple Foundation Models is unavailable on this Mac (Apple Intelligence \
                not enabled, unsupported hardware, or macOS < 26). The actions pipeline requires \
                it — this is not a pass/fail result, it is a hard prerequisite miss.
                """)
            return
        }

        var outcomes: [CaseOutcome] = []
        for item in cases {
            // The golden set has no Shortcuts library: simulate one with the Shortcut(s) the case
            // expects plus unrelated names (same policy as `murmur-eval tools`).
            let library = item.expectedIntents.filter { $0.kind == "runShortcut" }.compactMap(\.titleContains)
                + EvalShortcutLibrary.unrelated
            let extractor = ActionExtractor(budget: .milliseconds(args.int("budget-ms") ?? 2_500), shortcutLibrary: { library }, health: ModelHealth())
            let start = ContinuousClock.now
            let output = await extractor.extract(item.utterance, context: .current())
            let elapsedMs = Double((ContinuousClock.now - start).components.seconds) * 1000
                + Double((ContinuousClock.now - start).components.attoseconds) / 1e15
            outcomes.append(score(item: item, result: output.result, latencyMs: elapsedMs))
        }

        try report(outcomes: outcomes, args: args)
    }

    private static func score(item: GoldenCase, result: ActionExtractionResult, latencyMs: Double) -> CaseOutcome {
        let isNegative = item.expectedIntents.isEmpty
        let producedActions: [ProposedAction]
        switch result {
        case .actions(let actions): producedActions = actions
        case .notAnAction, .modelUnavailable, .rejected, .refused: producedActions = []
        }
        let producedIsAction = !producedActions.isEmpty
        let expectedIsAction = !isNegative
        let intentCallCorrect = producedIsAction == expectedIsAction

        var kindsMatched = true
        var slotChecks: [Bool] = []
        if expectedIsAction {
            var remaining = producedActions
            for expected in item.expectedIntents {
                guard let matchIndex = remaining.firstIndex(where: { $0.kind.rawValue == expected.kind }) else {
                    kindsMatched = false
                    continue
                }
                let matched = remaining.remove(at: matchIndex)
                slotChecks.append(checkTitle(matched, expected))
                if let hasDate = expected.hasDate {
                    slotChecks.append((matched.start != nil) == hasDate)
                }
                if let inputContains = expected.inputContains {
                    slotChecks.append((matched.shortcutInput ?? "").localizedCaseInsensitiveContains(inputContains))
                }
            }
        }

        return CaseOutcome(
            item: item, result: result, latencyMs: latencyMs, intentCallCorrect: intentCallCorrect,
            isNegative: isNegative, intentKindsMatched: kindsMatched, slotChecks: slotChecks)
    }

    private static func checkTitle(_ action: ProposedAction, _ expected: ExpectedIntent) -> Bool {
        guard let expectedSubstring = expected.titleContains else { return true }
        let haystack = (action.title + " " + (action.shortcutName ?? "")).lowercased()
        return haystack.contains(expectedSubstring.lowercased())
    }

    private static func report(outcomes: [CaseOutcome], args: Arguments) throws {
        let total = outcomes.count
        let negatives = outcomes.filter(\.isNegative)
        let positives = outcomes.filter { !$0.isNegative }

        // Intent precision: of utterances classified as *some* action, % where that call was
        // correct (i.e. it truly was a positive case) — voice-actions.md §6.2.
        let classifiedAsAction = outcomes.filter { outcome in
            if case .actions = outcome.result { return true }
            return false
        }
        let intentPrecision = classifiedAsAction.isEmpty ? 1.0
            : Double(classifiedAsAction.filter { !$0.isNegative }.count) / Double(classifiedAsAction.count)

        // Intent recall: of true positives, % correctly identified as *some* action.
        let intentRecall = positives.isEmpty ? 1.0
            : Double(positives.filter(\.intentCallCorrect).count) / Double(positives.count)

        // Negative rejection rate: of negatives, % correctly left as plain dictation.
        let negativeRejectionRate = negatives.isEmpty ? 1.0
            : Double(negatives.filter(\.intentCallCorrect).count) / Double(negatives.count)

        // Intent classification accuracy: of correctly-identified actions, % with the right kind(s).
        let correctlyIdentified = positives.filter(\.intentCallCorrect)
        let classificationAccuracy = correctlyIdentified.isEmpty ? 1.0
            : Double(correctlyIdentified.filter(\.intentKindsMatched).count) / Double(correctlyIdentified.count)

        // Slot accuracy, aggregated across every individual slot check.
        let allSlotChecks = positives.flatMap(\.slotChecks)
        let slotAccuracy = allSlotChecks.isEmpty ? 1.0
            : Double(allSlotChecks.filter { $0 }.count) / Double(allSlotChecks.count)

        let latencies = outcomes.map(\.latencyMs)
        let p50 = EvalMetrics.percentile(latencies, 0.5)
        let p95 = EvalMetrics.percentile(latencies, 0.95)

        let failingNegatives = negatives.filter { !$0.intentCallCorrect }
        let failingPositives = positives.filter { !$0.intentCallCorrect || !$0.intentKindsMatched }

        func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
        func ms(_ value: Double) -> String { String(format: "%.0fms", value) }

        let targetsMet = intentPrecision >= 0.97 && negativeRejectionRate >= 0.97
        let summary = """
            ### Voice Actions · \(total) cases (\(positives.count) positive, \(negatives.count) negative, \(String(format: "%.0f%%", Double(negatives.count) / Double(total) * 100)) negative)
            - Intent precision: **\(pct(intentPrecision))** (target ≥97%)
            - Intent recall: \(pct(intentRecall)) (target ≥90%)
            - Negative rejection rate: **\(pct(negativeRejectionRate))** (target ≥97%)
            - Intent classification accuracy: \(pct(classificationAccuracy)) (target ≥95%)
            - Slot accuracy: \(pct(slotAccuracy)) (target ≥90%, \(allSlotChecks.count) checks)
            - Latency: p50 \(ms(p50)), p95 \(ms(p95)) (budget: 2.5s hard ceiling — see ActionExtractor.budget; \
            revised from an initial 1.5s after measuring the real on-device model at p50 1448ms/p95 1599ms, \
            acceptable for an explicit, confirmation-gated action)
            - Release-blocking targets (precision & negative-rejection ≥97%): \(targetsMet ? "MET" : "NOT MET — report honestly, do not weaken the gate")
            """

        let failureLines = (failingNegatives + failingPositives).map { outcome -> String in
            let expected = outcome.isNegative ? "dictation (no action)" : outcome.item.expectedIntents.map(\.kind).joined(separator: "+")
            let got: String
            switch outcome.result {
            case .actions(let actions): got = actions.map(\.kind.rawValue).joined(separator: "+")
            case .notAnAction: got = "dictation (no action)"
            case .modelUnavailable: got = "model unavailable"
            case .rejected(let reason): got = "rejected: \(reason)"
            case .refused(let refusal): got = "refused (\(refusal.reason.rawValue)): \(refusal.message)"
            }
            return "  ✘ \"\(outcome.item.utterance)\" — expected: \(expected), got: \(got)"
        }

        var report = summary
        if !failureLines.isEmpty {
            report += "\n\nFailures:\n" + failureLines.joined(separator: "\n")
        }
        print(report)

        if let resultsPath = args.string("report") {
            try (report + "\n").appending(to: URL(fileURLWithPath: resultsPath))
        } else {
            try (report + "\n").appending(to: Paths.results)
        }
    }
}

private extension String {
    func appending(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(Data(("\n" + self).utf8))
            try handle.close()
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
