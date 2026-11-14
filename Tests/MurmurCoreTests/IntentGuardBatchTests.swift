import Foundation
import Testing
@testable import MurmurCore

/// Runs the intent guard over `{id, spoken, target}` rows or intent chat rows with an assistant `text` target.
/// Layout-only `paragraphs` rows have no text target and are skipped. It does nothing unless
/// `GUARD_BATCH_IN` and `GUARD_BATCH_OUT` name files. `GUARD_BATCH_BLOCK=1` supplies visible block words:
///
///     GUARD_BATCH_IN=rows.jsonl GUARD_BATCH_OUT=verdicts.jsonl swift test --filter IntentGuardBatch
///
/// Each output row is `{id, verdict, reason}`. Nothing is logged. (Sentences in the suite's own tests are invented.)
@Suite("Intent guard batch")
struct IntentGuardBatchTests {
    @Test("batch: run the files named by GUARD_BATCH_IN and GUARD_BATCH_OUT")
    func batch() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["GUARD_BATCH_IN"], let output = environment["GUARD_BATCH_OUT"] else { return }
        let lines = try String(contentsOfFile: input, encoding: .utf8).split(whereSeparator: \.isNewline)
        var out: [String] = []
        for line in lines {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let messages = row["messages"] as? [[String: String]] ?? []
            let user = messages.first { $0["role"] == "user" }?["content"]
            let assistant = messages.first { $0["role"] == "assistant" }?["content"]
            let spoken = (row["spoken"] as? String) ?? user.map { content in
                let text = content.components(separatedBy: "Transcript: ").last ?? content
                let source = text.hasPrefix("Text: ") ? String(text.dropFirst("Text: ".count)) : text
                return source.components(separatedBy: "\nOutput:").first ?? source
            }
            let target = (row["target"] as? String) ?? assistant.flatMap {
                guard let output = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else { return nil }
                return output["text"] as? String
            }
            guard let spoken, let target else { continue }
            let id = (row["id"] as? String) ?? String(out.count)
            let spellingWords: Set<String> = if environment["GUARD_BATCH_BLOCK"] != nil,
                let user, let start = user.range(of: "Transcript: "),
                user.hasPrefix("About this person\n") {
                PersonBlock.spellingWords(in: String(user[..<start.lowerBound]))
            } else { [] }
            var record: [String: Any] = ["id": id, "verdict": "accepted", "reason": ""]
            if case .rejected(let reason) = IntentOutputGuard.check(target, raw: spoken, spellingWords: spellingWords) {
                record["verdict"] = "rejected"
                record["reason"] = reason
                if environment["GUARD_BATCH_RUNS"] != nil {
                    record["spokenRuns"] = SpokenNumberRuns(spoken).runs.map { $0.joined(separator: "+") }
                    record["unsaidNames"] = CorrectionBound.unsaidNames(
                        answer: target, draft: spoken, spellingWords: spellingWords)
                    record["targetRuns"] = SpokenNumberRuns(target).runs.map { $0.joined(separator: "+") }
                }
            }
            out.append(String(decoding: try JSONSerialization.data(
                withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
        }
        try (out.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
