import CryptoKit
import Foundation
import MurmurCore

/// Markdown summary and JSON evidence for `murmur-eval tones`.
enum TonesReport {
    typealias Row = TonesRunner.Row
    typealias Record = ToneEvalChecks.Record
    typealias Tally = ToneEvalChecks.Tally

    private static func fraction(_ passed: Int, _ total: Int) -> String { "\(passed)/\(total)" }

    static func print(rows: [Row], records: [Record], caseFile: String, path: TonesRunner.CleanupPath) {
        Swift.print("### Tones (dev set) · \(caseFile) · cleanup path \(path.rawValue)")
        Swift.print("- Model available: \(SmartCleaner.isModelAvailable) · LanguageModel: \(LanguageModels.current.identifier)")
        let reasons = Dictionary(grouping: rows.compactMap(\.rejection), by: { $0 }).mapValues(\.count)
        Swift.print("- Model output used as the base on \(rows.filter(\.usedModel).count)/\(rows.count) cases"
            + (reasons.isEmpty ? "" : "; fallback reasons: " + reasons.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")))
        Swift.print("\n| Tone | Meets expectation (exact or checks; no forbidden term) | Checks | Exact | Faithful |")
        Swift.print("|---|---:|---:|---:|---:|")
        for tone in DictationTone.allCases {
            let all = ToneEvalChecks.breakdown(records, tone: tone).all
            Swift.print("| \(tone.rawValue) | \(fraction(all.meetsExpectation, all.total)) | \(fraction(all.checks, all.total)) | \(fraction(all.exact, all.total)) | \(fraction(all.faithful, all.total)) |")
        }
        Swift.print("\n| Tone | Contested: meets | Contested: faithful | Not contested: meets | Not contested: faithful |")
        Swift.print("|---|---:|---:|---:|---:|")
        for tone in DictationTone.allCases {
            let split = ToneEvalChecks.breakdown(records, tone: tone)
            Swift.print("| \(tone.rawValue) | \(fraction(split.contested.meetsExpectation, split.contested.total)) | \(fraction(split.contested.faithful, split.contested.total)) | \(fraction(split.uncontested.meetsExpectation, split.uncontested.total)) | \(fraction(split.uncontested.faithful, split.uncontested.total)) |")
        }
        Swift.print("\n### Failures")
        var failures = 0
        for row in rows {
            for tone in DictationTone.allCases {
                guard let score = row.scores[tone], let reason = score.failureReason else { continue }
                failures += 1
                Swift.print("  ✘ \(row.item.id) · \(tone.rawValue)\(row.item.isContested ? " · contested" : "")")
                Swift.print("      base:   \(flat(row.base))")
                Swift.print("      output: \(flat(row.outputs[tone] ?? ""))")
                Swift.print("      reason: \(reason)")
            }
        }
        if failures == 0 { Swift.print("  none") }
    }

    private static func flat(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ⏎ ") }

    // MARK: JSON evidence

    private static func tallyJSON(_ tally: Tally) -> [String: Int] {
        ["total": tally.total, "meetsExpectation": tally.meetsExpectation, "checks": tally.checks,
         "exact": tally.exact, "faithful": tally.faithful]
    }

    static func write(rows: [Row], records: [Record], to path: String, caseFileURL: URL, path cleanup: TonesRunner.CleanupPath) throws {
        let hash = SHA256.hash(data: try Data(contentsOf: caseFileURL)).map { String(format: "%02x", $0) }.joined()
        let cases: [[String: Any]] = rows.map { row in
            let tones: [String: Any] = Dictionary(uniqueKeysWithValues: DictationTone.allCases.compactMap { tone in
                row.scores[tone].map { score in
                    (tone.rawValue, [
                        "output": row.outputs[tone] ?? "",
                        "meetsExpectation": score.meetsExpectation,
                        "exactMatch": score.exactMatch as Any? ?? NSNull(),
                        "checksPassed": score.checksPassed as Any? ?? NSNull(),
                        "faithful": score.faithful,
                        "missingContent": score.missingContent,
                        "unexpectedIntroductions": score.unexpectedIntroductions,
                        "failedChecks": score.failedChecks.map(\.detail),
                    ] as [String: Any])
                }
            })
            return [
                "id": row.item.id, "category": row.item.category, "tags": row.item.tags,
                "contested": row.item.isContested, "context": String(describing: row.context),
                "input": row.item.raw, "base": row.base, "usedModel": row.usedModel,
                "rejection": row.rejection as Any? ?? NSNull(), "tones": tones,
            ]
        }
        let summaries: [String: Any] = Dictionary(uniqueKeysWithValues: DictationTone.allCases.map { tone in
            let split = ToneEvalChecks.breakdown(records, tone: tone)
            return (tone.rawValue, [
                "all": tallyJSON(split.all), "contested": tallyJSON(split.contested), "uncontested": tallyJSON(split.uncontested),
            ] as [String: Any])
        })
        let payload: [String: Any] = [
            "schemaVersion": 1, "title": "Tones (dev set)", "caseFile": caseFileURL.lastPathComponent, "caseFileSHA256": hash,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "arguments": Array(CommandLine.arguments.dropFirst()),
            "cleanupPath": cleanup.rawValue, "languageModel": LanguageModels.current.identifier,
            "modelAvailable": SmartCleaner.isModelAvailable, "modelUsedOnCases": rows.filter(\.usedModel).count, "tones": summaries, "cases": cases,
        ]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
