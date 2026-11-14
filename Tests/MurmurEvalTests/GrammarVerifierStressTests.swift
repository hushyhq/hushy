import Foundation
import MurmurCore
import Testing
@testable import murmur_eval

@Suite("Grammar verifier stress input and training boundaries")
struct GrammarVerifierStressTests {
    private func input(verdict: String = "accept", duplicate: Bool = false, raw: String = "A child walk home.") throws -> Data {
        let row: [String: Any] = ["id": "synthetic-test", "raw": raw,
            "draft": "A child walk home.", "candidate": "A child walks home.",
            "expectedVerdict": verdict, "category": "agreement", "rationale": "Clear grammatical repair."]
        return try JSONSerialization.data(withJSONObject: ["schema_version": 1, "cases": duplicate ? [row, row] : [row]])
    }

    @Test func entireInputRejectsInvalidLabelsDuplicatesAndEmptyText() throws {
        #expect(try GrammarVerifierStressRunner.prepare(input()).count == 1)
        for data in [try input(verdict: "maybe"), try input(duplicate: true), try input(raw: " \n ")] {
            #expect(throws: (any Error).self) { try GrammarVerifierStressRunner.prepare(data) }
        }
    }

    @Test func acceptVerdictRequiresEveryPreservationFlag() throws {
        let data = Data(#"{"verdict":"accept","grammarImproved":true,"contentAndRolesPreserved":false,"timeQuantityPolarityModalityPreserved":true,"toneAndIntentPreserved":true,"noAmbiguityIntroduced":true}"#.utf8)
        let result = try JSONDecoder().decode(GeneralGrammarVerification.self, from: data)
        #expect(!result.explicitlyAccepts)
    }

    @Test func broadVersionsCannotPrepareOrExportUnreviewedTrainingTargets() throws {
        for profile in ["compact-v4", "compact-v4-polished-bridge"] {
            let prepare = Arguments(["finetune", "prepare", "--prompt-version", profile][...])
            let export = Arguments(["finetune", "export", "--prompt-version", profile][...])
            #expect(throws: (any Error).self) { try FinetuneRunner.prepare(prepare) }
            #expect(throws: (any Error).self) { try FinetuneExport.run(export) }
        }
        #expect(throws: Never.self) { try FinetuneRunner.requireExportableVersion(.v2) }
        #expect(throws: Never.self) { try FinetuneRunner.requireExportableVersion(.v3) }
    }

    @Test func broadProfilesInferContractAndRejectLegacyMismatch() throws {
        for profile in ["compact-v4", "compact-v4-polished-bridge"] {
            let args = Arguments(["cleanup-trace", "--backend", "mlx", "--mlx-prompt", profile][...])
            #expect(try args.cleanGrammarContract() == .generalMinimal)
            let mismatch = Arguments(["cleanup-trace", "--backend", "mlx", "--mlx-prompt", profile, "--clean-grammar-contract", "legacy"][...])
            #expect(throws: (any Error).self) { try mismatch.cleanGrammarContract() }
        }
        for backend in ["apple", "none", "local"] {
            let args = Arguments(["cleanup", "--backend", backend, "--mlx-prompt", "compact-v4"][...])
            #expect(throws: (any Error).self) { try args.cleanGrammarContract() }
        }
        let local = Arguments(["cleanup", "--backend", "local", "--clean-grammar-contract", "general-minimal"][...])
        #expect(throws: (any Error).self) { try local.cleanGrammarContract() }
    }
}
