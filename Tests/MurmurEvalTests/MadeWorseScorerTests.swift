import Foundation
import MurmurCore
import Testing
@testable import murmur_eval

@Test("filler removal alone does not count as made worse")
func fillerRemovalNotWorse() {
    let reference = "Meet Priya at noon."
    let before = "Meet Priya um at noon."
    let after = "Meet Priya at noon."
    let delta = MadeWorseScorer.transition(reference: reference, before: before, after: after)
    #expect(delta.worse == 0)
}

@Test("a correct word swapped for a wrong one counts as made worse at the step")
func soundAlikeRegression() {
    let reference = "Ship the Priya build tonight."
    let before = "Ship the Priya build tonight."
    let after = "Ship the piranha build tonight."
    let delta = MadeWorseScorer.transition(reference: reference, before: before, after: after)
    #expect(delta.worse >= 1)
}

@Test("score attributes transitions to the after step")
func perStepAttribution() {
    let reference = "Call Priya before five."
    let steps: [MadeWorseScorer.PipelineStep: String] = [
        .recognizer: "Call Priya before five.",
        .boosted: "Call Priya before five.",
        .fixers: "Call Priya before five.",
        .model: "Call piranha before five.",
        .checks: "Call piranha before five.",
    ]
    let scored = MadeWorseScorer.score(reference: reference, steps: steps)
    #expect(scored[.model]?.worse == 1)
    #expect(scored[.checks]?.worse == 0)
}
