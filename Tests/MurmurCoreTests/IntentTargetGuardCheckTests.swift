import Foundation
import Testing
@testable import MurmurCore

/// Training targets for the intent model must be answers the app keeps. The app refuses any answer
/// `IntentOutputGuard` rejects, so a target the guard would refuse teaches the model an answer that is thrown away.
///
/// The batch test below is the round-7 data tool: it runs only when `ROUND7_GUARD_IN` names a JSONL file of
/// `{id, spoken, target}` rows, and it writes one verdict row per input to `ROUND7_GUARD_OUT`
/// (`{id, verdict, reason, afterFormat}`). Without the variable it does nothing, so the suite stays hermetic.
///
///     ROUND7_GUARD_IN=rows.jsonl ROUND7_GUARD_OUT=verdicts.jsonl swift test --filter IntentTargetGuardCheck
///
/// `afterFormat` repeats the check on the target after `IntentTextFormat.format`, the step the app runs on the
/// model's answer before judging it. Every sentence below is invented.
@Suite("Intent target guard check")
struct IntentTargetGuardCheckTests {
    private func verdict(_ target: String, _ spoken: String) -> (accepted: Bool, reason: String) {
        switch IntentOutputGuard.check(target, raw: spoken) {
        case .accepted: (true, "")
        case .rejected(let reason): (false, reason)
        }
    }

    @Test("a faithful typed target is kept")
    func faithfulTargetIsKept() {
        #expect(verdict("Send the invoice at 4.", "send the invoice at three no four").accepted)
        #expect(verdict("Book the van for Thursday.", "uh book the van for thursday").accepted)
    }

    @Test("a target with a value the speaker never said is refused")
    func unsaidValueIsRefused() {
        let result = verdict("Meet at 5.", "meet at four")
        #expect(!result.accepted)
        #expect(result.reason == "changed digits")
    }

    @Test("a target with a capitalised name the speaker never said is refused")
    func unsaidNameIsRefused() {
        #expect(!verdict("Ask Marguerite to review it.", "ask the new hire to review it").accepted)
    }

    @Test("a target far longer than the speech is refused")
    func overlongTargetIsRefused() {
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        #expect(verdict(long, "short note").reason == "longer than transcript")
    }

    @Test("batch: run the files named by ROUND7_GUARD_IN and ROUND7_GUARD_OUT")
    func batch() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["ROUND7_GUARD_IN"], let output = environment["ROUND7_GUARD_OUT"] else { return }
        let options = CleanupOptions(level: .clean)
        let lines = try String(contentsOfFile: input, encoding: .utf8).split(whereSeparator: \.isNewline)
        var out: [String] = []
        for line in lines {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, let spoken = row["spoken"] as? String,
                  let target = row["target"] as? String else { continue }
            let plain = verdict(target, spoken)
            let formatted = verdict(IntentTextFormat.format(target, options: options), spoken)
            let record: [String: Any] = [
                "id": id, "verdict": plain.accepted ? "accepted" : "rejected", "reason": plain.reason,
                "afterFormat": formatted.accepted ? "accepted" : "rejected: \(formatted.reason)",
            ]
            out.append(String(decoding: try JSONSerialization.data(
                withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
        }
        try (out.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
