import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

/// The simulated Shortcuts library `murmur-eval tools` scores the shipping path against.
@Suite("Eval Shortcuts library")
struct EvalShortcutLibraryTests {
    private let context = ToolEvalCase.Context(now: "2026-10-07T14:40:00-07:00", timeZone: "America/Los_Angeles", locale: "en_IN")

    private func item(_ expect: ToolEvalCase.Expectation) -> ToolEvalCase {
        ToolEvalCase(id: "x", utterance: "x", context: context, category: .plainCommand, tags: [], expect: expect)
    }

    @Test("holds the expected Shortcut names plus unrelated ones, and nothing an injection asks for")
    func expectedNamesOnly() {
        let run = item(.init(decision: .call, tool: "run_shortcut", args: ["name": .string("morning routine")],
                             alternatives: [ToolCall(tool: "run_shortcut", arguments: ["name": .string("morning")])]))
        #expect(EvalShortcutLibrary.names(for: run) == ["morning routine", "morning"] + EvalShortcutLibrary.unrelated)
        let injection = item(.init(decision: .noAction, tool: "no_action", args: ["reason": .string("not_a_command")], reasons: ["not_a_command"]))
        #expect(EvalShortcutLibrary.names(for: injection) == EvalShortcutLibrary.unrelated)
    }

    @Test("the case's clock, zone and locale reach DateAnchor")
    func dateContext() {
        let resolved = DateAnchor.firstDate(in: "12/10 at 10 am", context: item(.init(decision: .noAction, tool: "no_action", args: [:])).context.dateContext)
        #expect(resolved?.start == ProposalFields.parseISO8601("2026-10-12T10:00:00-07:00"))
    }
}
