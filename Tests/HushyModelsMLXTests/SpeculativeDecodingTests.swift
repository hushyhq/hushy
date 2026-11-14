import Foundation
import MLXGuidedGeneration
import Testing
@testable import HushyModelsMLX
@testable import MurmurCore

/// Prompt-lookup speculative decoding over the real XGrammar matcher and a scripted model:
/// same answers as the plain loop, grammar-valid drafts, correct rollback for both cache kinds,
/// and cancellation that leaves the grammar reusable.
@Suite("MLX speculative decoding (prompt lookup)")
struct SpeculativeDecodingTests {
    struct Case {
        var name: String
        var schema: GenerationSchemaSpec
        var source: String
        var target: String
        var junk = ""
    }

    struct Outcome {
        var result: GuidedJSONDecoder.Result
        var passes: Int
        var stats: SpeculationStats?
        var model: ScriptedSpeculativeModel
    }

    static let cases: [Case] = [
        Case(name: "clean edits", schema: SmartCleaner.cleanedSchema,
             source: "so um hello world ship it by friday no actually monday",
             target: #"{"text":"Hello world, ship it by Monday."}"#),
        Case(name: "clean copy", schema: SmartCleaner.cleanedSchema,
             source: "the import fails on files over two gigs so we should stream it in chunks",
             target: #"{"text":"the import fails on files over two gigs so we should stream it in chunks"}"#),
        Case(name: "clean with junk preference", schema: SmartCleaner.cleanedSchema,
             source: "please send the draft to priya by thursday",
             target: #"{"text":"Please send the draft to Priya by Thursday."}"#, junk: "x}\""),
        Case(name: "tool envelope", schema: VoiceToolCatalog.envelopeSchema,
             source: "send a message to arjun on slack saying the build is green and we ship at five",
             target: toolTarget(tool: "propose_message", fill: ["channel": "slack", "recipient": "arjun", "text": "the build is green and we ship at five"])),
        Case(name: "rerank", schema: SmartCleaner.RerankAnswer.generationSchema,
             source: "a or b", target: #"{"keeps":"both","droppedInformation":true}"#),
        Case(name: "meeting digest", schema: MeetingDigest.generationSchema,
             source: "launch plan ship friday priya owns qa",
             target: #"{"title":"Launch plan","keyPoints":["Ship Friday"],"decisions":[],"actionItems":[{"owner":"Priya","task":"Own QA","due":""}]}"#),
    ]

    /// The flat tools-v1 envelope in its fixed key order, every argument empty except `fill`.
    static func toolTarget(tool: String, fill: [String: String]) -> String {
        guard let schema = try? JSONSerialization.jsonObject(with: Data(VoiceToolCatalog.envelopeSchema.json.utf8)) as? [String: Any],
              let order = schema["x-order"] as? [String], let properties = schema["properties"] as? [String: [String: Any]]
        else { return "" }
        let fields = order.map { key -> String in
            if key == "tool" { return #""tool":"\#(tool)""# }
            switch properties[key]?["type"] as? String {
            case "integer": return #""\#(key)":0"#
            case "array": return #""\#(key)":[]"#
            default: return #""\#(key)":"\#(fill[key] ?? "")""#
            }
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    static func prompt(_ source: String) -> [Int] { TinyTokenizer().encode(text: "Transcript: \(source)\nOutput:", addSpecialTokens: false) }

    private func plain(_ item: Case, cache: GrammarCache) throws -> Outcome {
        let prompt = Self.prompt(item.source)
        let model = ScriptedSpeculativeModel(target: item.target, junk: item.junk, trimmable: true, promptLength: prompt.count)
        let result = try cache.withConstraint(for: item.schema) { constraint, commits in
            var decoder = GuidedJSONDecoder(
                model: model, constraint: constraint, endTokens: [TinyVocab.eos],
                grammarVocabSize: TinyVocab.strings.count, temperature: nil, maxSampledTokens: 4000)
            decoder.commits = commits
            decoder.checkpoint = {}
            return try decoder.decode(prompt: prompt)
        }
        return Outcome(result: result, passes: model.forwardPasses, stats: nil, model: model)
    }

    private func speculative(
        _ item: Case, cache: GrammarCache, trimmable: Bool, settings: SpeculationSettings = SpeculationSettings(),
        costs: PassCostModel = .m4ProDefault, maxTokens: Int = 4000, rewindableAnswerTokens: Int? = nil,
        checkpoint: @escaping () throws -> Void = {}
    ) throws -> Outcome {
        let prompt = Self.prompt(item.source)
        let model = ScriptedSpeculativeModel(target: item.target, junk: item.junk, trimmable: trimmable, promptLength: prompt.count)
        model.rewindableTokens = rewindableAnswerTokens.map { prompt.count + $0 }
        let (result, stats) = try cache.withConstraint(for: item.schema) { constraint, commits in
            var decoder = SpeculativeJSONDecoder(
                model: model, constraint: constraint, endTokens: [TinyVocab.eos],
                grammarVocabSize: TinyVocab.strings.count, temperature: nil, maxSampledTokens: maxTokens, settings: settings,
                costs: costs)
            decoder.commits = commits
            decoder.checkpoint = checkpoint
            decoder.onDraft = { draft in try Self.expectGrammarValid(draft, constraint) }
            return try decoder.decode(prompt: prompt, draftSource: TinyTokenizer().encode(text: item.source, addSpecialTokens: false))
        }
        return Outcome(result: result, passes: model.forwardPasses, stats: stats, model: model)
    }

    /// Walks `draft` through the matcher (as the decoder built it: forced tokens spliced after the
    /// token that triggered them) — any rejection throws — then rolls back.
    static func expectGrammarValid(_ draft: [Int], _ constraint: GrammarConstraint) throws {
        var index = 0
        var commits = 0
        while index < draft.count {
            let commit = try constraint.commitToken(Int32(draft[index]))
            commits += 1 + commit.tokens.count
            let jumped = commit.tokens.map(Int.init)
            let spliced = Array(draft[(index + 1)..<min(draft.count, index + 1 + jumped.count)])
            #expect(spliced == Array(jumped.prefix(spliced.count)), "forced tokens not spliced as the grammar forces them")
            index += 1 + jumped.count
        }
        try constraint.rollback(Int32(commits))
    }

    @Test("greedy output is byte-identical with and without speculation, for both cache kinds", arguments: [true, false])
    func identicalGreedyOutput(trimmable: Bool) throws {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        for item in Self.cases {
            let baseline = try plain(item, cache: cache)
            let fast = try speculative(item, cache: cache, trimmable: trimmable)
            #expect(fast.result == baseline.result, "\(item.name): \(TinyVocab.text(fast.result.tokens)) vs \(TinyVocab.text(baseline.result.tokens))")
            #expect(TinyVocab.text(fast.result.tokens) == item.target || !item.junk.isEmpty, "\(item.name)")
            // The scripted model conditions on everything it was fed, so a wrong re-feed after a
            // rewind would change its answer — equality above also checks the rollback.
            #expect(fast.passes <= baseline.passes, "\(item.name): \(fast.passes) passes vs \(baseline.passes)")
        }
        #expect(cache.compilations == Set(Self.cases.map(\.schema.name)).count)
    }

    @Test("copy-heavy answers need far fewer forward passes")
    func fewerPasses() throws {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        for name in ["clean copy", "tool envelope"] {
            guard let item = Self.cases.first(where: { $0.name == name }) else { continue }
            let baseline = try plain(item, cache: cache)
            let fast = try speculative(item, cache: cache, trimmable: false)
            let stats = try #require(fast.stats)
            #expect(Double(fast.passes) < Double(baseline.passes) * 0.5, "\(name): \(fast.passes) vs \(baseline.passes) passes")
            #expect(stats.acceptedDraftTokens > 0 && stats.acceptanceRate > 0.5, "\(name): \(stats)")
            #expect(stats.forwardPasses == fast.passes)
        }
    }

    @Test("rejected drafts roll back: recurrent caches return to the mark and re-feed, attention caches trim")
    func rollback() throws {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        guard let item = Self.cases.first(where: { $0.name == "clean edits" }) else { return }
        let baseline = try plain(item, cache: cache)
        let recurrent = try speculative(item, cache: cache, trimmable: false)
        let attention = try speculative(item, cache: cache, trimmable: true)
        for outcome in [recurrent, attention] {
            #expect(outcome.result == baseline.result)
            #expect(outcome.model.rewinds > 0, "the edits should reject some drafts")
        }
        #expect((recurrent.stats?.refedTokens ?? 0) > 0)
        #expect(attention.stats?.refedTokens == 0)
    }

    @Test("no draft is fed once the cache could not take it back (a sliding-window cache about to wrap)")
    func noDraftPastTheRewindLimit() throws {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        guard let item = Self.cases.first(where: { $0.name == "clean copy" }) else { return }
        let baseline = try plain(item, cache: cache)
        let free = try speculative(item, cache: cache, trimmable: true)
        // The window fills part-way through the answer: drafting stops there and the plain loop finishes.
        let partway = try speculative(item, cache: cache, trimmable: true, rewindableAnswerTokens: 24)
        // The window is already full when the answer starts: no draft at all, one pass per sampled token.
        let never = try speculative(item, cache: cache, trimmable: true, rewindableAnswerTokens: 0)
        for outcome in [partway, never] {
            #expect(outcome.result == baseline.result)
            #expect(outcome.model.unrewindableDraftPasses == 0)
        }
        #expect((partway.stats?.draftRounds ?? 0) > 0)
        #expect(partway.passes > free.passes && partway.passes < baseline.passes, "\(free.passes) < \(partway.passes) < \(baseline.passes)")
        #expect(never.stats?.draftRounds == 0)
        #expect(never.passes == baseline.passes)
    }

    @Test("drafts are cut where the grammar would reject them; answers still match")
    func grammarCutsDrafts() throws {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        // After "ship it" the source has a quote and a newline: a closing quote is valid JSON,
        // but what follows it (a space, not `}`) and a raw newline inside a string are not.
        let items = [
            Case(name: "quote", schema: SmartCleaner.cleanedSchema, source: #"ship it" now then"#, target: #"{"text":"ship it now then"}"#),
            Case(name: "newline", schema: SmartCleaner.cleanedSchema, source: "line one\nline two", target: #"{"text":"line one line two"}"#),
        ]
        var cut = 0
        for item in items {
            let baseline = try plain(item, cache: cache)
            // Passes cost the same at any length here, so drafts run as long as the source allows.
            let fast = try speculative(
                item, cache: cache, trimmable: false, settings: SpeculationSettings(maxDraftTokens: 12),
                costs: PassCostModel(tokens: [1, 64], relativeCost: [1, 1]))
            #expect(fast.result == baseline.result, "\(item.name)")
            cut += fast.stats?.grammarTrimmedDraftTokens ?? 0
        }
        #expect(cut > 0)
        // The matcher is at its start state after all of that.
        let again = try plain(Self.cases[0], cache: cache)
        #expect(TinyVocab.text(again.result.tokens) == Self.cases[0].target)
    }

    @Test("cancellation mid-speculation throws before the next pass and leaves the grammar reusable", arguments: [true, false])
    func cancellation(trimmable: Bool) throws {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        guard let item = Self.cases.first(where: { $0.name == "clean edits" }) else { return }
        for cancelAt in 2...5 {
            var passes = 0
            #expect(throws: CancellationError.self) {
                _ = try speculative(item, cache: cache, trimmable: trimmable) {
                    passes += 1
                    if passes >= cancelAt { throw CancellationError() }
                }
            }
            #expect(passes == cancelAt)
            let after = try speculative(item, cache: cache, trimmable: trimmable)
            #expect(TinyVocab.text(after.result.tokens) == item.target, "cancelled at pass \(cancelAt)")
        }
        #expect(cache.compilations == 1)
    }

    @Test("the token budget throws exactly as the plain loop does")
    func budget() throws {
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        let long = String(repeating: "ab ", count: 60)
        let item = Case(name: "long", schema: SmartCleaner.cleanedSchema, source: long, target: #"{"text":"\#(long)"}"#)
        #expect(throws: LanguageModelError.self) { _ = try speculative(item, cache: cache, trimmable: false, maxTokens: 40) }
        // At the exact budget both loops agree on success.
        let plainRun = try plain(item, cache: cache)
        let exact = try speculative(item, cache: cache, trimmable: false, maxTokens: plainRun.result.sampled)
        #expect(exact.result == plainRun.result)
    }

    @Test("prompt lookup follows the cursor; the answer's own rhythm predicts empty arguments")
    func drafter() {
        // " a" occurs twice; after accepting a copy near the end, the later occurrence wins.
        var drafter = PromptLookupDrafter(source: [1, 2, 3, 9, 2, 4], maxNgram: 3)
        #expect(drafter.guess(output: [2], chosen: [2]) == .init(token: 3, sourceIndex: 2))
        drafter.didAccept(.init(token: 9, sourceIndex: 3))
        #expect(drafter.guess(output: [2], chosen: [2]) == .init(token: 4, sourceIndex: 5))
        // Longer n-grams win over the cursor.
        #expect(drafter.guess(output: [1, 2], chosen: []) == .init(token: 3, sourceIndex: 2))
        // No prompt match: the most recent continuation of the last two choices in their own history.
        #expect(drafter.guess(output: [50, 71], chosen: [70, 71, 72, 70, 71, 74, 70, 71]) == .init(token: 74, sourceIndex: nil, kind: .history))
        // One matching choice is not enough (prose would echo its own earlier words).
        #expect(drafter.guess(output: [50, 70], chosen: [70, 80, 55, 70]) == nil)
        #expect(drafter.guess(output: [50], chosen: [50]) == nil)
    }

    @Test("word-level lookup re-syncs after punctuation and proposes the capitalised spelling after a sentence end")
    func wordLevelLookup() {
        let texts = WordTexts(words: [" so", " we", " ship", " friday", ".", " So", "Ship", " We"])
        // Source " so we ship friday"; the answer so far "… ship." — a sentence ended after "ship".
        let drafter = PromptLookupDrafter(source: [0, 1, 2, 3], texts: texts)
        // " Friday" is not one token in this vocabulary, so the source spelling is proposed.
        #expect(drafter.guess(output: [2, 4], chosen: [2, 4]) == .init(token: 3, sourceIndex: 3, kind: .promptWord))
        // "Ship" (capital, no space) matches " ship" by word.
        #expect(drafter.guess(output: [6], chosen: [6]) == .init(token: 3, sourceIndex: 3, kind: .promptWord))
        // After "so." the next source word " we" is proposed capitalised.
        let second = PromptLookupDrafter(source: [0, 1, 2], texts: texts)
        #expect(second.guess(output: [0, 4], chosen: [0, 4]) == .init(token: 7, sourceIndex: 1, kind: .promptWord))
    }

    @Test("draft length follows the pass-cost curve: short when passes get dearer per token, long when they flatten")
    func draftLengthPolicy() {
        let costs = PassCostModel.m4ProDefault
        #expect(costs.cost(1) == 1 && costs.cost(40) == costs.cost(21))
        #expect(abs(costs.cost(11) - (3.85 + 3.91) / 2) < 0.001)
        let shaky = costs.bestDraftLength(first: 0.3, next: 0.5, pending: 1, maxDraft: 15)
        let steady = costs.bestDraftLength(first: 0.95, next: 0.95, pending: 1, maxDraft: 15)
        #expect(shaky <= 1)
        #expect(steady >= 10)
        #expect(costs.bestDraftLength(first: 0.95, next: 0.95, pending: 1, maxDraft: 5) == 5)
        var acceptance = DraftAcceptance()
        let before = acceptance.first(.promptWord)
        acceptance.record(kind: .promptWord, accepted: 0, drafted: 3)
        #expect(acceptance.first(.promptWord) < before)
        #expect(acceptance.first(.prompt) == 0.8)
    }

    @Test("verification rows reuse the unmasked argmax only when the grammar allows it")
    func rowShortcut() {
        let mask: [Int32] = [Int32(bitPattern: 0b1010)]
        #expect(MLXRowDistribution.allows(mask, 1, grammarVocabSize: 32))
        #expect(!MLXRowDistribution.allows(mask, 2, grammarVocabSize: 32))
        #expect(!MLXRowDistribution.allows(mask, 3, grammarVocabSize: 2))
        #expect(!MLXRowDistribution.allows(mask, 40, grammarVocabSize: 64))
        #expect(MLXRowDistribution.allows(nil, 40, grammarVocabSize: 64))
    }

    @Test("HUSHY_MLX_SPECULATE parsing")
    func environment() {
        #expect(SpeculationSettings.fromEnvironment(nil) == nil)
        #expect(SpeculationSettings.fromEnvironment("off") == nil)
        #expect(SpeculationSettings.fromEnvironment("on") == SpeculationSettings())
        #expect(SpeculationSettings.fromEnvironment("12")?.maxDraftTokens == 12)
        let configuration = MLXLanguageModel.Configuration.fromEnvironment(["HUSHY_MLX_MODEL_DIR": "/tmp/m", "HUSHY_MLX_SPECULATE": "on"])
        #expect(configuration?.speculation != nil)
    }
}

/// A toy vocabulary of whole words for word-level lookup tests.
final class WordTexts: TokenTexts {
    let words: [String]
    init(words: [String]) { self.words = words }
    func text(of token: Int) -> String { words.indices.contains(token) ? words[token] : "" }
    func token(spelling text: String) -> Int? { words.firstIndex(of: text) }
}
