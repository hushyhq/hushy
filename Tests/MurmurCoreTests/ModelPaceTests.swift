import Testing
@testable import MurmurCore

@Suite("ModelPace")
struct ModelPaceTests {
    @Test("short drafts fit the budget, long monologues don't")
    func initialEstimate() {
        let pace = ModelPace.Estimator()
        #expect(pace.fits(words: 12, budgetMs: 1_200))
        #expect(!pace.fits(words: 150, budgetMs: 2_000))
    }

    @Test("a timeout raises the estimate so the same length is skipped next time")
    func timeoutRaises() {
        var pace = ModelPace.Estimator()
        #expect(pace.fits(words: 25, budgetMs: 2_000))
        pace.recordTimeout(words: 25, budgetMs: 2_000)
        #expect(!pace.fits(words: 25, budgetMs: 2_000))
    }

    @Test("fast successes bring the estimate back down")
    func successLowers() {
        var pace = ModelPace.Estimator()
        pace.recordTimeout(words: 10, budgetMs: 2_000)
        #expect(!pace.fits(words: 28, budgetMs: 1_200))
        for _ in 0..<10 { pace.recordSuccess(words: 30, elapsedMs: 900) }
        #expect(pace.fits(words: 28, budgetMs: 2_000))
    }

    @Test("short drafts are always tried, even after a run of timeouts")
    func shortAlwaysTried() {
        var pace = ModelPace.Estimator()
        for _ in 0..<20 { pace.recordTimeout(words: 5, budgetMs: 2_000) }
        #expect(pace.fits(words: 20, budgetMs: 1_200))
    }

    @Test("skipping relaxes an inflated estimate so the model gets tried again")
    func skipsRecover() {
        var pace = ModelPace.Estimator()
        pace.recordTimeout(words: 5, budgetMs: 2_000)
        #expect(!pace.fits(words: 25, budgetMs: 2_000))
        for _ in 0..<20 { pace.recordSkip() }
        #expect(pace.fits(words: 25, budgetMs: 2_000))
    }
}
