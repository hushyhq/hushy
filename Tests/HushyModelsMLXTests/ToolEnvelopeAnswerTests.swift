import CryptoKit
import Foundation
import Testing
@testable import HushyModelsMLX
@testable import MurmurCore

@Suite("Tool envelope answers for fine-tune data")
struct ToolEnvelopeAnswerTests {
    private let calls: [ToolCall] = [
        ToolCall(tool: "create_reminder", arguments: ["title": .string("call the plumber"), "when": .string("tomorrow at 9")]),
        ToolCall(tool: "create_event", arguments: [
            "title": .string("lunch with priya"), "when": .string("friday at 1"), "duration_minutes": .integer(45),
            "attendees": .strings(["priya"]),
        ]),
        ToolCall(tool: "add_to_list", arguments: ["items": .strings(["eggs", "oat milk"]), "list": .string("groceries")]),
        ToolCall(tool: "propose_message", arguments: ["channel": .string("slack"), "recipient": .string("dana"), "text": .string("café at 5 \"ok\"")]),
        .noAction(.notACommand),
    ]

    @Test("render puts the tool's own arguments first in tool-first mode and follows x-order in strict mode")
    func keyOrder() throws {
        let reminder = calls[0]
        let first = try #require(ToolEnvelopeAnswer.render(reminder, mode: "tool-first"))
        #expect(first.hasPrefix(#"{"tool":"create_reminder","title":"call the plumber","when":"tomorrow at 9","list":"","#))
        let strict = try #require(ToolEnvelopeAnswer.render(reminder, mode: "strict"))
        let order = ["tool"] + VoiceToolCatalog.allParameters.map(\.name)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(strict.utf8)) as? [String: Any])
        #expect(Set(object.keys) == Set(order))
        var cursor = strict.startIndex
        for key in order {
            let range = try #require(strict.range(of: "\"\(key)\":", range: cursor..<strict.endIndex))
            cursor = range.upperBound
        }
        #expect(ToolEnvelopeAnswer.render(reminder, mode: "flat") == nil)
        #expect(ToolEnvelopeAnswer.render(ToolCall(tool: "create_event", arguments: ["duration_minutes": .string("45")]), mode: "strict") == nil)
    }

    @Test("every rendered answer is accepted by the compiled grammar and reads back as the same call")
    func grammarAcceptsRenderedAnswers() throws {
        for mode in ToolEnvelopeAnswer.trainableModes {
            let checker = try ToolEnvelopeChecker(mode: mode, extraScalars: ["é"])
            for call in calls {
                let answer = try #require(ToolEnvelopeAnswer.render(call, mode: mode))
                #expect(checker.accepts(answer), "\(mode) \(answer)")
                #expect(ToolCall(envelopeJSON: answer) == call)
                // The checker resets itself: the same answer passes twice.
                #expect(checker.accepts(answer))
            }
        }
    }

    @Test("the grammar rejects what the decoder could never emit")
    func grammarRejects() throws {
        let checker = try ToolEnvelopeChecker(mode: "tool-first")
        let good = try #require(ToolEnvelopeAnswer.render(calls[0], mode: "tool-first"))
        // An optional argument of the chosen tool may be filled…
        #expect(checker.accepts(good.replacingOccurrences(of: #""list":"""#, with: #""list":"inbox""#)))
        // …but an argument only another tool takes must stay empty.
        #expect(!checker.accepts(good.replacingOccurrences(of: #""target":"""#, with: #""target":"slack""#)))
        // A required argument may not be empty; strict whitespace-free JSON only; no truncation.
        #expect(!checker.accepts(good.replacingOccurrences(of: #""title":"call the plumber""#, with: #""title":"""#)))
        #expect(!checker.accepts(good.replacingOccurrences(of: #"{"tool":"#, with: #"{ "tool":"#)))
        #expect(!checker.accepts(String(good.dropLast())))
        #expect(!checker.accepts(#"{"tool":"no_action","reason":"because"}"#))
        // strict order is not tool-first order (for a tool whose arguments aren't first in x-order).
        let timer = ToolCall(tool: "set_timer", arguments: ["duration": .string("20 minutes")])
        let strict = try #require(ToolEnvelopeAnswer.render(timer, mode: "strict"))
        #expect(!checker.accepts(strict))
        #expect(checker.accepts(try #require(ToolEnvelopeAnswer.render(timer, mode: "tool-first"))))
    }

    @Test("the tools system prompt is pinned: changing it means a new promptVersion and a retrained model")
    func promptIsPinned() {
        let system = MLXLanguageModel.systemText(instructions: VoiceToolCatalog.instructions, schema: VoiceToolCatalog.envelopeSchema)
        let digest = SHA256.hash(data: Data(system.utf8)).map { String(format: "%02x", $0) }.joined()
        // prompt-2: `open_app` gained the service-link slots (2026-09-28); the tools adapters
        // trained on prompt-1 need a retrain before the MLX tools path ships against it.
        #expect(VoiceToolCatalog.promptVersion == "tools-v1-prompt-2")
        #expect(digest == "a45ee5717ceece25979ee4202e4558d55f5e053146c017115a2b06ec459c5bf8")
    }
}
