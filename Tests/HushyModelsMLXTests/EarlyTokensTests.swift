import Foundation
import Testing
@testable import HushyModelsMLX
@testable import MurmurCore

/// The tokens-by-250-ms speed figure: the counting function, the recorder, and the decoders' emission hooks.
@Suite("MLX tokens by 250 ms")
struct EarlyTokensTests {
    private func emission(_ offset: Double, sampled: Int = 1, forced: Int = 0) -> EarlyTokens.Emission {
        .init(offsetMilliseconds: offset, sampled: sampled, forced: forced)
    }

    @Test("the window is 250 ms")
    func windowIsNamed() {
        #expect(EarlyTokens.windowMilliseconds == 250)
    }

    @Test("the rate is per second over the window, or over the call when it ended inside the window")
    func perSecond() {
        #expect(EarlyTokens.perSecond(tokens: 30, totalMilliseconds: 430) == 120)
        #expect(EarlyTokens.perSecond(tokens: 19, totalMilliseconds: 100) == 190)
        #expect(EarlyTokens.perSecond(tokens: 0, totalMilliseconds: 1_700) == 0)
        #expect(EarlyTokens.perSecond(tokens: 5, totalMilliseconds: 0) == 0)
    }

    @Test("nothing emitted by the window counts zero")
    func nothingEarly() {
        #expect(EarlyTokens.count([]) == .init(total: 0, sampled: 0))
        #expect(EarlyTokens.count([emission(250.5), emission(900, sampled: 3, forced: 2)]) == .init(total: 0, sampled: 0))
    }

    @Test("everything emitted inside the window counts, sampled and forced apart")
    func everythingEarly() {
        let emissions = [emission(10, sampled: 0, forced: 3), emission(40), emission(80, sampled: 1, forced: 2), emission(249.9)]
        #expect(EarlyTokens.count(emissions) == .init(total: 8, sampled: 3))
    }

    @Test("a token exactly at the limit counts; just past it does not")
    func boundary() {
        #expect(EarlyTokens.count([emission(250)]) == .init(total: 1, sampled: 1))
        #expect(EarlyTokens.count([emission(250.0001)]) == .init(total: 0, sampled: 0))
        #expect(EarlyTokens.count([emission(100), emission(250), emission(250.0001)]).total == 2)
    }

    @Test("speculation emitting several tokens in one pass counts them all at that pass's time")
    func speculationBatch() {
        let early = EarlyTokens.count([emission(120, sampled: 4, forced: 2), emission(240, sampled: 5, forced: 1), emission(260, sampled: 5, forced: 1)])
        #expect(early == .init(total: 12, sampled: 9))
    }

    @Test("a different window is honoured")
    func customWindow() {
        let emissions = [emission(50), emission(120)]
        #expect(EarlyTokens.count(emissions, windowMilliseconds: 100).total == 1)
    }

    @Test("the recorder counts what arrives inside the window and stops reading the clock after it")
    func recorder() async throws {
        var recorder = EarlyTokenRecorder(start: .now, windowMilliseconds: 40)
        recorder.record(sampled: 2, forced: 1)
        try await Task.sleep(for: .milliseconds(120))
        recorder.record(sampled: 5, forced: 5)
        recorder.record(sampled: 5, forced: 5)
        #expect(recorder.count == .init(total: 3, sampled: 2))
    }

    @Test("both decoders report every emitted token exactly once, the end token not at all", arguments: [true, false])
    func decodersEmitEveryToken(speculative: Bool) throws {
        let source = "the import fails on files over two gigs so we should stream it in chunks"
        let target = #"{"text":"the import fails on files over two gigs so we should stream it in chunks"}"#
        let prompt = TinyTokenizer().encode(text: "Transcript: \(source)\nOutput:", addSpecialTokens: false)
        let cache = GrammarCache(tokenizer: try TinyVocab.grammarTokenizer(), hostTokenizer: TinyTokenizer())
        var batches: [(sampled: Int, forced: Int)] = []
        let model = ScriptedSpeculativeModel(target: target, junk: "", trimmable: false, promptLength: prompt.count)
        let result = try cache.withConstraint(for: SmartCleaner.cleanedSchema) { constraint, commits in
            if speculative {
                var decoder = SpeculativeJSONDecoder(
                    model: model, constraint: constraint, endTokens: [TinyVocab.eos],
                    grammarVocabSize: TinyVocab.strings.count, temperature: nil, maxSampledTokens: 4000)
                decoder.commits = commits
                decoder.onEmit = { batches.append(($0, $1)) }
                return try decoder.decode(prompt: prompt, draftSource: TinyTokenizer().encode(text: source, addSpecialTokens: false)).result
            }
            var decoder = GuidedJSONDecoder(
                model: model, constraint: constraint, endTokens: [TinyVocab.eos],
                grammarVocabSize: TinyVocab.strings.count, temperature: nil, maxSampledTokens: 4000)
            decoder.commits = commits
            decoder.onEmit = { batches.append(($0, $1)) }
            return try decoder.decode(prompt: prompt)
        }
        #expect(batches.reduce(0) { $0 + $1.sampled + $1.forced } == result.tokens.count)
        // `result.sampled` also counts the end-of-sequence choice when the model made one; that is not an answer token.
        let sampledEmitted = batches.reduce(0) { $0 + $1.sampled }
        #expect(sampledEmitted == result.sampled || sampledEmitted == result.sampled - 1)
        if speculative {
            #expect(batches.contains { $0.sampled > 1 }, "accepted drafts should land several sampled tokens in one pass")
        } else {
            #expect(batches.allSatisfy { $0.sampled <= 1 })
        }
    }
}
