import Foundation
import MLXGuidedGeneration
import Testing
@testable import HushyModelsMLX
@testable import MurmurCore

@Suite("MLX tool-aware envelope grammar")
struct ToolEnvelopeGrammarTests {
    private func decode(_ target: String, junk: String = "", toolAware: Bool) throws -> GuidedJSONDecoder.Result {
        try decode(target, junk: junk, mode: toolAware ? .aware : .flat)
    }

    private func decode(_ target: String, junk: String = "", mode: ToolEnvelopeGrammar.Mode) throws -> GuidedJSONDecoder.Result {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer(), toolGrammar: mode)
        return try cache.withConstraint(for: VoiceToolCatalog.envelopeSchema) { constraint, commits in
            var decoder = GuidedJSONDecoder(
                model: ScriptedModel(target: target, junk: junk), constraint: constraint, endTokens: [TinyVocab.eos],
                grammarVocabSize: TinyVocab.strings.count, temperature: nil, maxSampledTokens: 4_000)
            decoder.commits = commits
            decoder.checkpoint = {}
            return try decoder.decode(prompt: [])
        }
    }

    @Test("only the tools-v1 envelope gets the tool-aware grammar; it compiles")
    func recognisesOnlyTheEnvelope() throws {
        #expect(try ToolEnvelopeGrammar.compactEBNF(for: VoiceToolCatalog.envelopeSchema) != nil)
        #expect(try ToolEnvelopeGrammar.compactEBNF(for: SmartCleaner.cleanedSchema) == nil)
        #expect(try ToolEnvelopeGrammar.compactEBNF(for: GeneratedActionEnvelope.generationSchema) == nil)
        let grammar = try #require(try ToolEnvelopeGrammar.compactEBNF(for: VoiceToolCatalog.envelopeSchema))
        // no_action takes only `reason`: its title is forced empty.
        #expect(grammar.contains(#""{\"tool\":\"no_action\",\"list\":\"\",\"title\":\"\""#) || grammar.contains(#"no_action\",\"title\":\"\""#))
    }

    @Test("a well-formed call decodes identically, with the unused arguments forced instead of sampled")
    func sameAnswerFewerSamples() throws {
        for (tool, fill) in [
            ("propose_message", ["channel": "slack", "recipient": "arjun", "text": "the build is green"]),
            ("create_reminder", ["title": "Call mom", "when": "tomorrow at 3"]),
            ("no_action", ["reason": "not_a_command"]),
        ] {
            let target = SpeculativeDecodingTests.toolTarget(tool: tool, fill: fill)
            let flat = try decode(target, toolAware: false)
            let aware = try decode(target, toolAware: true)
            #expect(TinyVocab.text(aware.tokens) == target, "\(tool)")
            #expect(aware.tokens == flat.tokens, "\(tool)")
            #expect(Double(aware.sampled) < Double(flat.sampled) * 0.6, "\(tool): \(aware.sampled) vs \(flat.sampled) sampled")
        }
    }

    @Test("a model that fills unused arguments with junk still yields the same ToolCall — the junk can't be written")
    func junkFillsAreForcedEmpty() throws {
        var target = SpeculativeDecodingTests.toolTarget(tool: "create_reminder", fill: ["title": "Call mom", "when": "tomorrow"])
        target = target.replacingOccurrences(of: #""location":"""#, with: #""location":"now""#)
            .replacingOccurrences(of: #""body":"""#, with: #""body":"now""#)
        let flat = try decode(target, toolAware: false)
        let aware = try decode(target, toolAware: true)
        #expect(TinyVocab.text(flat.tokens).contains(#""body":"now""#))
        let awareText = TinyVocab.text(aware.tokens)
        #expect(awareText.contains(#""body":"""#) && awareText.contains(#""location":"""#))
        let awareCall = try #require(ToolCall(envelopeJSON: awareText))
        #expect(awareCall == ToolCall(envelopeJSON: TinyVocab.text(flat.tokens)))
        #expect(awareCall.arguments["title"] == .string("Call mom"))
    }

    @Test("enumerated arguments are limited to their values; strict mode fills required arguments")
    func enumsAndRequired() throws {
        // The model wants a channel outside the enumeration and an empty required title.
        let message = SpeculativeDecodingTests.toolTarget(tool: "propose_message", fill: ["channel": "telegram", "recipient": "arjun", "text": "hi"])
        // Once its context leaves the target the scripted model prefers `"` then `x` (so it ends strings).
        let messageText = TinyVocab.text(try decode(message, junk: "\"x", mode: .aware).tokens)
        let call = try #require(ToolCall(envelopeJSON: messageText))
        let channel = try #require(call.arguments["channel"])
        #expect(["slack", "imessage", "whatsapp", "teams", "discord"].map { ToolArgumentValue.string($0) }.contains(channel))
        let reminder = SpeculativeDecodingTests.toolTarget(tool: "create_reminder", fill: ["when": "tomorrow"])
        let aware = try #require(ToolCall(envelopeJSON: TinyVocab.text(try decode(reminder, junk: "\"x", mode: .aware).tokens)))
        let strict = try #require(ToolCall(envelopeJSON: TinyVocab.text(try decode(reminder, junk: "\"x", mode: .strict).tokens)))
        #expect(aware.arguments["title"] == nil)
        #expect(strict.arguments["title"] != nil)
        #expect(try ToolEnvelopeGrammar.compactEBNF(for: VoiceToolCatalog.envelopeSchema, mode: .flat) == nil)
    }

    @Test("tool-first order: the chosen tool's arguments come first, so the empties after them are never fed")
    func toolFirstOrder() throws {
        let grammar = try #require(try ToolEnvelopeGrammar.compactEBNF(for: VoiceToolCatalog.envelopeSchema, mode: .toolFirst))
        #expect(grammar.contains(#"no_action\",\"reason\":"#))
        let flat = SpeculativeDecodingTests.toolTarget(tool: "no_action", fill: ["reason": "not_a_command"])
        let reason = #","reason":"not_a_command""#
        let head = #"{"tool":"no_action""#
        let target = head + reason + flat.dropFirst(head.count).replacingOccurrences(of: reason, with: "")
        let cacheAware = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer(), toolGrammar: .aware)
        let cacheFirst = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer(), toolGrammar: .toolFirst)
        func run(_ cache: GrammarCache, _ target: String) throws -> (String, Int) {
            let model = ScriptedModel(target: target)
            let result = try cache.withConstraint(for: VoiceToolCatalog.envelopeSchema) { constraint, commits in
                var decoder = GuidedJSONDecoder(
                    model: model, constraint: constraint, endTokens: [TinyVocab.eos],
                    grammarVocabSize: TinyVocab.strings.count, temperature: nil, maxSampledTokens: 4_000)
                decoder.commits = commits
                decoder.checkpoint = {}
                return try decoder.decode(prompt: [])
            }
            return (TinyVocab.text(result.tokens), model.feeds.reduce(0) { $0 + $1.count })
        }
        let (awareText, awareFed) = try run(cacheAware, flat)
        let (firstText, firstFed) = try run(cacheFirst, target)
        #expect(firstText == target)
        #expect(ToolCall(envelopeJSON: firstText) == ToolCall(envelopeJSON: awareText))
        #expect(firstFed < awareFed / 2, "tool-first fed \(firstFed) tokens, aware \(awareFed)")
    }
}
