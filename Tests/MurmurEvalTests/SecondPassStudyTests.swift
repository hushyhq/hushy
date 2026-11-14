import Foundation
import MurmurCore
import Synchronization
import Testing

@testable import murmur_eval

/// The pieces of `murmur-eval second-pass` that decide what a number means: the category a group's second pass is
/// counted under, and the tape that replays a live run's answers. No model: every answer here is scripted.
@Suite("Second pass study")
struct SecondPassStudyTests {
    private func trace(
        outcome: ModelOutcome = .used, pass: SecondPass, second: ModelOutcome? = nil, first: String? = nil, answer: String? = nil
    ) -> GroupTrace {
        var trace = GroupTrace(words: 12, outcome: outcome, guardCode: nil, edited: true, modelMs: 300, secondPass: pass)
        trace.measured.secondPassOutcome = second
        trace.measured.firstPassText = first
        trace.measured.secondPassAnswer = answer
        return trace
    }

    @Test("a group whose first pass leaves nothing the trigger looks for is not triggered")
    func cleanTextIsNotTriggered() {
        let verdict = SecondPassRecords.fate(of: trace(pass: .none, first: "We could hide the sidebar for new users."))
        #expect(verdict.triggered == false)
        #expect(verdict.fate == .notTriggered)
    }

    @Test("leftover filler with no second call is counted apart: the model was not there, or the first pass had no answer")
    func triggeredButNotAsked() {
        let text = "We could like hide the sidebar for new users and move the menu up front."
        #expect(SecondPassRecords.fate(of: trace(pass: .none, first: text)).fate == .unavailable)
        #expect(SecondPassRecords.fate(of: trace(outcome: .timeout, pass: .none, first: text)).fate == .firstPassHadNoAnswer)
    }

    @Test("each way a second call can end has its own category")
    func fatesOfASecondCall() {
        let first = "We could like hide the sidebar."
        #expect(SecondPassRecords.fate(of: trace(pass: .used, second: .used, first: first, answer: "We could hide the sidebar.")).fate == .accepted)
        #expect(SecondPassRecords.fate(of: trace(pass: .kept, second: .used, first: first, answer: first)).fate == .unchanged)
        #expect(SecondPassRecords.fate(of: trace(pass: .kept, second: .rejectedByGuard, first: first, answer: "We hid it.")).fate == .rejected)
        #expect(SecondPassRecords.fate(of: trace(pass: .kept, second: .timeout, first: first)).fate == .timedOut)
        #expect(SecondPassRecords.fate(of: trace(pass: .kept, second: .modelBusy, first: first)).fate == .noAnswer)
    }

    @Test("an answer a check turned down that says the same words counts as unchanged, not rejected")
    func sameWordsIsUnchanged() {
        let verdict = SecondPassRecords.fate(of: trace(
            pass: .kept, second: .rejectedByGuard, first: "We could like hide the sidebar.", answer: "we could like hide the sidebar"))
        #expect(verdict.fate == .unchanged)
    }

    // MARK: The tape

    private let schema = GenerationSchemaSpec(name: "Cleaned", json: "{}")

    private func ask(_ model: TapedModel, _ prompt: String) async throws -> String {
        try await model.respond(instructions: "i", prompt: prompt, schema: schema, options: .greedy)
    }

    @Test("a replay gives back what the live run recorded, without calling the model")
    func replayReturnsRecordedAnswers() async throws {
        let tape = CallTape()
        let base = CountingModel(delay: .milliseconds(30)) { "answer to \($0)" }
        tape.begin(scope: "a")
        #expect(try await ask(TapedModel(base: base, label: "second", tape: tape, role: .record), "p") == "answer to p")
        tape.begin(scope: "a")
        let replay = TapedModel(base: base, label: "second", tape: tape, role: .replay(budgetMs: nil))
        #expect(try await ask(replay, "p") == "answer to p")
        #expect(base.calls == 1)
        #expect(tape.drainCounters().hits == 1)
    }

    @Test("under a budget, an answer that took longer when recorded is withheld; a quicker one is served")
    func replayWithholdsALateAnswer() async throws {
        let tape = CallTape()
        tape.begin(scope: "a")
        _ = try await ask(TapedModel(base: CountingModel(delay: .milliseconds(80)) { $0 }, label: "second", tape: tape, role: .record), "p")
        tape.begin(scope: "a")
        await #expect(throws: LateAnswer.self) {
            _ = try await ask(TapedModel(base: NullLanguageModel(), label: "second", tape: tape, role: .replay(budgetMs: 20)), "p")
        }
        tape.begin(scope: "a")
        #expect(try await ask(TapedModel(base: NullLanguageModel(), label: "second", tape: tape, role: .replay(budgetMs: 5_000)), "p") == "p")
        let counters = tape.drainCounters()
        #expect(counters.late == 1)
        #expect(counters.hits == 2)
    }

    @Test("the same request in another dictation, or to the other model, has no recording")
    func replayIsScopedToTheDictationAndTheModel() async throws {
        let tape = CallTape()
        tape.begin(scope: "a")
        _ = try await ask(TapedModel(base: CountingModel { $0 }, label: "first", tape: tape, role: .record), "p")
        tape.begin(scope: "b")
        await #expect(throws: LanguageModelError.self) {
            _ = try await ask(TapedModel(base: NullLanguageModel(), label: "first", tape: tape, role: .replay(budgetMs: nil)), "p")
        }
        tape.begin(scope: "a")
        await #expect(throws: LanguageModelError.self) {
            _ = try await ask(TapedModel(base: NullLanguageModel(), label: "second", tape: tape, role: .replay(budgetMs: nil)), "p")
        }
        #expect(tape.drainCounters().misses == 2)
    }

    @Test("a recorded failure is replayed as the same kind of failure")
    func replayRepeatsAFailure() async throws {
        let tape = CallTape()
        tape.begin(scope: "a")
        let failing = CountingModel(failure: LanguageModelError.busy("memory")) { $0 }
        await #expect(throws: LanguageModelError.self) {
            _ = try await ask(TapedModel(base: failing, label: "second", tape: tape, role: .record), "p")
        }
        tape.begin(scope: "a")
        do {
            _ = try await ask(TapedModel(base: NullLanguageModel(), label: "second", tape: tape, role: .replay(budgetMs: nil)), "p")
            Issue.record("the replay should have failed")
        } catch let error as LanguageModelError {
            guard case .busy = error else { Issue.record("replayed as \(error)"); return }
        }
    }

    @Test("an arm is written as live or replay, with the second pass on, off or a budget")
    func armNames() {
        #expect(SecondPassRunner.ArmSpec("live:on")?.secondPass == "on")
        #expect(SecondPassRunner.ArmSpec("replay:off")?.budgetMs == nil)
        #expect(SecondPassRunner.ArmSpec("replay:off")?.live == false)
        #expect(SecondPassRunner.ArmSpec("live:1000")?.budgetMs == 1_000)
        #expect(SecondPassRunner.ArmSpec("live:1000")?.name == "live:1000")
        #expect(SecondPassRunner.ArmSpec("live") == nil)
        #expect(SecondPassRunner.ArmSpec("later:on") == nil)
        #expect(SecondPassRunner.ArmSpec("live:-5") == nil)
    }

    @Test("every writing setting runs at the level the app gives it")
    func settingsLevels() {
        let bundle = "com.anthropic.claudefordesktop"
        #expect(SecondPassRunner.settings(.asSpoken, bundleID: bundle).cleanupOptions.level == .verbatim)
        for setting in [SecondPassRunner.Setting.refined, .casual, .professional] {
            let settings = SecondPassRunner.settings(setting, bundleID: bundle)
            #expect(settings.cleanupOptions.level == .polished)
            #expect(settings.tone?.rawValue == setting.rawValue)
        }
        let clean = SecondPassRunner.settings(.clean, bundleID: bundle)
        #expect(clean.cleanupOptions.level == .clean)
        #expect(clean.tone == nil)
    }
}

private final class CountingModel: LanguageModel {
    private let transform: @Sendable (String) -> String
    private let delay: Duration
    private let failure: LanguageModelError?
    private let count = Mutex(0)

    init(delay: Duration = .zero, failure: LanguageModelError? = nil, _ transform: @escaping @Sendable (String) -> String) {
        self.delay = delay
        self.failure = failure
        self.transform = transform
    }

    var calls: Int { count.withLock { $0 } }
    var identifier: String { "counting" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        count.withLock { $0 += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return transform(prompt)
    }
}
