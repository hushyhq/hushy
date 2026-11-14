import CryptoKit
import Foundation
import MurmurCore

/// Aggregation, markdown summary and JSON evidence for `murmur-eval dev-messages`.
enum DevMessagesReport {
    typealias Record = DevMessagesRunner.Record

    struct Summary {
        let records: [Record]
        let levels: [CleanupLevel]
        let caseFile: String
        let backend: String
        let cleanGate: String

        func records(at level: CleanupLevel) -> [Record] { records.filter { $0.level == level } }
    }

    struct Tally {
        var passed = 0
        var total = 0
        var text: String { "\(passed)/\(total) (\(pct(total == 0 ? 0 : Double(passed) / Double(total))))" }
    }

    static func tally<Key: Hashable>(_ rows: [Record], by key: (Record) -> Key) -> [Key: Tally] {
        var result: [Key: Tally] = [:]
        for row in rows {
            var entry = result[key(row), default: Tally()]
            entry.total += 1
            if row.passed { entry.passed += 1 }
            result[key(row), default: Tally()] = entry
        }
        return result
    }

    static func checkTally(_ rows: [Record]) -> [DevMessageChecks.Kind: Tally] {
        var result: [DevMessageChecks.Kind: Tally] = [:]
        for row in rows {
            for outcome in row.outcomes {
                var entry = result[outcome.kind, default: Tally()]
                entry.total += 1
                if outcome.passed { entry.passed += 1 }
                result[outcome.kind] = entry
            }
        }
        return result
    }

    /// Cases ranked by failed checks (most first), then by id, for the "worst outputs" list.
    static func worst(_ rows: [Record], limit: Int) -> [Record] {
        rows.filter { !$0.passed }
            .sorted { ($0.failed.count, $1.item.id) > ($1.failed.count, $0.item.id) }
            .prefix(limit).map { $0 }
    }

    // MARK: Markdown

    static func print(_ summary: Summary) {
        Swift.print("### Developer messages (dev set) · \(summary.caseFile) · backend \(summary.backend) · clean gate \(summary.cleanGate)")
        Swift.print("- Model available: \(SmartCleaner.isModelAvailable) · LanguageModel: \(LanguageModels.current.identifier)")
        let first = summary.records(at: summary.levels[0])
        let matched = first.filter(\.classificationMatches).count
        Swift.print("- App classification matches the expected category: \(matched)/\(first.count)")
        for level in summary.levels {
            let rows = summary.records(at: level)
            let passed = rows.filter(\.passed).count
            Swift.print("\n## \(level.title) (\(level.rawValue)) · \(passed)/\(rows.count) cases pass (\(pct(rows.isEmpty ? 0 : Double(passed) / Double(rows.count))))")
            let attempted = rows.filter(\.modelWasAttempted).count
            Swift.print("- Model output used on \(rows.filter(\.usedModel).count)/\(rows.count) cases; model stage reached on \(attempted)/\(rows.count)")
            if attempted == 0 { Swift.print("- MODEL NEVER RAN: rules only (every case fell back with \"model unavailable\")") }
            let reasons = Dictionary(grouping: rows.compactMap(\.rejection), by: { $0 }).mapValues(\.count)
            if !reasons.isEmpty {
                Swift.print("- Model fallback reasons: " + reasons.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))
            }
            table("Check type", checkTally(rows).map { ($0.key.rawValue, $0.value) })
            table("Classified context", tally(rows, by: \.category.rawValue).map { ($0.key, $0.value) })
            table("Case category", tally(rows, by: \.item.category).map { ($0.key, $0.value) })
            let byTag = tally(rows.flatMap { row in row.item.tags.map { (tag: $0, row: row) } }, tag: true)
            table("Hard-part tag", byTag.map { ($0.key, $0.value) })
            let causes = Dictionary(grouping: rows.compactMap(\.cause), by: { $0 }).mapValues(\.count)
            Swift.print("\n| Failure cause | Cases |\n|---|---:|")
            for cause in DevMessageChecks.Cause.allCases { Swift.print("| \(cause.rawValue) | \(causes[cause, default: 0]) |") }
            Swift.print("\n### Worst outputs (\(level.rawValue))")
            for row in worst(rows, limit: 12) { printFailure(row) }
        }
    }

    private static func tally(_ rows: [(tag: String, row: Record)], tag: Bool) -> [String: Tally] {
        var result: [String: Tally] = [:]
        for entry in rows {
            var value = result[entry.tag, default: Tally()]
            value.total += 1
            if entry.row.passed { value.passed += 1 }
            result[entry.tag] = value
        }
        return result
    }

    private static func table(_ title: String, _ rows: [(String, Tally)]) {
        Swift.print("\n| \(title) | Pass |\n|---|---:|")
        for (name, value) in rows.sorted(by: { $0.0 < $1.0 }) { Swift.print("| \(name) | \(value.text) |") }
    }

    private static func printFailure(_ row: Record) {
        func flat(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ⏎ ") }
        Swift.print("  ✘ \(row.item.id) [\(row.item.target.bundleID) | \(row.item.target.windowTitle ?? "-")]")
        Swift.print("      classified: \(row.category.rawValue) (expected \(row.expected.rawValue)) · cause: \(row.cause?.rawValue ?? "-")")
        Swift.print("      input:  \(flat(row.item.raw))")
        Swift.print("      output: \(flat(row.output))")
        Swift.print("      ideal:  \(flat(row.item.ideal))")
        Swift.print("      failed: \(row.failed.map(\.detail).joined(separator: "; "))")
    }

    // MARK: JSON evidence

    static func write(_ summary: Summary, to path: String, caseFileURL: URL) throws {
        let hash = SHA256.hash(data: try Data(contentsOf: caseFileURL)).map { String(format: "%02x", $0) }.joined()
        let cases: [[String: Any]] = summary.records.map { row in
            [
                "id": row.item.id, "level": row.level.rawValue, "category": row.item.category, "tags": row.item.tags,
                "bundleID": row.item.target.bundleID, "windowTitle": row.item.target.windowTitle as Any? ?? NSNull(),
                "classified": row.category.rawValue, "expectedCategory": row.expected.rawValue,
                "input": row.item.raw, "ideal": row.item.ideal, "output": row.output, "rulesOutput": row.rulesOutput,
                "usedModel": row.usedModel, "rejection": row.rejection as Any? ?? NSNull(),
                "passed": row.passed, "cause": row.cause?.rawValue as Any? ?? NSNull(),
                "checks": row.outcomes.map { ["kind": $0.kind.rawValue, "label": $0.label, "passed": $0.passed, "detail": $0.detail] },
            ]
        }
        let levelSummaries: [[String: Any]] = summary.levels.map { level in
            let rows = summary.records(at: level)
            return [
                "level": level.rawValue, "passed": rows.filter(\.passed).count, "total": rows.count,
                "usedModel": rows.filter(\.usedModel).count, "modelAttempted": rows.filter(\.modelWasAttempted).count,
                "rejections": Dictionary(grouping: rows.compactMap(\.rejection), by: { $0 }).mapValues(\.count),
                "byCheck": checkTally(rows).reduce(into: [String: [Int]]()) { $0[$1.key.rawValue] = [$1.value.passed, $1.value.total] },
                "byContext": tally(rows, by: \.category.rawValue).reduce(into: [String: [Int]]()) { $0[$1.key] = [$1.value.passed, $1.value.total] },
                "byCause": Dictionary(grouping: rows.compactMap(\.cause), by: { $0.rawValue }).mapValues(\.count),
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1, "title": "Developer messages (dev set)", "caseFile": summary.caseFile, "caseFileSHA256": hash,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "arguments": Array(CommandLine.arguments.dropFirst()),
            "backend": summary.backend, "languageModel": LanguageModels.current.identifier,
            "modelAvailable": SmartCleaner.isModelAvailable, "cleanGate": summary.cleanGate,
            "levels": levelSummaries, "cases": cases,
        ]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}
