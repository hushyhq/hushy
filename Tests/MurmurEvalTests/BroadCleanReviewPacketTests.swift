import CryptoKit
import Foundation
import HushyModelsMLX
import MurmurCore
import Testing
@testable import murmur_eval

@Suite("Broad Clean runtime review packet")
struct BroadCleanReviewPacketTests {
    private func candidate() -> [String: Any] {
        ["id": "synthetic-review", "raw": "A lantern glow.", "target": "A lantern glows.",
         "level": "clean", "voiceCommandsEnabled": false, "isCodeContext": false,
         "protected": [String](), "context": "Author imagined a story.", "rationale": "Synthetic grammar repair."]
    }
    private func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func record(_ row: [String: Any]) throws -> [String: Any] {
        let packet = try BroadCleanReviewPacket.render(source: encode(row))
        return try #require((packet["rows"] as? [[String: Any]])?.first)
    }
    private func input(_ row: [String: Any]) throws -> [String: Any] {
        try #require(record(row)["modelObservableInput"] as? [String: Any])
    }

    @Test func authorOnlyContextDoesNotChangeRequest() throws {
        let original = candidate()
        var changed = original
        changed["context"] = "A different imagined setting."
        changed["rationale"] = "Different author reasoning."
        let before = try record(original); let after = try record(changed)
        #expect(try encode(input(original)) == encode(input(changed)))
        #expect(before["candidateRowSHA256"] as? String != after["candidateRowSHA256"] as? String)
        let annotations = try #require(after["annotationMetadataNotModelInput"] as? [String: Any])
        #expect(annotations["context"] as? String == changed["context"] as? String)
        #expect(annotations["rationale"] as? String == changed["rationale"] as? String)
        #expect(after["approvalStatus"] == nil)
    }

    @Test func supportedContextChangesActualRequest() throws {
        let original = candidate()
        let baseline = try encode(input(original))
        for (key, value) in [("isCodeContext", true as Any), ("detectedLanguage", "es" as Any),
                             ("protected", ["lantern"] as Any)] {
            var changed = original; changed[key] = value
            #expect(try encode(input(changed)) != baseline)
        }
        let context = try #require(input(original)["grammarProposalContext"] as? [String: Any])
        #expect(Set(context.keys) == ["isCodeContext", "detectedLanguage", "protectedTerms"])
    }

    @Test func exactPreparedTargetAndMLXWrapperMatchExporter() throws {
        var row = candidate()
        row["target"] = "A lantern   glows."
        let rendered = try record(row)
        let prepared = try BroadCleanTraining.prepare(raw: "A lantern glow.", target: "A lantern   glows.",
            terms: [], code: false, voice: false, language: nil)
        #expect(rendered["preparedDraft"] as? String == prepared.draft)
        #expect(rendered["preparedTarget"] as? String == prepared.target)
        #expect(rendered["targetChangedByPreparation"] as? Bool == true)
        #expect(rendered["preparedTargetSHA256"] as? String == SHA256.hash(data: Data(prepared.target.utf8))
            .map { String(format: "%02x", $0) }.joined())
        #expect(rendered["originalTarget"] as? String == "A lantern   glows.")
        let example = try BroadCleanTraining.trainingExample(id: "synthetic-review", draft: prepared.draft,
            target: prepared.target, context: prepared.context)
        let messages = try #require(example["messages"] as? [[String: String]])
        let observable = try input(row)
        #expect(observable["mlxSystemMessage"] as? String == messages[0]["content"])
        #expect(observable["prompt"] as? String == messages[1]["content"])
        let request = try GrammarEditProposalGenerator.wholeTextRequest(preparedDraft: prepared.draft, context: prepared.context)
        #expect(observable["instructions"] as? String == request.instructions)
        #expect(observable["mlxSystemMessage"] as? String == MLXLanguageModel.systemText(
            instructions: request.instructions, schema: WholeGrammarProposal.generationSchema))
        let answer = try JSONDecoder().decode(WholeGrammarProposal.self, from: Data(try #require(messages[2]["content"]).utf8))
        #expect(answer.text == prepared.target)
        let hashes = try #require(rendered["renderedSHA256"] as? [String: String])
        #expect(hashes["outputSchema"] == SHA256.hash(data: Data(WholeGrammarProposal.generationSchema.json.utf8))
            .map { String(format: "%02x", $0) }.joined())
    }

    @Test func hardVetoIsVisibleWithoutApprovingCandidate() throws {
        var row = candidate(); row["isCodeContext"] = true
        let rendered = try record(row)
        #expect(rendered["hardViolation"] as? String == "code context must remain byte-identical")
        #expect(rendered["approvalStatus"] == nil)
    }

    @Test func malformedAndDuplicateRowsAreRefused() throws {
        for (key, value) in [("level", "polished" as Any), ("protected", "lantern" as Any),
                             ("detectedLanguage", 4 as Any), ("isCodeContext", 1 as Any),
                             ("voiceCommandsEnabled", 0 as Any), ("raw", "" as Any)] {
            var row = candidate(); row[key] = value
            #expect(throws: (any Error).self) { try record(row) }
        }
        let rowData = try encode(candidate())
        var duplicate = rowData; duplicate.append(Data("\n".utf8)); duplicate.append(rowData)
        #expect(throws: (any Error).self) { try BroadCleanReviewPacket.render(source: duplicate) }
        for data in [Data(), Data("[]".utf8), Data("not JSON".utf8), Data([0xff])] {
            #expect(throws: (any Error).self) { try BroadCleanReviewPacket.render(source: data) }
        }
    }

    @Test func pathGuardsAndOverwriteRefusal() throws {
        #expect(throws: (any Error).self) { try BroadCleanReviewPacket.checkedOutput(".build/review.json") }
        #expect(throws: (any Error).self) { try BroadCleanReviewPacket.checkedOutput(".build/finetune/heldout-review.json") }
        #expect(throws: (any Error).self) {
            try BroadCleanReviewPacket.write(input: "Evals/heldout-v2-synthetic.jsonl", output: ".build/finetune/synthetic.json")
        }
        let directory = URL(fileURLWithPath: ".build/finetune/review-packet-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic.jsonl")
        let output = directory.appendingPathComponent("packet.json")
        try encode(candidate()).write(to: source)
        try BroadCleanReviewPacket.write(input: source.path, output: output.path)
        let original = try Data(contentsOf: output)
        #expect(throws: (any Error).self) { try BroadCleanReviewPacket.write(input: source.path, output: output.path) }
        #expect(try Data(contentsOf: output) == original)
        let malformed = directory.appendingPathComponent("malformed.jsonl")
        try Data("[]".utf8).write(to: malformed)
        let refused = directory.appendingPathComponent("refused.json")
        #expect(throws: (any Error).self) { try BroadCleanReviewPacket.write(input: malformed.path, output: refused.path) }
        #expect(!FileManager.default.fileExists(atPath: refused.path))
        let escape = directory.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(throws: (any Error).self) { try BroadCleanReviewPacket.checkedOutput(escape.appendingPathComponent("packet.json").path) }
        #expect(throws: (any Error).self) {
            try BroadCleanReviewPacket.checkedOutput(escape.appendingPathComponent("absent/subdir/packet.json").path)
        }
        let dangling = directory.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling,
            withDestinationURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        #expect(throws: (any Error).self) {
            try BroadCleanReviewPacket.checkedOutput(dangling.appendingPathComponent("packet.json").path)
        }
        let nested = directory.appendingPathComponent("new/subdir/packet.json")
        #expect(try BroadCleanReviewPacket.checkedOutput(nested.path).path == nested.standardizedFileURL.path)
    }
}
