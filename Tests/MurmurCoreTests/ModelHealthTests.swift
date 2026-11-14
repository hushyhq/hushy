import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// `ModelHealth` (2026-09-27, DECISIONS "Don't wait for a slow model"): a model that can't answer
/// in time is skipped at once instead of costing the user its whole budget.
@Suite("ModelHealth tracker")
struct ModelHealthTrackerTests {
    let start = ContinuousClock.now

    func at(_ ms: Int) -> ContinuousClock.Instant { start + .milliseconds(ms) }

    @Test("a fresh tracker calls the model")
    func freshCalls() {
        #expect(ModelHealth.Tracker().verdict(budgetMs: 2_400, now: at(0)) == .call)
    }

    @Test("one timeout is not enough; two in a row open the breaker; an answer closes it")
    func breaker() {
        var tracker = ModelHealth.Tracker()
        tracker.recordTimeout(budgetMs: 2_400)
        #expect(tracker.verdict(budgetMs: 2_400, now: at(0)) == .call)
        tracker.recordTimeout(budgetMs: 2_400)
        #expect(tracker.verdict(budgetMs: 2_400, now: at(0)) == .skip(.breakerOpen))
        tracker.recordAnswer()
        #expect(tracker.verdict(budgetMs: 2_400, now: at(0)) == .call)
    }

    @Test("a breaker opened by short-budget timeouts still lets a longer-budget call try")
    func breakerIsPerBudget() {
        var tracker = ModelHealth.Tracker()
        tracker.recordTimeout(budgetMs: 2_400)
        tracker.recordTimeout(budgetMs: 2_400)
        #expect(tracker.verdict(budgetMs: 2_400, now: at(0)) == .skip(.breakerOpen))
        #expect(tracker.verdict(budgetMs: 4_000, now: at(0)) == .call)
        tracker.recordTimeout(budgetMs: 4_000)
        #expect(tracker.verdict(budgetMs: 4_000, now: at(0)) == .skip(.breakerOpen))
    }

    @Test("an answer between timeouts resets the count")
    func answerResets() {
        var tracker = ModelHealth.Tracker()
        tracker.recordTimeout(budgetMs: 2_400)
        tracker.recordAnswer()
        tracker.recordTimeout(budgetMs: 2_400)
        #expect(tracker.verdict(budgetMs: 2_400, now: at(0)) == .call)
    }

    @Test("a probe slower than most of the budget skips the call; a fast one allows it")
    func probeLatency() {
        var slow = ModelHealth.Tracker()
        slow.startProbe(at: at(0), budgetMs: 2_400)
        slow.finishProbe(ms: 5_800, at: at(5_800))
        #expect(slow.verdict(budgetMs: 2_400, now: at(6_000)) == .skip(.skippedSlow))
        // Polished's 4 s budget is also out of reach at 5.8 s.
        #expect(slow.verdict(budgetMs: 4_000, now: at(6_000)) == .skip(.skippedSlow))

        var fast = ModelHealth.Tracker()
        fast.recordTimeout(budgetMs: 2_400)
        fast.recordTimeout(budgetMs: 2_400)
        fast.startProbe(at: at(0), budgetMs: 2_400)
        fast.finishProbe(ms: 1_300, at: at(1_300))
        #expect(fast.verdict(budgetMs: 2_400, now: at(1_400)) == .call)
    }

    @Test("a probe still running past most of the budget already says the model is slow")
    func inFlightProbe() {
        var tracker = ModelHealth.Tracker()
        tracker.recordTimeout(budgetMs: 2_400)
        tracker.startProbe(at: at(0), budgetMs: 2_400)
        #expect(tracker.verdict(budgetMs: 2_400, now: at(1_500)) == .call)
        #expect(tracker.verdict(budgetMs: 2_400, now: at(2_500)) == .skip(.skippedSlow))
    }

    @Test("slow evidence expires, so a stale probe never turns the model off for good")
    func slowEvidenceExpires() {
        var tracker = ModelHealth.Tracker()
        tracker.startProbe(at: at(0), budgetMs: 2_400)
        tracker.finishProbe(ms: 6_000, at: at(6_000))
        #expect(tracker.verdict(budgetMs: 2_400, now: at(30_000)) == .skip(.skippedSlow))
        #expect(tracker.verdict(budgetMs: 2_400, now: at(70_000)) == .call)
    }

    @Test("probes only when health is in doubt, one at a time, not back to back")
    func wantsProbe() {
        var tracker = ModelHealth.Tracker()
        #expect(!tracker.wantsProbe(budgetMs: 2_400, now: at(0)))
        tracker.recordTimeout(budgetMs: 2_400)
        #expect(tracker.wantsProbe(budgetMs: 2_400, now: at(0)))
        tracker.startProbe(at: at(0), budgetMs: 2_400)
        #expect(!tracker.wantsProbe(budgetMs: 2_400, now: at(100)))
        tracker.finishProbe(ms: 5_000, at: at(5_000))
        #expect(!tracker.wantsProbe(budgetMs: 2_400, now: at(6_000)))
        #expect(tracker.wantsProbe(budgetMs: 2_400, now: at(8_500)))
        tracker.startProbe(at: at(8_500), budgetMs: 2_400)
        tracker.finishProbe(ms: 1_000, at: at(9_500))
        #expect(!tracker.wantsProbe(budgetMs: 2_400, now: at(20_000)))
    }
}

/// End to end through `SmartCleaner` with a model whose speed the test controls.
@Suite("SmartCleaner health gate")
struct SmartCleanerHealthGateTests {
    let options = CleanupOptions(level: .polished)
    let draft = "so we should ship it on friday"

    /// Wide margins on both sides (a slow model is 4x the budget, a fast one 1/80th), so a busy
    /// test machine can't turn one into the other.
    static let budget: Duration = .milliseconds(400)

    /// The gate is off in the app (a slow model is retried, never switched off for a session), so
    /// these tests ask for it explicitly.
    func cleaner(_ model: PacedModel, health: ModelHealth, budget: Duration = Self.budget, gates: Bool = true) -> SmartCleaner {
        SmartCleaner(
            budget: budget, correctionBudget: budget, polishedBudget: budget, segmentBudget: budget,
            model: model, health: health, gatesOnHealth: gates)
    }

    /// For a model that answers at once: every limit is ten minutes, so a stalled or busy machine cannot turn
    /// its answer into a timeout. Only the tests of a slow model need the short budget above.
    func patientCleaner(_ model: PacedModel, health: ModelHealth) -> SmartCleaner {
        let limit: Duration = .seconds(600)
        return SmartCleaner(
            budget: limit, correctionBudget: limit, polishedBudget: limit, segmentBudget: limit,
            model: model, health: health, gatesOnHealth: true,
            dictationCeiling: limit, noProgressCeiling: limit, groupCeiling: limit)
    }

    func timed(_ cleaner: SmartCleaner, _ text: String) async -> (SmartCleaner.Output, Double) {
        let start = ContinuousClock.now
        let output = await cleaner.clean(text, options: options)
        return (output, ModelPace.ms(ContinuousClock.now - start))
    }

    func waitForProbe(_ health: ModelHealth) async {
        for _ in 0..<800 where health.isProbing {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("by default a slow model is never switched off: two dictations retry, later ones make one short attempt")
    func slowModelIsNeverSwitchedOff() async {
        let model = PacedModel(delay: .milliseconds(1_600))
        let health = ModelHealth()
        let cleaner = cleaner(model, health: health, gates: false)
        var traces: [GroupTrace] = []
        for _ in 0..<4 {
            let (output, _) = await timed(cleaner, draft)
            #expect(output.rejection == "timeout")
            #expect(output.groups.first?.outcome == .timeout)
            traces += output.groups
        }
        #expect(traces.prefix(2).allSatisfy { $0.retries == 1 && !$0.shortAttempt })
        #expect(traces.suffix(2).allSatisfy { $0.retries == 0 && $0.shortAttempt })
        #expect(!health.isProbing)
        // The model recovers and the very next dictation uses it.
        model.delay = .milliseconds(5)
        let (recovered, _) = await timed(cleaner, draft)
        #expect(recovered.usedModel)
    }

    @Test("a slow model costs two budgets, then dictations paste the rules text at once")
    func slowModelIsSkipped() async {
        let model = PacedModel(delay: .milliseconds(1_600))
        let health = ModelHealth()
        let cleaner = cleaner(model, health: health)
        let first = await timed(cleaner, draft)
        let second = await timed(cleaner, draft)
        #expect(first.0.rejection == "timeout")
        #expect(second.0.rejection == "timeout")
        #expect(first.1 >= 380)
        let third = await timed(cleaner, draft)
        #expect(third.0.rejection == "breaker-open")
        #expect(third.0.speedFallback)
        #expect(!third.0.usedModel)
        #expect(third.1 < 200)
        // The rules text is what a timeout would have pasted.
        #expect(third.0.text == first.0.text)
        #expect(health.isProbing)
        health.reset()
    }

    @Test("once a probe finds the model fast again, it is used again")
    func recovers() async {
        let model = PacedModel(delay: .milliseconds(1_600))
        let health = ModelHealth(probeIntervalSeconds: 0)
        let cleaner = cleaner(model, health: health)
        _ = await timed(cleaner, draft)
        _ = await timed(cleaner, draft)
        let skipped = await timed(cleaner, draft)
        #expect(skipped.0.rejection == "breaker-open")
        // That skip sent a probe while the model was still slow: it keeps the breaker open.
        await waitForProbe(health)
        model.delay = .milliseconds(5)
        let stillSkipped = await timed(cleaner, draft)
        #expect(stillSkipped.0.rejection == "breaker-open")
        // …and sent another probe, which finds the model fast.
        await waitForProbe(health)
        let recovered = await timed(cleaner, draft)
        #expect(recovered.0.usedModel)
        #expect(!recovered.0.speedFallback)
    }

    @Test("a fast model is never skipped: no quality lost when the Mac is idle")
    func fastModelAlwaysUsed() async {
        let model = PacedModel(delay: .milliseconds(5))
        let health = ModelHealth()
        let cleaner = patientCleaner(model, health: health)
        for _ in 0..<6 {
            let (output, _) = await timed(cleaner, draft)
            #expect(output.usedModel)
            #expect(output.rejection == nil)
        }
        #expect(!health.isProbing)
    }

    @Test("prewarm probes at key-down only while health is in doubt")
    func prewarmProbes() async {
        let model = PacedModel(delay: .milliseconds(1_600))
        let health = ModelHealth()
        let cleaner = cleaner(model, health: health)
        cleaner.prewarm()
        #expect(!health.isProbing)
        _ = await timed(cleaner, draft)
        cleaner.prewarm()
        #expect(health.isProbing)
        health.reset()
    }

    @Test("a fast model error is not a timeout and doesn't open the breaker")
    func errorIsNotTimeout() async {
        let model = PacedModel(delay: .milliseconds(5), fails: true)
        let health = ModelHealth()
        let cleaner = patientCleaner(model, health: health)
        for _ in 0..<3 {
            let (output, _) = await timed(cleaner, draft)
            #expect(output.rejection == "model error")
        }
        #expect(health.verdict(budget: .seconds(600)) == .call)
    }

    @Test("a busy system (memory pressure) is its own outcome and never opens the breaker")
    func busyIsNotTimeout() async {
        let model = PacedModel(delay: .milliseconds(5), failure: .busy("ModelManagerError#1013"))
        let health = ModelHealth()
        let cleaner = patientCleaner(model, health: health)
        for _ in 0..<3 {
            let (output, _) = await timed(cleaner, draft)
            #expect(output.rejection == "model busy")
            #expect(ModelOutcome(usedModel: false, rejection: output.rejection) == .modelBusy)
            #expect(output.speedFallback)
        }
        #expect(health.verdict(budget: .seconds(600)) == .call)
    }

    @Test("a content refusal is its own outcome and never opens the breaker")
    func refusalIsNotTimeout() async {
        // Classified from the error itself, not from how long the call took (before 2026-09-27
        // any failure after 95% of the budget counted as a timeout).
        let model = PacedModel(delay: .milliseconds(5), failure: .refused("guardrail"))
        let health = ModelHealth()
        let cleaner = patientCleaner(model, health: health)
        for _ in 0..<3 {
            let (output, _) = await timed(cleaner, draft)
            #expect(output.rejection == "model refused")
            #expect(ModelOutcome(usedModel: false, rejection: output.rejection) == .refused)
        }
        #expect(health.verdict(budget: .seconds(600)) == .call)
    }

    @Test("a probe that fails fast measures nothing: no skipped-slow for a minute")
    func failedProbeIsNoMeasurement() async throws {
        let health = ModelHealth(probeIntervalSeconds: 0)
        health.recordTimeout(budget: .seconds(2), elapsed: .seconds(2))
        let cleaner = cleaner(PacedModel(delay: .milliseconds(5), failure: .busy("1013")), health: health)
        cleaner.prewarm()
        for _ in 0..<200 where health.isProbing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!health.isProbing)
        #expect(health.verdict(budget: Self.budget) == .call)
    }
}

@Suite("ModelCallFailure")
struct ModelCallFailureTests {
    @Test("errors map to the failure that ModelHealth and the log need", arguments: [
        (LanguageModelError.busy("x"), ModelCallFailure.busy),
        (.refused("x"), .refused),
        (.unavailable("x"), .error),
        (.malformedOutput("x"), .malformed),
        (.unsupportedSchema("x"), .error),
    ] as [(LanguageModelError, ModelCallFailure)])
    func mapping(error: LanguageModelError, expected: ModelCallFailure) {
        #expect(ModelCallFailure(error) == expected)
    }

    @Test("the budget race reports timeout, busy and refusal distinctly")
    func race() async {
        func run(_ model: PacedModel, budget: Duration) async -> Result<SmartCleaner.Cleaned, ModelCallFailure> {
            await model.respondResult(
                instructions: "", prompt: "Transcript: x\nOutput:", generating: SmartCleaner.Cleaned.self,
                options: .greedy, budget: budget)
        }
        #expect(await run(PacedModel(delay: .seconds(2)), budget: .milliseconds(20)).failure == .timeout)
        #expect(await run(PacedModel(delay: .milliseconds(1), failure: .busy("1013")), budget: .seconds(2)).failure == .busy)
        #expect(await run(PacedModel(delay: .milliseconds(1), failure: .refused("g")), budget: .seconds(2)).failure == .refused)
        #expect(await run(PacedModel(delay: .milliseconds(1)), budget: .seconds(2)).failure == nil)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

@Suite("ModelOutcome")
struct ModelOutcomeTests {
    @Test("every rejection maps to one outcome", arguments: [
        (true, nil, ModelOutcome.used),
        (false, nil, .notAsked),
        (false, "skipped-slow", .skippedSlow),
        (false, "too long for model budget", .skippedSlow),
        (false, "breaker-open", .breakerOpen),
        (false, "timeout", .timeout),
        (false, "model error", .modelError),
        (false, "model busy", .modelBusy),
        (false, "model refused", .refused),
        (false, "release-window", .releaseWindow),
        (false, "prewarm-late", .prewarmLate),
        (false, "model unavailable", .unavailable),
        (false, "kept retracted item", .rejectedByGuard),
        (false, "ranked below rules", .rejectedByGuard),
    ] as [(Bool, String?, ModelOutcome)])
    func classify(usedModel: Bool, rejection: String?, expected: ModelOutcome) {
        #expect(ModelOutcome(usedModel: usedModel, rejection: rejection) == expected)
    }

    @Test("only a missing answer is a speed fallback — not a guard, not rules-only, not no model")
    func speedFallback() {
        let speed: Set<ModelOutcome> = [
            .skippedSlow, .breakerOpen, .timeout, .modelError, .modelBusy, .refused, .releaseWindow, .prewarmLate, .thermalSerious, .notResponding,
        ]
        for outcome in ModelOutcome.allCases {
            #expect(outcome.isSpeedFallback == speed.contains(outcome))
        }
        #expect(SmartCleaner.Output(text: "x", pressEnter: false, usedModel: false, rejection: "timeout").speedFallback)
        #expect(!SmartCleaner.Output(text: "x", pressEnter: false, usedModel: false, rejection: "kept retracted item").speedFallback)
    }

    @Test("log labels name the guard that rejected an answer")
    func logLabel() {
        #expect(ModelOutcome.logLabel(usedModel: false, rejection: "timeout") == "timeout")
        // Only the closed guard name is logged, never the words the reason may quote.
        #expect(ModelOutcome.logLabel(usedModel: false, rejection: "kept retracted item: off the dry cleaning")
                == "rejected-by-guard(kept-retracted-item)")
        #expect(ModelOutcome.logLabel(usedModel: true, rejection: nil) == "used")
    }
}

/// A model that answers with the draft, capitalized and full-stopped, after `delay`.
final class PacedModel: LanguageModel {
    private let state: Mutex<Duration>
    private let failure: LanguageModelError?

    /// `fails` throws a generic error; `failure` throws that error instead (after `delay`).
    init(delay: Duration, fails: Bool = false, failure: LanguageModelError? = nil) {
        state = Mutex(delay)
        self.failure = failure ?? (fails ? .malformedOutput("scripted failure") : nil)
    }

    var delay: Duration {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    var identifier: String { "paced" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        try await Task.sleep(for: delay)
        if let failure { throw failure }
        guard schema.name == SmartCleaner.Cleaned.generationSchema.name else {
            throw LanguageModelError.unsupportedSchema(schema.name)
        }
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
        let answer = draft.prefix(1).uppercased() + draft.dropFirst().replacingOccurrences(of: "friday", with: "Friday") + "."
        let data = try JSONEncoder().encode(["text": answer])
        return String(decoding: data, as: UTF8.self)
    }
}
