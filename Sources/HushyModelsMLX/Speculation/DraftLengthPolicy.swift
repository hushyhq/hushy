import Foundation

/// Forward-pass cost by number of tokens fed, relative to a one-token pass, and the draft length
/// that maximises expected tokens per unit of cost.
///
/// Why a cost curve and not a fixed draft length: on Apple GPUs a pass is not "free" for a few
/// extra tokens. MLX runs quantized matmuls as matrix-vector kernels up to a per-chip, per-shape
/// row limit (`get_qmv_batch_limit`: 6–32 rows) and each extra row re-reads the weights, so cost
/// grows ~linearly with tokens (Qwen3.5-2B 4-bit on an M4 Pro: +33% of a one-token pass per
/// token); past the limit a tiled matmul takes over and cost goes flat (~4× a one-token pass up to
/// 20+ tokens). So a draft should be short (2–3) when guesses are shaky and long (15) when a copy
/// run is going well — and where the kink sits differs between an M1 and an M4, which is why the
/// engine measures the curve at prewarm (`MLXSpeculativeContext.calibrate`) instead of trusting
/// this default.
struct PassCostModel: Sendable, Equatable {
    /// Tokens fed per pass, ascending, and the matching relative cost (1 token = 1.0).
    let tokens: [Int]
    let relativeCost: [Double]

    init(tokens: [Int], relativeCost: [Double]) {
        let pairs = zip(tokens, relativeCost).filter { $0.0 >= 1 && $0.1 > 0 }.sorted { $0.0 < $1.0 }
        let base = pairs.first(where: { $0.0 == 1 })?.1 ?? pairs.first?.1 ?? 1
        self.tokens = pairs.map(\.0)
        self.relativeCost = pairs.map { $0.1 / base }
    }

    /// Measured on an M4 Pro (24 GB), Qwen3.5-2B 4-bit, mlx-swift 0.31.6, warm 2k-token prefix.
    static let m4ProDefault = PassCostModel(
        tokens: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 16, 21],
        relativeCost: [1.0, 1.17, 1.46, 1.78, 2.12, 2.46, 2.84, 3.17, 3.7, 3.85, 3.91, 4.02, 4.04])

    /// Relative cost of a pass feeding `count` tokens (piecewise linear; flat past the last point).
    func cost(_ count: Int) -> Double {
        guard let first = tokens.first, let last = tokens.last else { return Double(max(1, count)) }
        if count <= first { return relativeCost[0] }
        if count >= last { return relativeCost[relativeCost.count - 1] }
        guard let upper = tokens.firstIndex(where: { $0 >= count }) else { return relativeCost[relativeCost.count - 1] }
        if tokens[upper] == count { return relativeCost[upper] }
        let lower = upper - 1
        let t = Double(count - tokens[lower]) / Double(tokens[upper] - tokens[lower])
        return relativeCost[lower] + t * (relativeCost[upper] - relativeCost[lower])
    }

    /// Draft tokens (0…`maxDraft`) maximising expected emitted tokens per cost, when `pending`
    /// tokens must be fed anyway, the first draft token is accepted with probability `first`, and
    /// each later one with probability `next` given the ones before it. 0 = don't speculate.
    func bestDraftLength(first: Double, next: Double, pending: Int, maxDraft: Int) -> Int {
        let a0 = min(max(first, 0), 0.995)
        let a = min(max(next, 0), 0.995)
        var best = (length: 0, rate: 1 / cost(max(1, pending)))
        var expected = 1.0
        var chain = a0
        for length in stride(from: 1, through: max(0, maxDraft), by: 1) {
            expected += chain
            chain *= a
            let rate = expected / cost(max(1, pending) + length)
            if rate > best.rate * 1.0001 { best = (length, rate) }
        }
        return best.length
    }
}

/// Running estimate of how often a draft token is accepted given the ones before it were: every
/// accepted token is a success; a chain that broke before its end is one failure.
struct AcceptanceEstimate: Sendable, Equatable {
    private(set) var successes: Double
    private(set) var failures: Double

    init(prior: Double = 0.8, weight: Double = 5) {
        successes = prior * weight
        failures = (1 - prior) * weight
    }

    var value: Double { successes / (successes + failures) }

    mutating func record(accepted: Int, drafted: Int) {
        guard drafted > 0 else { return }
        successes += Double(accepted)
        if accepted < drafted { failures += 1 }
    }
}

/// Acceptance by where a draft's first guess came from (an exact prompt continuation is far more
/// reliable than a re-sync after an edit), plus one estimate for the tokens after the first.
struct DraftAcceptance: Sendable, Equatable {
    private var first: [PromptLookupDrafter.Guess.Kind: AcceptanceEstimate] = [
        .prompt: AcceptanceEstimate(prior: 0.8), .promptWord: AcceptanceEstimate(prior: 0.5), .history: AcceptanceEstimate(prior: 0.5),
    ]
    private(set) var next = AcceptanceEstimate(prior: 0.85)

    func first(_ kind: PromptLookupDrafter.Guess.Kind) -> Double { first[kind]?.value ?? 0.5 }

    /// `accepted` of `drafted` draft tokens were kept; the first came from `kind`.
    mutating func record(kind: PromptLookupDrafter.Guess.Kind, accepted: Int, drafted: Int) {
        guard drafted > 0 else { return }
        first[kind, default: AcceptanceEstimate(prior: 0.5)].record(accepted: min(accepted, 1), drafted: 1)
        if accepted >= 1, drafted > 1 { next.record(accepted: accepted - 1, drafted: drafted - 1) }
    }
}
