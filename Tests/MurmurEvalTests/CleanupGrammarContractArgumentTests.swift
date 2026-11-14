import MurmurCore
import Testing

@testable import murmur_eval

@Suite("Cleanup grammar contract arguments")
struct CleanupGrammarContractArgumentTests {
    @Test func defaultsStayLegacyAndCompactV3SelectsMinimal() throws {
        let baseline = Arguments(["cleanup"][...])
        #expect(try baseline.cleanGrammarContract() == .legacy)
        #expect(try baseline.cleanupOptions(level: .clean).grammarContract == .legacy)

        let candidate = Arguments(["grammar", "--backend", "mlx", "--mlx-prompt", "compact-v3"][...])
        #expect(try candidate.cleanGrammarContract() == .minimal)
        #expect(try candidate.cleanupOptions(level: .clean).grammarContract == .minimal)
    }

    @Test func explicitContractCanSelectProductionCandidateAndRejectContradictions() throws {
        let productionCandidate = Arguments([
            "grammar", "--clean-grammar-contract", "minimal",
        ][...])
        #expect(try productionCandidate.cleanGrammarContract() == .minimal)

        let explicitLegacyCompactV3 = Arguments([
            "cleanup", "--backend", "mlx", "--mlx-prompt", "compact-v3", "--clean-grammar-contract", "legacy",
        ][...])
        #expect(throws: (any Error).self) { try explicitLegacyCompactV3.cleanGrammarContract() }

        let unknown = Arguments(["try", "--clean-grammar-contract", "broad"][...])
        #expect(throws: (any Error).self) { try unknown.cleanGrammarContract() }

        let missingValue = Arguments(["cleanup", "--clean-grammar-contract"][...])
        #expect(throws: (any Error).self) { try missingValue.cleanGrammarContract() }

        let invalidPrompt = Arguments(["cleanup", "--backend", "mlx", "--mlx-prompt", "compact-v9"][...])
        #expect(throws: (any Error).self) { try invalidPrompt.cleanGrammarContract() }
    }

    @Test func sharedOptionsCarryContextAndResolvedContract() throws {
        let args = Arguments([
            "cleanup", "--backend", "mlx", "--mlx-prompt", "compact-v3", "--code-context", "--casual-context", "--language", "en-US",
        ][...])
        let options = try args.cleanupOptions(level: .clean)
        #expect(options.grammarContract == .minimal)
        #expect(options.isCodeContext)
        #expect(options.isCasualContext)
        #expect(options.detectedLanguage == "en-US")
    }
}
