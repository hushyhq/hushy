import Foundation

/// Jev (TypeSafe) as a second opinion on meeting digests the deterministic scoring can't see:
/// is anything in the notes unsupported by the transcript, and do they cover the whole meeting?
/// Reads `murmur-eval meeting --out` files; ~12k input tokens per meeting at $0.042 per million.
///
///   murmur-eval meeting-jev label=run.json[,label=run.json…] [--golden Evals/meeting-eval/golden.json]
///
/// Report only (not a gate). The API key comes from `JudgeRunner.loadAPIKey` and is never printed.
enum MeetingJevJudge {
    static let questions: [String: TypeSafeClient.Question] = [
        "unsupported": .init(
            type: .noul,
            instructions: .string(
                "notes contains a statement, owner, date or decision that the transcript does not support, "
                    + "or presents something the meeting later changed or cancelled as still current."),
            criteria: .strings([
                "true": "Something in notes is invented, attributed to the wrong person, or out of date by the end of the meeting.",
                "false": "Everything in notes is supported by the transcript as it stood at the end of the meeting.",
            ])),
        "coverage": .init(
            type: .score,
            instructions: .string(
                "How completely notes captures the decisions and the action items (who does what) of the whole "
                    + "meeting in transcript, from beginning to end, including the last part."),
            criteria: .array([
                .string("Misses most decisions and action items."),
                .string("Captures some, misses many, or covers only part of the meeting."),
                .string("Captures most, with several gaps."),
                .string("Captures nearly all, with one or two gaps."),
                .string("Captures every decision and action item of the whole meeting."),
            ])),
    ]

    static func run(_ args: Arguments) async throws {
        guard let key = JudgeRunner.loadAPIKey() else {
            print("meeting-jev skipped: no TypeSafe API key (TYPESAFE_API_KEY or ~/.config/hushy/typesafe_api_key)")
            return
        }
        let golden = try JSONDecoder().decode(
            MeetingGolden.self, from: Data(contentsOf: URL(fileURLWithPath: args.string("golden") ?? "Evals/meeting-eval/golden.json")))
        let transcripts = Dictionary(uniqueKeysWithValues: golden.meetings.map { ($0.id, $0.transcript) })
        var lines = ["### Meeting digest · Jev second opinion", "", "| run | unsupported (mean P) | coverage (0–4) | meetings |", "|---|---|---|---|"]
        for spec in args.positional.flatMap({ $0.split(separator: ",") }) {
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw EvalError.missing("expected label=path.json, got \(spec)") }
            let rows = try JSONDecoder().decode([MeetingRunner.Row].self, from: Data(contentsOf: URL(fileURLWithPath: parts[1])))
            var unsupported: [Double] = [], coverage: [Double] = []
            for row in rows {
                guard let transcript = transcripts[row.id] else { continue }
                let notes = "Title: \(row.title)\n\nSummary:\n\(row.summary)\n\nAction items:\n" + row.actionItems.map { "- \($0)" }.joined(separator: "\n")
                let state = TypeSafeClient.AnyJSON.strings(["transcript": transcript, "notes": notes])
                let response = try await TypeSafeClient.ask(state: state, questions: questions, apiKey: key)
                if let p = response.answers["unsupported"]?.noul { unsupported.append(p) }
                if let s = response.answers["coverage"]?.score { coverage.append(s) }
            }
            lines.append("| \(parts[0]) | \(format(unsupported)) | \(format(coverage)) | \(rows.count) |")
        }
        Runners.emit(lines.joined(separator: "\n"))
    }

    static func format(_ values: [Double]) -> String {
        values.isEmpty ? "–" : String(format: "%.2f", values.reduce(0, +) / Double(values.count))
    }
}
