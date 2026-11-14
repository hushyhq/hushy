import Foundation
import MurmurCore

/// `murmur-eval answer-check --cases <jsonl> --runs <intent-app output jsonl> --out <jsonl> [--register professional|casual|prompt]`
///
/// Replays the whole-transcript checks on the model answers an earlier `intent-app` run saved (`modelAnswers`), without
/// loading a model: for each answer, what `IntentOutputGuard` says, what the not-a-rewrite bound says under the register,
/// the content words the answer leaves out, and the negations it adds. It reads the spoken text from `--cases` by id and
/// the answers from `--runs`. Eval output only, for invented and public text; the rows hold the words, like the runs do.
enum AnswerCheckRunner {
    static func run(_ args: Arguments) async throws {
        guard let casesPath = args.string("cases"), let runsPath = args.string("runs"), let out = args.string("out") else {
            throw NSError(domain: "murmur-eval", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "answer-check needs --cases <jsonl> --runs <intent-app output> --out <jsonl>"])
        }
        let register = args.string("register").flatMap(IntentRegister.init(rawValue:))
        let spoken = Dictionary(uniqueKeysWithValues: try rows(casesPath).compactMap { row -> (String, String)? in
            guard let id = row["id"] as? String, let text = row["spoken"] as? String else { return nil }
            return (id, text)
        })
        var result = [[String: Any]]()
        for run in try rows(runsPath) {
            guard let id = run["id"] as? String, let raw = spoken[id] else { continue }
            let answers = (run["modelAnswers"] as? [String] ?? []).compactMap(text(of:))
            var checked = [[String: Any]]()
            for answer in answers {
                let account = RewriteAccount.measure(answer, against: raw)
                let replay = AnswerReplay.check(answer: answer, raw: raw, register: register)
                checked.append([
                    "answer": answer, "guard": replay.verdict, "pasted": replay.text,
                    "is_rewrite": account.isRewrite(under: register), "invents_speaker": account.inventsSpeaker,
                    "lost": replay.lostContent, "unpaid_negations": replay.unpaidNegations,
                    "negations": [replay.negations.spoken, replay.negations.written],
                ])
            }
            result.append(["id": id, "spoken": raw, "text": run["text"] as Any, "answers": checked])
        }
        let lines = try result.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        print("answer-check rows=\(result.count) output=\(out)")
    }

    private static func rows(_ path: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if path.hasSuffix(".json") { return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? [] }
        return try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private static func text(of answer: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])?["text"] as? String
    }
}
