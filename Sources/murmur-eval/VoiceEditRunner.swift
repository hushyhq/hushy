import Foundation
import MurmurCore

/// `murmur-eval voice-edit [--cases Evals/voice-edit-dev.jsonl] --out <file.jsonl> [--backend mlx --mlx-model <dir>]`
///
/// Voice edit through the app's code path (`VoiceEditor.run`): per case, the router's signals, the model's answer
/// and the guard, exactly as a dictation over a selection runs. Three ways to tell an instruction from dictation are
/// scored on the same answers:
///   rules  `VoiceEditSignals.rulesAnswer` alone, no model
///   model  the model's `kind`, asked for every case (one extra call for the cases the app skips)
///   app    what ships: the router skips the model for words with no sign of an instruction, the model decides the rest
/// Faithfulness is scored on the app's outcome for every instruction case with the case's own checks (`keep`,
/// `want`, `avoid`, `shorter`, `bullets`, `decline`). The output file holds each case's answer (the text is invented).
enum VoiceEditRunner {
    struct Case: Decodable {
        let id: String
        let app: String
        let kind: String
        let category: String
        let selection: String
        let spoken: String
        let keep: [String]
        let want: [String]
        let avoid: [String]
        let shorter: Bool
        let bullets: Bool
        let decline: Bool

        var isInstruction: Bool { kind == "instruction" }
    }

    struct Scored {
        let item: Case
        let rules: SpokenOverSelection
        let model: SpokenOverSelection?
        let app: SpokenOverSelection
        let outcome: VoiceEditOutcome
        let failures: [String]
        let milliseconds: Int
        let askedModel: Bool
        let row: [String: Any]
    }

    static func run(_ args: Arguments) async throws {
        let path = args.string("cases") ?? Paths.root.appendingPathComponent("voice-edit-dev.jsonl").path
        guard let out = args.string("out") else { throw failure("voice-edit needs --out <file.jsonl>") }
        let cases = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
        let model = LanguageModels.current
        print("### Voice edit · \(cases.count) cases · model \(model.identifier)")
        var scored: [Scored] = []
        for item in cases {
            scored.append(await score(item, model: model))
            if scored.count % 10 == 0 { FileHandle.standardError.write(Data("\(scored.count)/\(cases.count)\n".utf8)) }
        }
        try write(scored.map(\.row), to: out)
        print(VoiceEditReport.markdown(scored))
    }

    static func score(_ item: Case, model: any LanguageModel) async -> Scored {
        guard let selection = SelectedText(text: item.selection) else { fatalError("case \(item.id) has no selection") }
        let started = ContinuousClock.now
        let run = await VoiceEditor.run(spoken: item.spoken, selection: selection, model: model)
        let elapsed = Int(ModelPace.ms(ContinuousClock.now - started))
        let modelTrace: VoiceEditor.Trace?
        if let trace = run.trace {
            modelTrace = trace
        } else {
            modelTrace = await VoiceEditor.editTraced(.init(selection: item.selection, instruction: item.spoken), model: model)
        }
        let modelAnswer: SpokenOverSelection? = switch modelTrace?.kind {
        case "dictation": .replacement
        case "edit", "cannot": .instruction
        default: nil
        }
        let app: SpokenOverSelection = run.outcome == .dictation ? .replacement : .instruction
        let failures = item.isInstruction ? faithfulness(item, outcome: run.outcome) : []
        var row: [String: Any] = [
            "id": item.id, "kind": item.kind, "category": item.category, "app": item.app, "spoken": item.spoken,
            "rules": run.signals.rulesAnswer.rawValue, "model": modelAnswer?.rawValue ?? "none",
            "app_route": app.rawValue, "asked_model": run.trace != nil, "ms": elapsed, "failures": failures,
            "guard": modelTrace?.guardReason ?? "", "model_text": modelTrace?.answer ?? "",
        ]
        switch run.outcome {
        case .edited(let text): row["outcome"] = "edited"; row["edited"] = text
        case .dictation: row["outcome"] = "dictation"
        case .declined(let why): row["outcome"] = "declined:\(why.rawValue)"
        }
        return Scored(item: item, rules: run.signals.rulesAnswer, model: modelAnswer, app: app, outcome: run.outcome,
                      failures: failures, milliseconds: elapsed, askedModel: run.trace != nil, row: row)
    }

    /// The case's checks against what the app would have pasted. Empty means faithful.
    static func faithfulness(_ item: Case, outcome: VoiceEditOutcome) -> [String] {
        if item.decline {
            if case .declined = outcome { return [] }
            return ["should decline, got \(label(outcome))"]
        }
        guard case .edited(let text) = outcome else { return ["no edit: \(label(outcome))"] }
        let lower = text.lowercased()
        func has(_ alternatives: String) -> Bool {
            alternatives.split(separator: "|").contains { lower.contains($0.lowercased()) }
        }
        var failures: [String] = []
        for fact in item.keep where !has(fact) { failures.append("lost \(fact)") }
        for wanted in item.want where !has(wanted) { failures.append("missing \(wanted)") }
        for unwanted in item.avoid where has(unwanted) { failures.append("still has \(unwanted)") }
        if item.shorter, words(text) >= words(item.selection) { failures.append("not shorter") }
        if item.bullets {
            let marked = text.split(separator: "\n").filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return ["- ", "• ", "* "].contains { trimmed.hasPrefix($0) } || trimmed.range(of: "^\\d+[.)] ", options: .regularExpression) != nil
            }
            if marked.count < 2 { failures.append("not a list") }
        }
        return failures
    }

    static func label(_ outcome: VoiceEditOutcome) -> String {
        switch outcome {
        case .edited: "edited"
        case .dictation: "dictation"
        case .declined(let why): "declined \(why.rawValue)"
        }
    }

    private static func words(_ text: String) -> Int { text.split { $0.isWhitespace }.count }

    private static func write(_ rows: [[String: Any]], to path: String) throws {
        let lines = try rows.map { row in
            String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "murmur-eval", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// The voice-edit eval's tables.
enum VoiceEditReport {
    static func markdown(_ scored: [VoiceEditRunner.Scored]) -> String {
        var lines = ["", "Detection (positive = instruction; \(scored.filter(\.item.isInstruction).count) instructions, \(scored.filter { !$0.item.isInstruction }.count) dictations)", "",
                     "| Detector | Precision | Recall | Dictation taken as an edit | Instruction pasted as text | No answer |",
                     "|---|---|---|---|---|---|"]
        lines.append(detectionRow("rules", scored.map { ($0.item.isInstruction, $0.rules) }))
        lines.append(detectionRow("model", scored.map { ($0.item.isInstruction, $0.model) }))
        lines.append(detectionRow("app (rules skip, model decides)", scored.map { ($0.item.isInstruction, $0.app) }))
        let instructions = scored.filter { $0.item.isInstruction && !$0.item.decline }
        let faithful = instructions.filter(\.failures.isEmpty).count
        let edited = instructions.filter { if case .edited = $0.outcome { true } else { false } }
        let lostFact = edited.filter { $0.failures.contains { $0.hasPrefix("lost ") } }.count
        let declinedHonestly = instructions.filter { if case .declined = $0.outcome { true } else { false } }.count
        let impossible = scored.filter(\.item.decline)
        let impossibleDeclined = impossible.filter(\.failures.isEmpty).count
        lines += ["", "Edits (app path, \(instructions.count) doable instructions)", "",
                  "| Faithful | Edited | Edited but lost a kept fact | Declined (text kept) | Impossible asks declined |",
                  "|---|---|---|---|---|",
                  "| \(faithful)/\(instructions.count) | \(edited.count) | \(lostFact) | \(declinedHonestly) | \(impossibleDeclined)/\(impossible.count) |"]
        lines += ["", "Per category (faithful / cases)", "", "| Category | Faithful | Median ms |", "|---|---|---|"]
        let categories = Dictionary(grouping: scored.filter(\.item.isInstruction), by: \.item.category)
        for (category, rows) in categories.sorted(by: { $0.key < $1.key }) {
            lines.append("| \(category) | \(rows.filter(\.failures.isEmpty).count)/\(rows.count) | \(median(rows.map(\.milliseconds))) |")
        }
        let asked = scored.filter(\.askedModel)
        lines += ["", "Latency (app path, ms): edits median \(median(edited.map(\.milliseconds))), p90 \(percentile(edited.map(\.milliseconds), 0.9)); every case with a model call (\(asked.count)) median \(median(asked.map(\.milliseconds))); cases the router sent straight to dictation: \(scored.count - asked.count)"]
        lines += ["", "Failures", ""]
        for row in scored where !row.failures.isEmpty || row.app != (row.item.isInstruction ? .instruction : .replacement) {
            let route = row.app.rawValue
            lines.append("- \(row.item.id) [\(row.item.kind) → \(route), \(VoiceEditRunner.label(row.outcome))]: \(row.failures.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    static func detectionRow(_ name: String, _ answers: [(Bool, SpokenOverSelection?)]) -> String {
        var truePositive = 0, falsePositive = 0, falseNegative = 0, none = 0
        for (isInstruction, answer) in answers {
            guard let answer else { none += 1; continue }
            switch (isInstruction, answer) {
            case (true, .instruction): truePositive += 1
            case (false, .instruction): falsePositive += 1
            case (true, .replacement): falseNegative += 1
            case (false, .replacement): break
            }
        }
        let precision = truePositive + falsePositive == 0 ? 0 : Double(truePositive) / Double(truePositive + falsePositive)
        let recall = truePositive + falseNegative == 0 ? 0 : Double(truePositive) / Double(truePositive + falseNegative)
        return "| \(name) | \(String(format: "%.3f", precision)) | \(String(format: "%.3f", recall)) | \(falsePositive) | \(falseNegative) | \(none) |"
    }

    static func median(_ values: [Int]) -> Int { percentile(values, 0.5) }

    static func percentile(_ values: [Int], _ share: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * share))]
    }
}
