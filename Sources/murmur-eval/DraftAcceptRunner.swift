import Foundation
import HushyModelsMLX
import MurmurCore

/// `murmur-eval draft-accept --cases <jsonl> --target <4B dir> --draft <2B dir> --out <jsonl>`: how often a draft
/// model's greedy pick equals the target's answer token, fed the target's answer so far (teacher forcing). That is
/// the per-token acceptance a draft-and-verify decoder would see with greedy verification. Default register only.
/// Rows: id, answer tokens, matches over all tokens and over the content tokens (the JSON envelope excluded), and
/// the draft's own greedy decode time for the case.
enum DraftAcceptRunner {
    static func run(_ args: Arguments) async throws {
        guard let input = args.string("cases"), let output = args.string("out"),
              let targetDir = args.string("target"), let draftDir = args.string("draft") else {
            throw EvalError.missing("draft-accept needs --cases <jsonl> --target <dir> --draft <dir> --out <jsonl>")
        }
        func model(_ dir: String) -> MLXLanguageModel {
            var configuration = MLXLanguageModel.Configuration(directory: URL(fileURLWithPath: dir, isDirectory: true))
            configuration.promptProfile = .intent
            return MLXLanguageModel(configuration: configuration)
        }
        let target = model(targetDir), draft = model(draftDir)
        let schema = SmartCleaner.cleanedSchema
        let system = MLXLanguageModel.systemText(instructions: SmartCleaner.cleanupInstructions(confidenceGuided: false), schema: schema, profile: .intent)
        var rows = [String]()
        var totals = (all: 0, allHit: 0, content: 0, contentHit: 0)
        for line in try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, let spoken = row["spoken"] as? String else { continue }
            let prompt = IntentCleanupPrompt.user(transcript: spoken)
            let answer = try await target.respondVerbatim(system: system, prompt: prompt, schema: schema, maxTokens: 1_024)
            let forced = try await draft.teacherForcedPicks(system: system, prompt: prompt, answer: answer.text)
            let own = try await draft.respondVerbatim(system: system, prompt: prompt, schema: schema, maxTokens: 1_024)
            let hits = zip(forced.answer, forced.picks).map { $0 == $1 }
            let content = hits.count > 6 ? Array(hits[4..<(hits.count - 2)]) : []
            totals.all += hits.count; totals.allHit += hits.filter { $0 }.count
            totals.content += content.count; totals.contentHit += content.filter { $0 }.count
            let out: [String: Any] = [
                "id": id, "answerTokens": forced.answer.count, "matches": hits.filter { $0 }.count,
                "contentTokens": content.count, "contentMatches": content.filter { $0 }.count,
                "targetGen": answer.timings.generatedTokens, "targetMs": Int(answer.timings.totalMilliseconds),
                "draftGen": own.timings.generatedTokens, "draftMs": Int(own.timings.totalMilliseconds),
                "draftTtftMs": Int(own.timings.timeToFirstTokenMilliseconds),
            ]
            rows.append(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
        }
        try (rows.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        let rate = { (hit: Int, all: Int) in all == 0 ? 0 : Double(hit) / Double(all) }
        print("draft-accept cases=\(rows.count) tokens=\(totals.all) acceptAll=\(String(format: "%.3f", rate(totals.allHit, totals.all))) acceptContent=\(String(format: "%.3f", rate(totals.contentHit, totals.content))) output=\(output)")
    }
}
