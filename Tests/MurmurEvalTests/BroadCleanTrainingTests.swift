import CryptoKit
import Foundation
import HushyModelsMLX
import MurmurCore
import Testing
@testable import murmur_eval

@Suite("Reviewed broad training provenance")
struct BroadCleanTrainingTests {
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

    @Test func exportedSystemIncludesExactRuntimeSchemaWrapper() throws {
        let context = GrammarProposalContext(protectedTerms: ["Riven"])
        let draft = "Riven carry the box."; let target = "Riven carries the box."
        let request = try GrammarEditProposalGenerator.wholeTextRequest(preparedDraft: draft, context: context)
        let example = try BroadCleanTraining.trainingExample(id: "system-parity", draft: draft, target: target, context: context)
        let messages = try #require(example["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user", "assistant"])
        #expect(messages[0]["content"] == MLXLanguageModel.systemText(instructions: request.instructions, schema: WholeGrammarProposal.generationSchema))
        #expect(messages[0]["content"] != request.instructions)
        #expect(messages[0]["content"]?.hasSuffix(WholeGrammarProposal.generationSchema.json.trimmingCharacters(in: .whitespacesAndNewlines)) == true)
        #expect(messages[1]["content"] == request.prompt)
        let answer = try JSONDecoder().decode(WholeGrammarProposal.self, from: Data(try #require(messages[2]["content"]).utf8))
        #expect(answer.text == target)
    }

    @Test func staleSourceReviewAndUnreviewedRowsAreRefused() throws {
        let row: [String: Any] = ["id": "review-boundary", "raw": "A lamp glow.", "target": "A lamp glows.",
            "level": "clean", "voiceCommandsEnabled": false, "isCodeContext": false, "protected": []]
        let source = try encode(row)
        let independent = try encode(["candidatesSHA256": "prior", "cases": [["id": "review-boundary", "status": "approved"]]])
        var ledger: [String: Any] = ["schema_version": 1, "candidatesSHA256": hash(source),
            "independentReviewSHA256": hash(independent), "independentCandidatesSHA256": "prior",
            "independentApprovedIDs": ["review-boundary"], "rootAdjudicatedIDs": [],
            "rootReviewedCurrentIDs": ["review-boundary"], "approvedRowSHA256": ["review-boundary": hash(source)]]
        #expect(try BroadCleanTraining.validatedRows(source: source, review: encode(ledger), independent: independent).count == 1)
        let mutated = Data(String(decoding: source, as: UTF8.self).replacingOccurrences(of: "glows", with: "shines").utf8)
        #expect(throws: (any Error).self) { try BroadCleanTraining.validatedRows(source: mutated, review: encode(ledger), independent: independent) }
        ledger["candidatesSHA256"] = hash(mutated)
        #expect(throws: (any Error).self) { try BroadCleanTraining.validatedRows(source: mutated, review: encode(ledger), independent: independent) }
        ledger["candidatesSHA256"] = hash(source)
        ledger["rootReviewedCurrentIDs"] = [String]()
        #expect(throws: (any Error).self) { try BroadCleanTraining.validatedRows(source: source, review: encode(ledger), independent: independent) }
    }
}
