import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// An explicit action's patience: a probe that timed out is a timeout, the whole extraction has
/// one deadline, and a lead-in word never changes which installed app is meant.
@Suite("Explicit action limits")
struct ActionExplicitLimitsTests {
    static let context = DateContext(
        now: ProposalFields.parseISO8601("2026-10-07T14:40:00-07:00")!, timeZone: TimeZone(identifier: "America/Los_Angeles")!)

    private final class Model: LanguageModel, @unchecked Sendable {
        let json: String?
        init(json: String?) { self.json = json }
        var identifier: String { "limits" }
        var availability: LanguageModelAvailability { .available }
        func supportsLanguage(_ languageCode: String) -> Bool { true }
        func prewarm(instructions: String) {}
        func prefixCache(instructions: String) async {}
        func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
            guard let json else {
                try await Task.sleep(for: .seconds(60))
                return "{}"
            }
            return json
        }
    }

    @Test("a probe that times out is a timeout: it never closes the breaker, even under a longer call budget")
    func timedOutProbeKeepsBreakerOpen() async {
        let health = ModelHealth(probeIntervalSeconds: 0)
        let extractor = ActionExtractor(
            budget: .milliseconds(150), model: Model(json: nil), health: health, probeBudget: .milliseconds(40))
        let ask = "remind me to water the plants tomorrow"
        _ = await extractor.extract(ask, context: Self.context)
        _ = await extractor.extract(ask, context: Self.context)
        let skipped = await extractor.extract(ask, context: Self.context)
        #expect(skipped.result == .rejected("skipped: breaker-open"))
        for _ in 0..<200 where health.isProbing { try? await Task.sleep(for: .milliseconds(10)) }
        let after = await extractor.extract(ask, context: Self.context)
        guard case .rejected(let reason) = after.result, reason.hasPrefix("skipped") else {
            Issue.record("a probe that timed out must leave the model skipped, got \(after.result)")
            return
        }
    }

    @Test("the whole extraction has one deadline, the Shortcuts listing included")
    func overallDeadline() async {
        let json = """
        {"speech": "askingYou", "actions": [{"kind": "runShortcut", "title": "morning routine", "when": "", "durationMinutes": 0, \
        "listOrCalendarName": "", "location": "", "shortcutInput": ""}]}
        """
        let extractor = ActionExtractor(
            budget: .seconds(2), model: Model(json: json),
            shortcutLibrary: {
                try? await Task.sleep(for: .seconds(120))
                return ["Morning Routine"]
            },
            health: ModelHealth(), deadline: .milliseconds(200))
        // The listing takes two minutes and the deadline is 200 ms, so waiting for the listing would
        // take 120 s. Half of that cannot be reached by a busy machine, and SuspendingClock does not
        // count time the Mac spent asleep.
        let clock = SuspendingClock()
        let started = clock.now
        let output = await extractor.extract("run my morning routine shortcut", context: Self.context)
        #expect(clock.now - started < .seconds(60), "the pill must not sit on Working… for the listing's own time-out")
        #expect(output.result == .rejected("timeout"))
    }

    @Test("an explicit extractor has the 12 second overall deadline")
    func explicitDeadline() {
        #expect(ActionExtractor.explicitDeadline == .seconds(12))
        #expect(ActionExtractor.explicit(model: NullLanguageModel()).deadline == ActionExtractor.explicitDeadline)
    }

    @Test("a lead-in word before an installed app's name never changes which app is meant")
    func leadInsAndRealNames() {
        let apps = ["Slack", "Quick Look", "Just Press Record", "HEY", "Safari", "Hush Notes"].map { AppNameMatcher.Candidate(name: $0) }
        func best(_ spoken: String) -> String? { AppNameMatcher.best(spoken: spoken, among: apps)?.name }
        // A real name wins exactly, even when it opens with a word that is a lead-in elsewhere.
        #expect(best("Quick Look") == "Quick Look")
        #expect(best("just press record") == "Just Press Record")
        #expect(best("hey") == "HEY")
        // A filler or polite lead-in in front of a name is dropped.
        #expect(best("um Slack") == "Slack")
        #expect(best("uh, please slack") == "Slack")
        #expect(best("okay so safari") == "Safari")
        #expect(best("um quick look") == "Quick Look")
    }
}

@Suite("Explicit action limits, round three")
struct ActionExplicitLimitsRoundThreeTests {
    private final class Model: LanguageModel, @unchecked Sendable {
        let json: String
        init(json: String) { self.json = json }
        var identifier: String { "round3" }
        var availability: LanguageModelAvailability { .available }
        func supportsLanguage(_ languageCode: String) -> Bool { true }
        func prewarm(instructions: String) {}
        func prefixCache(instructions: String) async {}
        func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String { json }
    }

    private static let shortcutJSON = """
        {"speech": "askingYou", "actions": [{"kind": "runShortcut", "title": "morning routine", "when": "", "durationMinutes": 0, \
        "listOrCalendarName": "", "location": "", "shortcutInput": ""}]}
        """

    @Test("the whole phrase is matched at every level before a lead-in is ever dropped")
    func wholePhraseFirst() {
        func best(_ spoken: String, _ names: [String]) -> String? {
            AppNameMatcher.best(spoken: spoken, among: names.map { AppNameMatcher.Candidate(name: $0) })?.name
        }
        // "quick look" is the start of Quick Look Pro; the bare "look" is another, exactly-named app.
        #expect(best("quick look", ["Quick Look Pro", "Look"]) == "Quick Look Pro")
        #expect(best("quick look", ["Quick Look Pro", "Look Pro"]) == "Quick Look Pro")
        // A lead-in is still dropped when nothing matches the whole phrase.
        #expect(best("um slack", ["Slack", "Quick Look Pro"]) == "Slack")
        #expect(best("uh, please safari", ["Safari", "Look"]) == "Safari")
    }

    @Test("only a real timeout is a probe timeout: an error that arrives late is not")
    func lateErrorIsNotATimeout() {
        let budget = Duration.milliseconds(1_000)
        #expect(ActionExtractor.probeResult(Result<Int, ModelCallFailure>.failure(.timeout), elapsed: budget, budget: budget) != nil)
        if case .timedOut? = ActionExtractor.probeResult(Result<Int, ModelCallFailure>.failure(.timeout), elapsed: budget, budget: budget) {} else {
            Issue.record("a real timeout must be .timedOut")
        }
        for failure in [ModelCallFailure.error, .busy, .refused, .cancelled, .notResponding] {
            #expect(ActionExtractor.probeResult(Result<Int, ModelCallFailure>.failure(failure), elapsed: .milliseconds(990), budget: budget) == nil,
                    "\(failure) at 99% of the budget measures nothing")
        }
        if case .answered(let ms)? = ActionExtractor.probeResult(Result<Int, ModelCallFailure>.success(1), elapsed: .milliseconds(300), budget: budget) {
            #expect(ms == 300)
        } else {
            Issue.record("an answer is a measurement")
        }
    }

    @Test("Esc during the Shortcuts wait returns at once, not when the timer or the listing ends")
    func cancellationReturnsAtOnce() async {
        let extractor = ActionExtractor(
            budget: .seconds(2), model: Model(json: Self.shortcutJSON),
            shortcutLibrary: {
                try? await Task.sleep(for: .seconds(120))
                return ["Morning Routine"]
            },
            health: ModelHealth(), deadline: .seconds(30))
        let context = ActionExplicitLimitsTests.context
        let task = Task { await extractor.extract("run my morning routine shortcut", context: context) }
        try? await Task.sleep(for: .milliseconds(200))
        let cancelled = ContinuousClock.now
        task.cancel()
        _ = await task.value
        #expect(ContinuousClock.now - cancelled < .seconds(1), "a cancelled extraction must not stay suspended")
    }

    @Test("with no time left the answer is the timeout, even if the listing is ready")
    func zeroRemainingIsTimeout() async {
        let extractor = ActionExtractor(
            budget: .seconds(2), model: Model(json: Self.shortcutJSON),
            shortcutLibrary: { ["Morning Routine"] }, health: ModelHealth(), deadline: .zero)
        let output = await extractor.extract("run my morning routine shortcut", context: ActionExplicitLimitsTests.context)
        #expect(output.result == .rejected("timeout"))
    }
}
