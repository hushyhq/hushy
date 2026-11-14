import Foundation
import MurmurCore
import Testing
@testable import murmur_eval

@Suite("murmur-eval learn-timelines")
struct LearnTimelinesTests {
    private func rate(_ name: String, _ policy: LearningPolicy, trials: Int = 400) -> Double {
        let scenario = LearnTimelines.scenarios.first { $0.name == name }!
        return Double(LearnTimelines.simulate(scenario, policy: policy, trials: trials, seed: 11).learned) / Double(trials)
    }

    @Test("a word changed 1 time in 7 is learned by the earlier rule in most timelines and by the evidence rule in almost none")
    func ambiguousWord() {
        let name = "ambiguous word, changed 1 time in 7"
        #expect(rate(name, .editsOnly) > 0.4)
        #expect(rate(name, .standard) < 0.08)
    }

    @Test("a consistent fix is learned as often as before, and a one-off change never")
    func trueFixesStay() {
        let often = "consistent fix, said often"
        #expect(rate(often, .standard) >= 0.99 && rate(often, .editsOnly) >= 0.99)
        let rare = "consistent fix, said every 25 days"
        #expect(rate(rare, .standard) >= rate(rare, .editsOnly) - 0.05)
        #expect(rate("one-off change", .standard) == 0 && rate("one-off change", .editsOnly) == 0)
    }

    @Test("a word wanted in Mail and never in Slack ends up applied in Slack far less often")
    func backoff() throws {
        let scenario = try #require(LearnTimelines.scenarios.first { $0.name == "wanted in Mail, never in Slack" })
        let earlier = LearnTimelines.simulate(scenario, policy: .editsOnly, trials: 300, seed: 5)
        let evidence = LearnTimelines.simulate(scenario, policy: .standard, trials: 300, seed: 5)
        #expect(evidence.wrongApplications * 2 < earlier.wrongApplications)
        #expect(evidence.scopes.keys.contains { $0.hasPrefix("category:") || $0.hasPrefix("app:") })
    }
}
