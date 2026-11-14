import Testing

@testable import murmur_eval

@Suite("Grammar runner prompt experiment")
struct GrammarRunnerTests {
    @Test func experimentIsOptInAndRequiresDirectMLX() throws {
        #expect(try GrammarRunner.experimentProfile(Arguments(["grammar"][...])) == nil)
        #expect(try GrammarRunner.experimentProfile(
            Arguments(["grammar", "--backend", "mlx", "--polished-experiment", "agreement-v1"][...])) == "agreement-v1")
        #expect(throws: (any Error).self) {
            try GrammarRunner.experimentProfile(Arguments(["grammar", "--polished-experiment", "unknown"][...]))
        }
        #expect(throws: (any Error).self) {
            try GrammarRunner.experimentProfile(
                Arguments(["grammar", "--backend", "none", "--polished-experiment", "agreement-v1"][...]))
        }
        #expect(throws: (any Error).self) {
            try GrammarRunner.experimentProfile(Arguments(["grammar", "--polished-experiment"][...]))
        }
    }
}
