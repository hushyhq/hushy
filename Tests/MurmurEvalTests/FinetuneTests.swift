import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

@Suite("Fine-tune pipeline guards and export (M7)")
struct FinetuneTests {
    @Test func sealedNamePrefixesMatchOnlyAtTheStartOfAPathComponent() {
        // A temp folder named by a UUID can hold "AB-" mid-name; it is not the sealed ab-* family.
        #expect(FinetunePathGuard.violation("/tmp/review-packet-test-9B91E6AB-AD3C-443D/synthetic.jsonl") == nil)
        #expect(FinetunePathGuard.violation("/tmp/x/ab-01.json") == "ab-")
        #expect(FinetunePathGuard.violation("ab-02.jsonl") == "ab-")
        #expect(FinetunePathGuard.violation("/tmp/runs/longb-3.jsonl") == "longb")
        #expect(FinetunePathGuard.violation("/tmp/Evals/eval-long64-b2.jsonl") == "eval-long64-b")
        #expect(FinetunePathGuard.violation("/tmp/y/runs/sealed/x.jsonl") == "runs/sealed")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("held-out, Voice Lab and app-data paths are refused")
    func refusesForbiddenPaths() {
        for path in [
            "Evals/heldout-v2.json", "Evals/heldout-v2-asr.json", "/x/Evals/actions-heldout-v1.json", "/data/VoiceLab/s1.json",
            "voice-lab/clip.json", NSHomeDirectory() + "/Library/Application Support/Hushy/history.sqlite",
            "Evals/data/external/disflqa-test.json", "/x/disfluencyspeech-test.json", "/y/disfl_qa/train.json",
            "Evals/negatives-fresh-dev.json",
            "Evals/ab-session.jsonl", "Evals/eval-long64-b1.jsonl", "Evals/longb-notes.jsonl",
            "Evals/runs/sealed/private.jsonl",
        ] {
            #expect(FinetunePathGuard.violation(path) != nil, "\(path)")
            #expect(throws: FinetunePathGuard.Refused.self) { try FinetunePathGuard.checked(path) }
        }
        #expect(FinetunePathGuard.violation("Evals/reformat-golden.json") == nil)
        #expect(FinetunePathGuard.violation("/tmp/ft/data/pairs.jsonl") == nil)
    }

    @Test("a symlink that resolves to a held-out file is refused")
    func refusesSymlinkedHeldout() throws {
        let dir = try tempDir()
        let target = dir.appendingPathComponent("heldout-v2.json")
        try "[]".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("innocent.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(FinetunePathGuard.violation(link.path) == "heldout")
        #expect(throws: FinetunePathGuard.Refused.self) { try FinetuneJSONL.read(link.path) }
    }

    @Test("JSONL round trip keeps unknown fields and never escapes slashes")
    func jsonlRoundTrip() throws {
        let path = try tempDir().appendingPathComponent("rows.jsonl").path
        try FinetuneJSONL.write([["id": "a", "raw": "either/or", "n": 3]], to: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("either/or"))
        let rows = try FinetuneJSONL.read(path)
        #expect(rows.count == 1 && rows[0]["n"] as? Int == 3)
    }

    @Test("prepare adds the rules draft and the guard verdict")
    func prepareRow() {
        let row = FinetuneRunner.prepareRow([
            "id": "x", "level": "clean", "raw": "we need twenty five chairs for the offsite", "target": "We need 25 chairs for the offsite.",
        ])
        #expect(row["draft"] as? String == "We need 25 chairs for the offsite.")
        #expect(row["rejection"] is NSNull)
        #expect(row["unchanged"] as? Bool == true)
        let missing = FinetuneRunner.prepareRow(["id": "y"])
        #expect(missing["rejection"] as? String == "missing raw/target")
        let grammarRow: FinetuneJSONL.Row = [
            "id": "g", "level": "clean", "raw": "the team have access", "target": "The team has access.",
        ]
        #expect(!(FinetuneRunner.prepareRow(grammarRow)["rejection"] is NSNull))
        #expect(FinetuneRunner.prepareRow(grammarRow, version: .v3)["rejection"] is NSNull)
    }

    @Test("export renders the compact prompt and the exact JSON answer")
    func exportExample() throws {
        let example = try #require(FinetuneExport.chatExample([
            "id": "p1", "level": "polished", "draft": "The files is ready.", "target": "The files are ready.",
        ]))
        let messages = try #require(example["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user", "assistant"])
        #expect(messages[0]["content"] == CompactCleanupPrompt.systemText(level: .polished))
        #expect(messages[1]["content"] == "Transcript: The files is ready.\nOutput:")
        #expect(messages[2]["content"] == #"{"text":"The files are ready."}"#)
        #expect(FinetuneExport.chatExample(["id": "p2", "level": "clean"]) == nil)
        let candidate = try #require(FinetuneExport.chatExample([
            "id": "g", "level": "clean", "draft": "The invoices is due.", "target": "The invoices are due.",
        ], version: .v3))
        let candidateMessages = try #require(candidate["messages"] as? [[String: String]])
        #expect(candidateMessages[0]["content"] == CompactCleanupPrompt.systemText(level: .clean, version: .v3))
    }
}
