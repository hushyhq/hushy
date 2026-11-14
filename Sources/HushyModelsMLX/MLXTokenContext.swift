import Foundation
import MLX
import MLXLMCommon
import MurmurCore

/// `TokenStepModel` over an MLX model and one KV cache (a copy of a cached instruction prefix,
/// or a fresh cache). Lives entirely inside `MLXEngine`'s isolation; `MLXArray`s never escape.
final class MLXTokenContext: TokenStepModel {
    private let model: any MLXLMCommon.LanguageModel
    private let cache: [KVCache]
    private(set) var fedTokens = 0
    /// Measurement only (`murmur-eval intent-app --ab argmax`): false masks every row on the CPU first, as before.
    private let reusesArgmax: Bool

    init(model: any MLXLMCommon.LanguageModel, cache: [KVCache], reusesArgmax: Bool = true) {
        self.model = model
        self.cache = cache
        self.reusesArgmax = reusesArgmax
    }

    /// The row's unmasked argmax is evaluated with the forward pass. A greedy pick the grammar allows is that token
    /// (`MLXRowDistribution`), so most steps need no mask on the GPU and no second evaluation. Same token as masking
    /// first: argmax returns the first maximum, and masking only lowers other entries.
    func append(_ tokens: [Int]) throws -> any NextTokenDistribution {
        guard !tokens.isEmpty else { throw LanguageModelError.malformedOutput("empty prompt") }
        guard reusesArgmax else { return try appendMaskingFirst(tokens) }
        let (row, best) = try withError {
            let output = model(MLXArray(tokens.map(Int32.init))[.newAxis], cache: cache)
            let row = output[0, -1].asType(.float32)
            let best = argMax(row)
            eval(row, best)
            return (row, best.item(Int.self))
        }
        fedTokens += tokens.count
        return MLXRowDistribution(logits: row, unmaskedBest: best)
    }

    private func appendMaskingFirst(_ tokens: [Int]) throws -> any NextTokenDistribution {
        let logits = try withError {
            let output = model(MLXArray(tokens.map(Int32.init))[.newAxis], cache: cache)
            let row = output[0, -1].asType(.float32)
            eval(row)
            return row
        }
        fedTokens += tokens.count
        return MLXDistribution(logits: logits)
    }
}

struct MLXDistribution: NextTokenDistribution {
    let logits: MLXArray

    func choose(mask: [Int32]?, grammarVocabSize: Int, temperature: Float?) -> Int {
        var scores = logits
        if let mask {
            scores = scores + Self.additiveMask(mask, grammarVocabSize: grammarVocabSize, logitCount: logits.dim(0))
        }
        if let temperature, temperature > 0 {
            return categorical(scores / MLXArray(temperature)).item(Int.self)
        }
        return argMax(scores).item(Int.self)
    }

    static func additiveMask(_ mask: [Int32], grammarVocabSize: Int, logitCount: Int) -> MLXArray {
        MLXArray(additiveMaskValues(mask, grammarVocabSize: grammarVocabSize, logitCount: logitCount))
    }

    /// 0 for allowed tokens, -inf elsewhere (including logits beyond the grammar vocabulary).
    static func additiveMaskValues(_ mask: [Int32], grammarVocabSize: Int, logitCount: Int) -> [Float] {
        var values = [Float](repeating: -.infinity, count: logitCount)
        let limit = min(grammarVocabSize, logitCount)
        for (word, bits) in mask.enumerated() where bits != 0 {
            var remaining = UInt32(bitPattern: bits)
            while remaining != 0 {
                let index = word * 32 + remaining.trailingZeroBitCount
                if index < limit { values[index] = 0 }
                remaining &= remaining - 1
            }
        }
        return values
    }
}
