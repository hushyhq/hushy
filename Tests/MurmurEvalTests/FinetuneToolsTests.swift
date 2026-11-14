import Foundation
import HushyModelsMLX
import MurmurCore
import Testing

@testable import murmur_eval

@Suite("Voice-actions fine-tune data: label checks (tools-check)")
struct FinetuneToolsTests {
    private let context: [String: Any] = ["now": "2026-10-05T10:15:00-07:00", "timeZone": "America/Los_Angeles", "locale": "en_US"]

    private func verdict(_ utterance: String, _ tool: String, _ args: [String: Any]) throws -> Result<String, FinetuneTools.Rejection> {
        let checker = try ToolEnvelopeChecker(mode: "tool-first")
        let row: FinetuneJSONL.Row = ["id": "t", "utterance": utterance, "context": context, "call": ["tool": tool, "args": args]]
        return FinetuneTools.verdict(row, grammar: "tool-first", checker: checker)
    }

    private func rejection(_ result: Result<String, FinetuneTools.Rejection>) -> String? {
        if case .failure(let rejection) = result { return rejection.text }
        return nil
    }

    @Test("a grounded, schema-valid call passes and comes back as the runtime's envelope")
    func accepts() throws {
        let result = try verdict("uh remind me to call the plumber tomorrow at 3 no 4 pm", "create_reminder",
                                 ["title": "call the plumber", "when": "tomorrow at 4 pm"])
        guard case .success(let answer) = result else { Issue.record("rejected: \(rejection(result) ?? "")"); return }
        #expect(answer.hasPrefix(#"{"tool":"create_reminder","title":"call the plumber","when":"tomorrow at 4 pm","list":"""#))
        #expect(rejection(try verdict("hey what's up", "no_action", ["reason": "not_a_command"])) == nil)
        #expect(rejection(try verdict("set a timer for an hour and a half", "set_timer", ["duration": "an hour and a half"])) == nil)
    }

    @Test("labels the runtime would not accept are rejected, each for its reason")
    func rejects() throws {
        // Invented word (not in the utterance).
        #expect(rejection(try verdict("remind me to call the plumber", "create_reminder", ["title": "phone the plumber"]))?.hasPrefix("ungrounded") == true)
        // Missing required argument / unknown argument.
        #expect(rejection(try verdict("add eggs to groceries", "add_to_list", ["items": ["eggs"]]))?.hasPrefix("schema") == true)
        #expect(rejection(try verdict("open slack", "open_app", ["target": "slack", "when": "now"]))?.hasPrefix("schema") == true)
        // The pre-model screen refuses edits; only an `unsupported` label agrees with it.
        #expect(rejection(try verdict("move my standup to friday at 10", "create_event", ["title": "standup", "when": "friday at 10"]))?.hasPrefix("prescreen") == true)
        #expect(rejection(try verdict("move my standup to friday at 10", "no_action", ["reason": "unsupported"])) == nil)
        // VoiceToolGuard refuses a destructive Shortcut, and the sensitive screen a secret in a positive call.
        #expect(rejection(try verdict("run the wipe disk shortcut", "run_shortcut", ["name": "wipe disk"]))?.hasPrefix("guard") == true)
        #expect(rejection(try verdict("save a note my password is sunflower42", "save_note", ["text": "my password is sunflower42"]))?.hasPrefix("sensitive") == true)
        // Dates and durations must be readable by the runtime's parsers.
        #expect(rejection(try verdict("remind me to stretch at some point", "create_reminder", ["title": "stretch", "when": "some point"]))?.hasPrefix("date") == true)
        #expect(rejection(try verdict("set a timer for three whistles", "set_timer", ["duration": "three whistles"]))?.hasPrefix("duration") == true)
    }

    @Test("the eval's user turn and the training data's are the same bytes")
    func userPromptMatchesEval() throws {
        let item = try JSONDecoder().decode(ToolEvalCase.Context.self, from: JSONSerialization.data(withJSONObject: context.merging(["frontmostApp": "Slack"]) { a, _ in a }))
        let line = VoiceToolCatalog.contextLine(now: try #require(item.nowDate), timeZone: try #require(item.zone), locale: item.locale, frontmostApp: "Slack")
        #expect(line == item.promptLine())
        #expect(VoiceToolCatalog.userPrompt(contextLine: line, utterance: "open slack") == line + "\nUtterance: open slack")
    }
}
