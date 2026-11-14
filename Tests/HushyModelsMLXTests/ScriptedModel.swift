import Foundation
import MLXGuidedGeneration
import MLXLMCommon
@testable import HushyModelsMLX

/// A tiny vocabulary for driving the real XGrammar matcher in tests: ids 0–127 are the ASCII
/// characters, then a few multi-character pieces (so a token can carry a closing quote and what
/// follows it, as BPE tokens do), then EOS.
enum TinyVocab {
    static let pieces = [#".""#, #"."}"#, #"", "#, "Hel", "lo", #"\""#, "true", "both"]
    static let eos = 128 + pieces.count
    static let strings: [String] = (0..<128).map { String(UnicodeScalar(UInt8($0))) } + pieces + ["<eos>"]

    static func grammarTokenizer() throws -> GrammarTokenizer {
        try GrammarTokenizer(vocab: strings, vocabType: .raw, eosTokenId: Int32(eos))
    }

    static func text(_ tokens: [Int]) -> String {
        tokens.filter { $0 != eos }.map { strings[$0] }.joined()
    }
}

/// Character-level host tokenizer over `TinyVocab` (what jump-forward re-encodes with).
struct TinyTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { TinyVocab.text(tokenIds) }
    func convertTokenToId(_ token: String) -> Int? { TinyVocab.strings.firstIndex(of: token) }
    func convertIdToToken(_ id: Int) -> String? { TinyVocab.strings.indices.contains(id) ? TinyVocab.strings[id] : nil }
    var bosToken: String? { nil }
    var eosToken: String? { "<eos>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
}

/// A fake LM that "wants" to write `target` (compact JSON), preferring the longest vocabulary
/// piece that continues it; once its context leaves `target` it prefers `junk`'s characters.
/// Whatever it prefers, it can only pick what the grammar mask allows.
final class ScriptedModel: TokenStepModel {
    let target: String
    let junk: String
    private(set) var context = ""
    private(set) var forwardPasses = 0
    private(set) var feeds: [[Int]] = []

    init(target: String, junk: String = "") {
        self.target = target
        self.junk = junk
    }

    func append(_ tokens: [Int]) throws -> any NextTokenDistribution {
        forwardPasses += 1
        feeds.append(tokens)
        context += TinyVocab.text(tokens)
        return Distribution(preference: Self.preference(context: context, target: target, junk: junk))
    }

    /// Longest vocabulary piece continuing `target` after `context`, then its next character;
    /// EOS once `target` is complete; then `junk`'s characters.
    static func preference(context: String, target: String, junk: String) -> [Int] {
        let rest = target.hasPrefix(context) ? String(target.dropFirst(context.count)) : ""
        var preference: [Int] = []
        if let next = rest.unicodeScalars.first {
            preference += (128..<TinyVocab.eos).filter { rest.hasPrefix(TinyVocab.strings[$0]) }
                .sorted { TinyVocab.strings[$0].count > TinyVocab.strings[$1].count }
            preference.append(Int(next.value))
        } else if target.hasPrefix(context) {
            preference.append(TinyVocab.eos)
        }
        return preference + junk.unicodeScalars.map { Int($0.value) }
    }

    struct Distribution: NextTokenDistribution {
        let preference: [Int]

        func choose(mask: [Int32]?, grammarVocabSize: Int, temperature: Float?) -> Int {
            func allowed(_ id: Int) -> Bool {
                guard let mask else { return true }
                return (UInt32(bitPattern: mask[id / 32]) >> UInt32(id % 32)) & 1 == 1
            }
            if let choice = preference.first(where: allowed) { return choice }
            return (0..<grammarVocabSize).first(where: allowed) ?? TinyVocab.eos
        }
    }
}
