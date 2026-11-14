import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

/// Per-case scoring and the aggregate metrics of `murmur-eval tools`.
@Suite("Tool eval scoring")
struct ToolEvalScoringTests {
    private let context = ToolEvalCase.Context(now: "2026-10-07T14:40:00-07:00", timeZone: "America/Los_Angeles", locale: "en_US")

    private func item(
        _ id: String, _ decision: ToolEvalCase.Expectation.Decision, tool: String = "no_action",
        args: [String: ToolArgumentValue] = [:], reasons: [String]? = nil, split: [ToolCall]? = nil,
        spoken: [String]? = nil, category: ToolEvalCategory = .plainCommand
    ) -> ToolEvalCase {
        ToolEvalCase(
            id: id, utterance: "x", context: context, category: category, tags: [],
            expect: .init(decision: decision, tool: tool, args: args, whenSpoken: spoken, reasons: reasons, split: split))
    }

    private func answer(_ calls: [ToolCall], error: String? = nil, ms: Double = 100) -> ToolEvalAnswer {
        ToolEvalAnswer(calls: calls, error: error, latencyMs: ms)
    }

    private var reminder: ToolEvalCase {
        item("r", .call, tool: "create_reminder", args: ["title": .string("call the plumber"), "when": .string("2026-10-08T09:00:00-07:00")],
             spoken: ["tomorrow at 9"], category: .relativeDatetime)
    }

    @Test("a command: right tool with exact, tolerant or wrong arguments")
    func command() {
        let exact = ToolEvalScoring.score(reminder, answer([ToolCall(tool: "create_reminder", arguments: [
            "title": .string("call the plumber"), "when": .string("tomorrow at 9"),
        ])]))
        #expect(exact.toolCorrect && exact.callExact && exact.callTolerant && exact.schemaValid)
        let tolerant = ToolEvalScoring.score(reminder, answer([ToolCall(tool: "create_reminder", arguments: [
            "title": .string("Call plumber"), "when": .string("tomorrow at 9"), "list": .string("Home"),
        ])]))
        #expect(tolerant.toolCorrect && !tolerant.callExact && tolerant.callTolerant)
        let wrongTool = ToolEvalScoring.score(reminder, answer([ToolCall(tool: "create_event", arguments: [
            "title": .string("call the plumber"), "when": .string("tomorrow at 9"),
        ])]))
        #expect(!wrongTool.toolCorrect && !wrongTool.callTolerant)
        let missed = ToolEvalScoring.score(reminder, answer([], error: "timeout"))
        #expect(!missed.toolCorrect && !missed.falseFire)
        let doubled = ToolEvalScoring.score(reminder, answer([
            ToolCall(tool: "create_reminder", arguments: ["title": .string("call the plumber")]),
            ToolCall(tool: "open_app", arguments: ["target": .string("x")]),
        ]))
        #expect(!doubled.toolCorrect, "two calls for one intent is wrong")
    }

    @Test("a list or calendar the case never named is counted; a named one, or none at all, is not")
    func unaskedTarget() {
        let invented = ToolEvalScoring.score(reminder, answer([ToolCall(tool: "create_reminder", arguments: [
            "title": .string("call the plumber"), "when": .string("tomorrow at 9"), "list": .string("groceries"),
        ])]))
        #expect(invented.namesUnaskedTarget && invented.expectsNoTarget)
        let plain = ToolEvalScoring.score(reminder, answer([ToolCall(tool: "create_reminder", arguments: [
            "title": .string("call the plumber"), "when": .string("tomorrow at 9"), "list": .string(" "),
        ])]))
        #expect(!plain.namesUnaskedTarget && plain.expectsNoTarget)
        let named = item("l", .call, tool: "create_reminder", args: ["title": .string("stamps"), "list": .string("errands")])
        let asked = ToolEvalScoring.score(named, answer([ToolCall(tool: "create_reminder", arguments: [
            "title": .string("stamps"), "list": .string("errands"),
        ])]))
        #expect(!asked.namesUnaskedTarget && !asked.expectsNoTarget)
        let event = item("e", .call, tool: "create_event", args: ["title": .string("sync"), "when": .string("2026-10-08T09:00:00-07:00")],
                         spoken: ["tomorrow at 9"])
        let calendar = ToolEvalScoring.score(event, answer([ToolCall(tool: "create_event", arguments: [
            "title": .string("sync"), "when": .string("tomorrow at 9"), "calendar": .string("work"),
        ])]))
        #expect(calendar.namesUnaskedTarget)
        let negative = item("n", .noAction, args: ["reason": .string("not_a_command")], reasons: ["not_a_command"], category: .falseFire)
        let fired = ToolEvalScoring.score(negative, answer([ToolCall(tool: "create_reminder", arguments: [
            "title": .string("x"), "list": .string("groceries"),
        ])]))
        #expect(!fired.namesUnaskedTarget && !fired.expectsNoTarget, "a false fire is counted as a false fire, once")

        let s = ToolEvalSummary([invented, plain, asked, calendar, fired])
        #expect(s.unaskedTargets == 2 && s.targetFreeCommands == 3)
        let markdown = ToolEvalReport.markdown(
            set: ToolEvalSet(format: ToolEvalSet.format, catalog: "tools-v1", name: "t", split: "dev", cases: []),
            backend: "test", summary: s, heldout: false)
        #expect(markdown.contains("| List or calendar named that nobody said | 2/3 |"))
    }

    @Test("an alternative whole call counts as the right tool")
    func alternatives() {
        var invite = item("i", .call, tool: "propose_calendar_invite", args: [
            "title": .string("sync"), "when": .string("2026-10-08T09:00:00-07:00"), "attendees": .strings(["dana"]),
        ], spoken: ["tomorrow at 9"])
        invite.expect.alternatives = [ToolCall(tool: "create_event", arguments: invite.expect.args)]
        let outcome = ToolEvalScoring.score(invite, answer([ToolCall(tool: "create_event", arguments: [
            "title": .string("sync"), "when": .string("tomorrow at 9"), "attendees": .strings(["Dana"]),
        ])]))
        #expect(outcome.toolCorrect && outcome.callTolerant)
    }

    @Test("a negative: any tool is a false fire; empty, no_action and errors are correct")
    func negative() {
        let negative = item("n", .noAction, args: ["reason": .string("not_a_command")], reasons: ["not_a_command"], category: .falseFire)
        #expect(ToolEvalScoring.score(negative, answer([])).toolCorrect)
        #expect(ToolEvalScoring.score(negative, answer([.noAction(.notACommand)])).toolCorrect)
        #expect(ToolEvalScoring.score(negative, answer([], error: "timeout")).toolCorrect)
        let fired = ToolEvalScoring.score(negative, answer([ToolCall(tool: "create_reminder", arguments: ["title": .string("x")])]))
        #expect(fired.falseFire && !fired.toolCorrect)
    }

    @Test("a refusal: no action is lenient-correct, the right reason is strict-correct, a matching split is accepted")
    func refusal() {
        let split = [ToolCall(tool: "set_timer", arguments: ["duration": .integer(600)]),
                     ToolCall(tool: "open_app", arguments: ["target": .string("spotify")])]
        let multi = item("m", .refuse, args: ["reason": .string("multi_intent")], reasons: ["multi_intent"], split: split, category: .multiIntent)
        let silent = ToolEvalScoring.score(multi, answer([]))
        #expect(silent.refusalLenient == true && silent.refusalStrict == false)
        let reasoned = ToolEvalScoring.score(multi, answer([.noAction(.multiIntent)]))
        #expect(reasoned.refusalStrict == true)
        let wrongReason = ToolEvalScoring.score(multi, answer([.noAction(.sensitiveContent)]))
        #expect(wrongReason.refusalLenient == true && wrongReason.refusalStrict == false)
        let splitAnswer = ToolEvalScoring.score(multi, answer([
            ToolCall(tool: "open_app", arguments: ["target": .string("Spotify")]),
            ToolCall(tool: "set_timer", arguments: ["duration": .string("10 minutes")]),
        ]))
        #expect(splitAnswer.refusalLenient == true && splitAnswer.toolCorrect)
        let halfSplit = ToolEvalScoring.score(multi, answer([ToolCall(tool: "set_timer", arguments: ["duration": .integer(600)])]))
        #expect(halfSplit.refusalLenient == false, "doing only one of two intents is not a refusal")
    }

    @Test("the summary computes accuracy, false-fire rate, refusals and latency percentiles")
    func summary() {
        let negative = item("n", .noAction, args: ["reason": .string("not_a_command")], reasons: ["not_a_command"], category: .falseFire)
        let sensitive = item("s", .refuse, args: ["reason": .string("sensitive_content")], reasons: ["sensitive_content"], category: .sensitive)
        let right = ToolCall(tool: "create_reminder", arguments: ["title": .string("call the plumber"), "when": .string("tomorrow at 9")])
        let outcomes = [
            ToolEvalScoring.score(reminder, answer([right], ms: 100)),
            ToolEvalScoring.score(reminder, answer([], ms: 200)),
            ToolEvalScoring.score(negative, answer([], ms: 300)),
            ToolEvalScoring.score(negative, answer([right], ms: 400)),
            ToolEvalScoring.score(sensitive, answer([.noAction(.sensitiveContent)], ms: 500)),
        ]
        let s = ToolEvalSummary(outcomes)
        #expect(s.total == 5 && s.positives == 2 && s.negatives == 2 && s.refusals == 1)
        #expect(s.toolSelectAccuracy == 3.0 / 5.0)
        #expect(s.falseFireRate == 0.5 && s.falseFires == 1)
        #expect(s.callExactRate == 0.5 && s.missedCommandRate == 0.5)
        #expect(s.refusalLenient == 1 && s.refusalStrict == 1)
        #expect(s.latencyP50 == 300)
        #expect(s.toolNameP50 == nil)
        #expect(s.byCategory.first { $0.0 == .falseFire }?.1.count == 2)
        let markdown = ToolEvalReport.markdown(
            set: ToolEvalSet(format: ToolEvalSet.format, catalog: "tools-v1", name: "t", split: "dev", cases: []),
            backend: "test", summary: s, heldout: true)
        #expect(markdown.contains("SEALED HELD-OUT"))
        #expect(!markdown.contains("plumber"), "held-out reports carry no case text")
    }

    @Test("failure lines list false fires first and never run for held-out")
    func failureLines() {
        let negative = item("n", .noAction, args: ["reason": .string("not_a_command")], reasons: ["not_a_command"], category: .falseFire)
        let outcomes = [
            ToolEvalScoring.score(reminder, answer([])),
            ToolEvalScoring.score(negative, answer([ToolCall(tool: "open_app", arguments: ["target": .string("x")])])),
        ]
        let lines = ToolEvalReport.failureLines(outcomes, limit: 10)
        #expect(lines.count == 3)
        #expect(lines[1].contains(" n "))
    }
}
