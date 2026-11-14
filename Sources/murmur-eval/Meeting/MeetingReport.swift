import Darwin
import Foundation

/// Markdown for `murmur-eval meeting` (appended to Evals/results.md).
enum MeetingReport {
    static func markdown(_ rows: [MeetingRunner.Row], label: String, memory: String, perMeeting: Bool = true) -> String {
        var total = MeetingScore()
        rows.forEach { total.add($0.score) }
        let latencies = rows.map(\.milliseconds).sorted()
        let hour = rows.filter { (55...65).contains($0.minutes) }.map(\.milliseconds).sorted()
        let wordsPerSecond = Double(rows.map(\.words).reduce(0, +)) / max(1, rows.map(\.milliseconds).reduce(0, +) / 1_000)
        var lines = [
            "### Meeting digest · \(label) · \(rows.count) meetings",
            "",
            "| action recall (owner+task) | task recall | action precision | decision recall | Q1 / Q2 / Q3 / Q4 recall | corrections applied | due right | stale items | small-talk items | hallucinated owners | p50 latency | 55–65 min p50 |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|",
            "| \(pct(total.actionsFound, total.goldActions)) | \(pct(total.actionTasksFound, total.goldActions)) | \(pct(total.predictedMatchingGold, total.predictedActions)) | \(pct(total.decisionsFound, total.goldDecisions)) | \((0..<4).map { pct(total.quartileFound[$0], total.quartileTotal[$0]) }.joined(separator: " / ")) | \(total.correctionsApplied)/\(total.corrections) | \(pct(total.duesRight, total.duesChecked)) | \(total.staleItems) | \(total.smallTalkItems) | \(total.hallucinatedOwners)/\(total.predictedActions) | \(seconds(median(latencies))) | \(seconds(median(hour))) |",
            "",
            "Throughput \(String(format: "%.0f", wordsPerSecond)) transcript words/s; \(memory); load \(loadAverage()). Quartile recall counts action items (owner+task) and decisions by where they are said.",
        ]
        guard perMeeting else { return lines.joined(separator: "\n") }
        lines += [
            "",
            "| meeting | min | words | latency | calls | actions | decisions | predicted | notes |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        for row in rows {
            let s = row.score
            lines.append("| \(row.id) | \(row.minutes) | \(row.words) | \(seconds(row.milliseconds)) | \(row.calls) | \(s.actionsFound)/\(s.goldActions) | \(s.decisionsFound)/\(s.goldDecisions) | \(s.predictedActions) | \(row.note) |")
        }
        return lines.joined(separator: "\n")
    }

    static func pct(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "–" : String(format: "%.0f%%", 100 * Double(part) / Double(whole))
    }

    static func seconds(_ ms: Double?) -> String {
        guard let ms else { return "–" }
        return String(format: "%.1f s", ms / 1_000)
    }

    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Peak physical footprint of this process (includes Metal buffers) and the current one.
    static func memory() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "memory n/a" }
        return String(format: "peak footprint %.2f GB (now %.2f GB)",
                      Double(info.ledger_phys_footprint_peak) / 1_073_741_824, Double(info.phys_footprint) / 1_073_741_824)
    }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "n/a" }
        return String(format: "%.1f", loads[0])
    }
}
