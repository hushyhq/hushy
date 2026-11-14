import Foundation
import Testing
@testable import murmur_eval

@Suite("Paired grammar proposal preflight")
struct GrammarProposalRunnerTests {
    private func fixture(expectation: String = "repair", duplicate: Bool = false) throws -> Data {
        let row: [String: Any] = ["id": "synthetic-preflight", "raw": "A bird sing.",
            "reference": "A bird sings.", "alternatives": [], "expectation": expectation,
            "category": "agreement", "protectedTerms": [], "isCodeContext": false,
            "isCasualContext": false, "voiceCommandsEnabled": false]
        return try JSONSerialization.data(withJSONObject: ["schema_version": 1, "cases": duplicate ? [row, row] : [row]])
    }
    @Test func validatesAllRowsBeforeInference() throws {
        #expect(try GrammarProposalRunner.prepare(fixture()).count == 1)
        for input in [try fixture(expectation: "unknown"), try fixture(duplicate: true)] {
            #expect(throws: (any Error).self) { try GrammarProposalRunner.prepare(input) }
        }
    }
    @Test func rejectsHiddenAdapterAndUnspecifiedPromptBeforeLoadingInput() async {
        let args = Arguments(["grammar-proposal", "--backend", "mlx", "--arm", "text"][...])
        await #expect(throws: (any Error).self) { try await GrammarProposalRunner.run(args) }
    }
}
