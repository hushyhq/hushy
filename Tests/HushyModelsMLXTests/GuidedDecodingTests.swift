import Foundation
import MLXGuidedGeneration
import Testing
@testable import HushyModelsMLX
@testable import MurmurCore

/// The real XGrammar matcher over a tiny vocabulary, driven by a scripted fake model.
@Suite("MLX guided JSON decoding (XGrammar)")
struct GuidedDecodingTests {
    static let productionSchemas = [
        SmartCleaner.Cleaned.generationSchema, SmartCleaner.RerankAnswer.generationSchema,
        MeetingPartNotes.generationSchema, MeetingDigest.generationSchema, MeetingMerge.generationSchema, ModeExecutor.Transformed.generationSchema,
        GeneratedActionEnvelope.generationSchema, MeetingExtractAnswer.generationSchema,
    ]

    private func run(
        _ spec: GenerationSchemaSpec, target: String, junk: String = "", maxTokens: Int = 400,
        checkpoint: @escaping () throws -> Void = {}
    ) throws -> (json: String, result: GuidedJSONDecoder.Result, model: ScriptedModel) {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        let model = ScriptedModel(target: target, junk: junk)
        let result = try cache.withConstraint(for: spec) { constraint, commits in
            var decoder = GuidedJSONDecoder(
                model: model, constraint: constraint, endTokens: [TinyVocab.eos],
                grammarVocabSize: TinyVocab.strings.count, temperature: nil, maxSampledTokens: maxTokens)
            decoder.commits = commits
            decoder.checkpoint = checkpoint
            return try decoder.decode(prompt: [])
        }
        return (TinyVocab.text(result.tokens), result, model)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], "not JSON: \(json)")
    }

    @Test("every production schema compiles to an XGrammar grammar")
    func allSchemasCompile() throws {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        for spec in Self.productionSchemas {
            #expect(throws: Never.self) { _ = try cache.withConstraint(for: spec) { constraint, _ in try constraint.computeMask() } }
        }
        #expect(cache.compilations == Self.productionSchemas.count)
    }

    @Test("one compiled grammar serves many calls: the matcher is rolled back after each")
    func grammarReuse() throws {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        let targets = [#"{"text":"Hello"}"#, #"{"text":"Second answer, longer."}"#, #"{"text":""}"#]
        for target in targets {
            let tokens = try cache.withConstraint(for: SmartCleaner.Cleaned.generationSchema) { constraint, commits in
                var decoder = GuidedJSONDecoder(
                    model: ScriptedModel(target: target), constraint: constraint, endTokens: [TinyVocab.eos],
                    grammarVocabSize: TinyVocab.strings.count, temperature: nil, maxSampledTokens: 100)
                decoder.commits = commits
                return try decoder.decode(prompt: []).tokens
            }
            #expect(TinyVocab.text(tokens) == target)
        }
        // Cancelled mid-answer: the matcher is still reset for the next call.
        #expect(throws: CancellationError.self) {
            try cache.withConstraint(for: SmartCleaner.Cleaned.generationSchema) { constraint, commits in
                var passes = 0
                var decoder = GuidedJSONDecoder(
                    model: ScriptedModel(target: #"{"text":"interrupted answer"}"#), constraint: constraint,
                    endTokens: [TinyVocab.eos], grammarVocabSize: TinyVocab.strings.count, temperature: nil, maxSampledTokens: 100)
                decoder.commits = commits
                decoder.checkpoint = { passes += 1; if passes > 4 { throw CancellationError() } }
                _ = try decoder.decode(prompt: [])
            }
        }
        let after = try cache.withConstraint(for: SmartCleaner.Cleaned.generationSchema) { constraint, commits in
            var decoder = GuidedJSONDecoder(
                model: ScriptedModel(target: #"{"text":"Hello"}"#), constraint: constraint, endTokens: [TinyVocab.eos],
                grammarVocabSize: TinyVocab.strings.count, temperature: nil, maxSampledTokens: 100)
            decoder.commits = commits
            return try decoder.decode(prompt: []).tokens
        }
        #expect(TinyVocab.text(after) == #"{"text":"Hello"}"#)
        #expect(cache.compilations == 1)
    }

    @Test("the compact grammar fixes key order and allows no whitespace")
    func compactGrammarShape() throws {
        let grammar = try JSONSchemaNode.parse(SmartCleaner.RerankAnswer.generationSchema).compactEBNF()
        #expect(grammar.contains(#""{\"keeps\":""#))
        #expect(grammar.contains(#"",\"droppedInformation\":""#))
        #expect(!grammar.contains("ws"))
    }

    @Test("MeetingRecords: a nullable owner and due decode as null or a string, and a chunk may list many records")
    func meetingRecords() throws {
        let grammar = try JSONSchemaNode.parse(MeetingExtractAnswer.generationSchema).compactEBNF()
        #expect(grammar.contains(#"| "null")"#))
        #expect(grammar.contains("{0,\(JSONSchemaNode.meetingRecordsMaxItems - 1)}"))
        let target = #"{"records":[{"kind":"action","text":"Send it.","owner":null,"due":"Friday","quote":"send it by Friday"},{"kind":"decision","text":"Ship.","owner":"You","due":null,"quote":"we ship"}]}"#
        let (json, _, _) = try run(MeetingExtractAnswer.generationSchema, target: target, maxTokens: 600)
        #expect(json == target)
        let answer = try JSONDecoder().decode(MeetingExtractAnswer.self, from: Data(json.utf8))
        #expect(answer.records.map(\.owner) == [nil, "You"])
        #expect(answer.records.map(\.due) == ["Friday", nil])
    }

    @Test("Cleaned: structure is jump-forwarded, the model writes only the text")
    func cleaned() throws {
        let target = #"{"text":"Hello, \"world\". Ship it by Friday."}"#
        let (json, result, model) = try run(SmartCleaner.Cleaned.generationSchema, target: target)
        #expect(try object(json)["text"] as? String == #"Hello, "world". Ship it by Friday."#)
        #expect(json == target)
        #expect(result.forced >= 7, "`\"text\":\"` and the closing brace should be forced, got \(result.forced)")
        // The loop stops once only EOS is allowed: no forward pass is spent on it.
        #expect(!model.feeds.contains { $0.contains(TinyVocab.eos) })
    }

    @Test("rerank: enum and boolean")
    func rerank() throws {
        let (json, _, _) = try run(SmartCleaner.RerankAnswer.generationSchema, target: #"{"keeps":"both","droppedInformation":true}"#)
        let answer = try JSONDecoder().decode(SmartCleaner.RerankAnswer.self, from: Data(json.utf8))
        #expect(answer.keeps == .both)
        #expect(answer.droppedInformation)
    }

    @Test("actions: array of objects with integers")
    func actions() throws {
        let one = #"{"kind":"createEvent","title":"Dentist","when":"tomorrow at 3pm","durationMinutes":45,"listOrCalendarName":"","location":"Main St","shortcutInput":""}"#
        let two = #"{"kind":"createReminder","title":"Call mom","when":"","durationMinutes":0,"listOrCalendarName":"Family","location":"","shortcutInput":""}"#
        let (json, _, _) = try run(GeneratedActionEnvelope.generationSchema, target: #"{"speech":"askingYou","actions":["# + one + "," + two + "]}")
        let envelope = try JSONDecoder().decode(GeneratedActionEnvelope.self, from: Data(json.utf8))
        #expect(envelope.speech == .askingYou)
        #expect(envelope.actions.map(\.durationMinutes) == [45, 0])
        #expect(envelope.actions.last?.listOrCalendarName == "Family")
    }

    @Test("meeting digest: nested action-item objects and empty arrays")
    func meetingDigest() throws {
        let target = #"{"title":"Launch plan","keyPoints":["Ship Friday"],"decisions":[],"actionItems":[{"owner":"Priya","task":"Own QA","due":"Friday"}]}"#
        let (json, _, _) = try run(MeetingDigest.generationSchema, target: target)
        let digest = try JSONDecoder().decode(MeetingDigest.self, from: Data(json.utf8))
        #expect(digest.actionItems == [DigestActionItem(owner: "Priya", task: "Own QA", due: "Friday")])
        #expect(digest.decisions.isEmpty)
    }

    @Test("meeting merge: integer arrays and update objects")
    func meetingMerge() throws {
        let target = #"{"title":"Sync","keyPoints":["k"],"decisions":[],"dropItems":[1,12],"updates":[{"item":3,"owner":"Marcus","due":""}]}"#
        let (json, _, _) = try run(MeetingMerge.generationSchema, target: target)
        #expect(json == target)
    }

    @Test("meeting part notes: the map step's key order")
    func meetingPartNotes() throws {
        let target = #"{"actionItems":[],"decisions":["Use Toast"],"changes":["Permit cancelled"],"speakers":[{"label":"Speaker 2","name":"Ben"}],"keyPoints":["POS"]}"#
        let (json, _, _) = try run(MeetingPartNotes.generationSchema, target: target)
        #expect(json == target)
    }

    @Test("a model that wants to write garbage yields schema-valid JSON or throws — never broken JSON")
    func garbage() throws {
        for junk in ["}]\"\\ ,{[\n\tx9", "\"9],}x", "x"] {
            for spec in Self.productionSchemas {
                do {
                    let (json, _, _) = try run(spec, target: "", junk: junk, maxTokens: 200)
                    #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil, "invalid JSON for \(spec.name): \(json)")
                } catch let error as LanguageModelError {
                    guard case .malformedOutput = error else { throw error }
                }
            }
        }
    }

    @Test("a runaway answer hits the token budget and throws (caller falls back)")
    func budget() {
        let long = String(repeating: "a", count: 500)
        #expect(throws: LanguageModelError.self) {
            _ = try run(SmartCleaner.Cleaned.generationSchema, target: #"{"text":"\#(long)"}"#, maxTokens: 40)
        }
    }

    @Test("cancellation stops decoding before the next forward pass")
    func cancellation() {
        var passes = 0
        #expect(throws: CancellationError.self) {
            _ = try run(SmartCleaner.Cleaned.generationSchema, target: #"{"text":"a long answer that keeps going"}"#) {
                passes += 1
                if passes > 3 { throw CancellationError() }
            }
        }
        #expect(passes == 4)
    }

    @Test("unsupported schema shapes throw unsupportedSchema")
    func unsupportedSchemas() {
        for json in [#"{"type":"number"}"#, #"{"anyOf":[{"type":"string"}]}"#, "not json",
                     #"{"type":"array"}"#, ##"{"$ref":"#/$defs/Missing"}"##, #"{"enum":[1,2]}"#] {
            #expect(throws: LanguageModelError.self) { try JSONSchemaNode.parse(GenerationSchemaSpec(name: "X", json: json)) }
        }
    }

    @Test("schema parsing: x-order, $ref, integers, enums")
    func parsesStructure() throws {
        let rerank = try JSONSchemaNode.parse(SmartCleaner.RerankAnswer.generationSchema)
        #expect(rerank == .object(properties: [
            .init(name: "keeps", node: .enumeration(["a", "b", "both", "neither"])),
            .init(name: "droppedInformation", node: .boolean),
        ]))
        guard case .object(let envelope) = try JSONSchemaNode.parse(GeneratedActionEnvelope.generationSchema),
              case .array(let item, _) = envelope.first(where: { $0.name == "actions" })?.node, case .object(let fields) = item else {
            Issue.record("unexpected envelope shape")
            return
        }
        #expect(fields[3] == .init(name: "durationMinutes", node: .integer))
    }

    @Test("MLX mask: allowed bits are 0, everything else (and past the grammar vocab) is -inf")
    func additiveMask() {
        let mask: [Int32] = [Int32(bitPattern: 0x8000_0005), Int32(bitPattern: 0x8000_0001)]
        let values = MLXDistribution.additiveMaskValues(mask, grammarVocabSize: 40, logitCount: 70)
        #expect(values[0] == 0 && values[2] == 0 && values[31] == 0 && values[32] == 0)
        // Bit 63 is set but lies past the grammar vocabulary; 64..<70 have no mask bits at all.
        #expect(values[1] == -.infinity && values[63] == -.infinity && values[69] == -.infinity)
    }
}
