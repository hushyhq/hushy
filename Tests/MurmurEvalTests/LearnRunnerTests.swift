import Foundation
import MurmurCore
import Testing
@testable import murmur_eval

@Suite("murmur-eval learn")
struct LearnRunnerTests {
    private let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: SmartCleaner(model: NullLanguageModel()))

    @Test("every adversarial scenario teaches nothing active, in both modes")
    func adversarialHasNoFalseLearns() throws {
        for mode in LearnRunner.Mode.allCases {
            for scenario in LearnFixtures.adversarial {
                let result = try LearnRunner.runScenario(scenario, policy: mode.policy, pipeline: pipeline)
                #expect(result.activated.isEmpty, "\(mode.rawValue) \(scenario.name) activated \(result.activated)")
            }
        }
    }

    @Test("suggest-only: one verified Pria spelling fix is ready and activates on confirm")
    func suggestOnlyLearnsPriya() async throws {
        let store = try Store()
        var nextID: Int64 = 1
        let term = try #require(LearnFixtures.terms.first { $0.term == "Priya" })
        let result = try await LearnRunner.learn(term, mode: .suggestOnly, store: store, pipeline: pipeline, nextID: &nextID)
        #expect(result.editsToLearn == 1)
        #expect(!result.activatedSilently)
        #expect(try store.learnedItems().first?.confirmed == true)
        let personalizer = LearnedPersonalization.personalizer(dictionary: [], snippets: [], learned: try store.learnedItems())
        let text = await LearnRunner.clean("Let's set up a call with Pria on Thursday.", personalizer: personalizer, pipeline: pipeline)
        #expect(text.contains("Priya"))
    }

    @Test("auto-activate: one verified Pria spelling fix activates without confirm")
    func autoLearnsPriya() async throws {
        let store = try Store()
        var nextID: Int64 = 1
        let term = try #require(LearnFixtures.terms.first { $0.term == "Priya" })
        let result = try await LearnRunner.learn(term, mode: .autoActivate, store: store, pipeline: pipeline, nextID: &nextID)
        #expect(result.editsToLearn == 1)
        #expect(result.activatedSilently)
    }
}

@Suite("murmur-eval learn · short dictations")
struct LearnShortRunnerTests {
    private let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: SmartCleaner(model: NullLanguageModel()))

    @Test("no short adversarial scenario teaches anything active, in both modes")
    func shortAdversarialHasNoFalseLearns() throws {
        for mode in LearnRunner.Mode.allCases {
            for scenario in LearnShortFixtures.adversarial {
                let result = try LearnRunner.runShortScenario(scenario, policy: mode.policy)
                #expect(result.activated.isEmpty, "\(mode.rawValue) \(scenario.name) activated \(result.activated)")
            }
        }
    }

    @Test("a fix that was never repeated stays a candidate, and the real fixes do reach the store")
    func onceOnlyIsCandidate() throws {
        let once = try #require(LearnShortFixtures.adversarial.first { $0.name == "once-only" })
        let result = try LearnRunner.runShortScenario(once, policy: LearningPolicy(autoActivateTerms: true))
        #expect(result.activated.isEmpty)
        #expect(result.candidates == ["Priya"])
    }

    @Test("a short Priya fix is learned after the second dictation, never after the first")
    func learnsPriyaFromShortDictations() async throws {
        let term = try #require(LearnFixtures.terms.first { $0.term == "Priya" })
        var nextID: Int64 = 1
        let result = try await LearnRunner.learnShort(
            term, mode: .autoActivate, store: try Store(), pipeline: pipeline, nextID: &nextID)
        #expect(result.fixesToLearn == 2)
        #expect(result.legacyCaptures == 0)
    }

    @Test("a term the recognizer split into two words is not learned from a short dictation")
    func splitTermIsAKnownLimit() async throws {
        let term = try #require(LearnFixtures.terms.first { $0.term == "kubectl" })
        var nextID: Int64 = 1
        let result = try await LearnRunner.learnShort(
            term, mode: .autoActivate, store: try Store(), pipeline: pipeline, nextID: &nextID)
        #expect(result.fixesToLearn == nil)
    }
}
