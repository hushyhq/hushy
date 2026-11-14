import Testing
@testable import MurmurCore

@Suite("Eval layout scoring")
struct EvalLayoutTests {
    @Test func detectsLostLineAndParagraphBreaks() {
        #expect(!EvalMetrics.layoutMatches("Hi Sam\nThanks", "Hi Sam Thanks"))
        #expect(!EvalMetrics.layoutMatches("Intro\n\nPricing", "Intro\nPricing"))
        #expect(EvalMetrics.layoutMatches("Hi Sam\nThanks!", "hi sam\r\nthanks."))
    }

    @Test func detectsWrongListStructure() {
        #expect(!EvalMetrics.layoutMatches("- Milk\n- Eggs", "1. Milk\n2. Eggs"))
        #expect(!EvalMetrics.layoutMatches("- Milk and bread\n- Eggs", "- Milk\n- And bread eggs"))
        #expect(EvalMetrics.layoutMatches("- Milk\n- Eggs", "• milk\n• eggs"))
    }
}
