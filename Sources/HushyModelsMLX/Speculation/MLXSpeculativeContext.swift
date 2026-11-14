import Foundation
import MLX
import MLXLMCommon
import MurmurCore

/// `SpeculativeTokenStepModel` over an MLX model and one KV cache (a copy of a cached prefix, or
/// a fresh cache). Like `MLXTokenContext`, it lives inside `MLXEngine`'s isolation.
///
/// Rewinding a hybrid cache (Qwen3.5: full-attention layers plus gated-delta "linear attention"
/// layers with a recurrent state):
/// - attention layers (`KVCacheSimple`, `QuantizedKVCache`) trim, which only moves the offset;
/// - a `MambaCache`'s conv/recurrent state cannot be cut at a token, so `mark()` keeps the state
///   arrays it holds before the pass. That costs nothing: the model assigns fresh arrays into the
///   cache after each pass rather than writing into these, and holding a reference stops MLX from
///   donating their buffers. A rewind puts them back and trims the attention layers to the same
///   point, so the whole cache is at the mark; the decoder then re-feeds the tokens it keeps.
final class MLXSpeculativeContext: SpeculativeTokenStepModel {
    private struct Mark {
        var fedTokens: Int
        /// (layer index, state arrays, offset) for each non-trimmable layer.
        var recurrent: [(index: Int, state: [MLXArray], offset: Int)]
    }

    private let model: any MLXLMCommon.LanguageModel
    private let cache: [KVCache]
    private var current: Mark?
    private(set) var fedTokens = 0
    /// (tokens fed, milliseconds) per forward pass, prompt pass included.
    private(set) var passTimings: [(tokens: Int, milliseconds: Double)] = []

    init(model: any MLXLMCommon.LanguageModel, cache: [KVCache]) {
        self.model = model
        self.cache = cache
    }

    /// Whether every layer cache can be rewound exactly after `count` more tokens (trimmable, or a
    /// two-array `MambaCache`). A sliding-window `RotatingKVCache` (Gemma 4, 512 tokens) stops being
    /// trimmable once it wraps: a trim there cannot bring back the rows the rewound pass overwrote.
    static func supports(_ cache: [KVCache], afterFeeding count: Int = 0) -> Bool {
        cache.allSatisfy { $0 is MambaCache || $0.isTrimmable(after: count) }
    }

    func canRewind(afterFeeding count: Int) -> Bool {
        Self.supports(cache, afterFeeding: count)
    }

    func append(_ tokens: [Int]) throws -> any NextTokenDistribution {
        guard let last = try append(tokens, rows: 1).last else { throw LanguageModelError.malformedOutput("empty prompt") }
        return last
    }

    func append(_ tokens: [Int], rows: Int) throws -> [any NextTokenDistribution] {
        guard !tokens.isEmpty, rows >= 1, rows <= tokens.count else {
            throw LanguageModelError.malformedOutput("speculative append: \(tokens.count) tokens, \(rows) rows")
        }
        let start = ContinuousClock.now
        let (block, best) = try withError {
            let output = model(MLXArray(tokens.map(Int32.init))[.newAxis], cache: cache)
            let block = output[0, (tokens.count - rows)...].asType(.float32)
            let best = argMax(block, axis: -1)
            eval(block, best)
            return (block, best)
        }
        fedTokens += tokens.count
        let bestIds = best.asArray(Int32.self)
        passTimings.append((tokens.count, MLXEngine.milliseconds(since: start)))
        return (0..<rows).map { MLXRowDistribution(logits: block[$0], unmaskedBest: Int(bestIds[$0])) }
    }

    func mark() {
        var recurrent: [(index: Int, state: [MLXArray], offset: Int)] = []
        for (index, entry) in cache.enumerated() where !entry.isTrimmable {
            recurrent.append((index, entry.state, entry.offset))
        }
        current = Mark(fedTokens: fedTokens, recurrent: recurrent)
    }

    func rewind(keeping keep: Int) -> Int {
        guard let mark = current else { return 0 }
        current = nil
        let fedSince = fedTokens - mark.fedTokens
        let keep = max(0, min(keep, fedSince))
        if mark.recurrent.isEmpty {
            for entry in cache { entry.trim(fedSince - keep) }
            fedTokens -= fedSince - keep
            return keep
        }
        for entry in cache where entry.isTrimmable { entry.trim(fedSince) }
        for saved in mark.recurrent {
            var entry = cache[saved.index]
            entry.state = saved.state
            (entry as? BaseKVCache)?.offset = saved.offset
        }
        fedTokens = mark.fedTokens
        return 0
    }

    func releaseMark() {
        current = nil
    }

    /// Measures this chip's pass-cost curve on `cache` (a warm prefix): each size is timed after
    /// a mark and rewound, so the cache ends exactly as it started. ~12 short passes (~0.2–0.3 s
    /// on an M4 Pro for a 2B model); nil if anything fails (callers fall back to the default).
    static func calibrate(
        model: any MLXLMCommon.LanguageModel, cache: [KVCache], counts: [Int] = [1, 2, 4, 8, 12, 16], repeats: Int = 2
    ) -> PassCostModel? {
        // A fresh cache (no prefix) has no recurrent state to restore to yet.
        guard supports(cache, afterFeeding: counts.max() ?? 0), !cache.isEmpty,
              cache.allSatisfy({ !($0 is MambaCache) || $0.state.count == 2 }) else { return nil }
        let token = 13
        let context = MLXSpeculativeContext(model: model, cache: cache)
        var medians: [Double] = []
        do {
            for count in [1] + counts {  // the first size is a warm-up
                var times: [Double] = []
                for _ in 0..<repeats {
                    context.mark()
                    _ = try context.append(Array(repeating: token, count: count), rows: count)
                    times.append(context.passTimings.last?.milliseconds ?? 0)
                    _ = context.rewind(keeping: 0)
                }
                medians.append(times.min() ?? 0)
            }
        } catch {
            MLXLog.model.error("mlx pass-cost calibration failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        let model = PassCostModel(tokens: counts, relativeCost: Array(medians.dropFirst()))
        MLXLog.model.info("mlx pass-cost calibration \(zip(counts, medians.dropFirst()).map { "\($0)=\(Int($1 * 10) / 10)ms" }.joined(separator: " "), privacy: .public)")
        return model
    }
}

/// One row of a verification pass. Greedy picks reuse the row's unmasked argmax (computed for all
/// rows in the same GPU evaluation) whenever the grammar allows it — then it is also the masked
/// argmax, ties included, since argmax returns the first maximum — and only fall back to masking
/// the row when it doesn't.
struct MLXRowDistribution: NextTokenDistribution {
    let logits: MLXArray
    let unmaskedBest: Int

    func choose(mask: [Int32]?, grammarVocabSize: Int, temperature: Float?) -> Int {
        let greedy = temperature.map { $0 <= 0 } ?? true
        if greedy, Self.allows(mask, unmaskedBest, grammarVocabSize: grammarVocabSize) { return unmaskedBest }
        return MLXDistribution(logits: logits).choose(mask: mask, grammarVocabSize: grammarVocabSize, temperature: temperature)
    }

    static func allows(_ mask: [Int32]?, _ token: Int, grammarVocabSize: Int) -> Bool {
        guard let mask else { return true }
        guard token >= 0, token < grammarVocabSize, token / 32 < mask.count else { return false }
        return (UInt32(bitPattern: mask[token / 32]) >> UInt32(token % 32)) & 1 == 1
    }
}

/// `TokenTexts` over the model's tokenizer (single-token decode / encode).
final class TokenizerTexts: TokenTexts {
    private let tokenizer: any MLXLMCommon.Tokenizer

    init(_ tokenizer: any MLXLMCommon.Tokenizer) {
        self.tokenizer = tokenizer
    }

    func text(of token: Int) -> String {
        tokenizer.decode(tokenIds: [token], skipSpecialTokens: false)
    }

    func token(spelling text: String) -> Int? {
        let ids = tokenizer.encode(text: text, addSpecialTokens: false)
        return ids.count == 1 ? ids[0] : nil
    }
}
