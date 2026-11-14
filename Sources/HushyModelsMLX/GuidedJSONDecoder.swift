import Foundation
import MLXGuidedGeneration
import MLXLMCommon
import MurmurCore

/// The next-token distribution after the tokens fed so far.
protocol NextTokenDistribution {
    /// The token to emit, restricted to `mask` (XGrammar's LSB-first bitmask over the grammar
    /// vocabulary; nil = no restriction). Greedy, or sampled at `temperature` when set.
    func choose(mask: [Int32]?, grammarVocabSize: Int, temperature: Float?) -> Int
}

/// A causal LM partway through one answer: feeding tokens appends them to its context (KV cache).
/// `MLXTokenContext` implements it over MLX; tests use a scripted fake.
protocol TokenStepModel: AnyObject {
    func append(_ tokens: [Int]) throws -> any NextTokenDistribution
}

/// Grammar-constrained decoding with XGrammar (`MLXGuidedGeneration.GrammarConstraint`).
///
/// We drive our own loop instead of `GuidedGenerationLoop.run` because that function always
/// builds a fresh KV cache and prefills the whole prompt; ours starts from a copy of the cached
/// instruction prefix and feeds only the call's own tokens. Per step: mask the logits with the
/// grammar, pick a token, commit it, and append whatever XGrammar jump-forwards (the forced JSON
/// structure) to the *same* next forward pass — a batch of tokens, not one pass each. The loop
/// ends as soon as the grammar allows nothing but end-of-sequence, without a forward pass for it.
struct GuidedJSONDecoder {
    struct Result: Equatable {
        var tokens: [Int]
        /// Tokens the model chose (forward passes after the prompt).
        var sampled: Int
        /// Tokens XGrammar forced by jump-forward (no sampling).
        var forced: Int
    }

    let model: any TokenStepModel
    let constraint: GrammarConstraint
    let endTokens: Set<Int>
    let grammarVocabSize: Int
    let temperature: Float?
    let maxSampledTokens: Int
    /// Counts tokens committed to `constraint`, so its owner can roll the matcher back.
    var commits = CommitCounter()
    /// Called before every forward pass; throws to stop (task cancellation).
    var checkpoint: () throws -> Void = { try Task.checkCancellation() }
    /// Called once, when the first token has been chosen (time to first token).
    var onFirstToken: (() -> Void)?
    /// Called each time tokens join the answer, with how many were sampled and how many forced
    /// (the end-of-sequence token is not one). The caller reads the clock; see `EarlyTokenRecorder`.
    var onEmit: ((_ sampled: Int, _ forced: Int) -> Void)?

    func decode(prompt: [Int]) throws -> Result {
        var pending = prompt
        var output: [Int] = []
        var sampled = 0
        var forced = 0
        var mask = try constraint.computeMask()
        while !mask.isTerminated, !mask.allowsOnly(endTokens) {
            // A grammar that allows exactly one token (e.g. the `}` jump-forward leaves to the
            // sampler) needs no forward pass: take it and feed it with whatever comes next.
            if let only = mask.onlyToken(), !endTokens.contains(only) {
                let commit = try constraint.commitToken(Int32(only))
                let jumped = commit.tokens.map(Int.init)
                commits.count += 1 + jumped.count
                forced += 1 + jumped.count
                output += [only] + jumped
                onEmit?(0, 1 + jumped.count)
                if commit.isTerminated { break }
                pending += [only] + jumped
                mask = try constraint.computeMask()
                continue
            }
            guard sampled < maxSampledTokens else {
                throw LanguageModelError.malformedOutput("MLX answer exceeded \(maxSampledTokens) tokens")
            }
            try checkpoint()
            let distribution = try model.append(pending)
            let token = distribution.choose(
                mask: mask.needsApply ? mask.mask : nil, grammarVocabSize: grammarVocabSize, temperature: temperature)
            if sampled == 0 { onFirstToken?() }
            sampled += 1
            if endTokens.contains(token) { break }
            let commit = try constraint.commitToken(Int32(token))
            let jumped = commit.tokens.map(Int.init)
            commits.count += 1 + jumped.count
            forced += jumped.count
            output += [token] + jumped
            onEmit?(1, jumped.count)
            if commit.isTerminated { break }
            pending = [token] + jumped
            mask = try constraint.computeMask()
        }
        return Result(tokens: output, sampled: sampled, forced: forced)
    }
}

final class CommitCounter {
    var count = 0
}

/// Compiles one `GrammarConstraint` per schema for a loaded model's vocabulary and reuses it:
/// XGrammar compilation (per-state token masks over a ~250k vocabulary) is the expensive part,
/// and the vendored xgrammar (v0.1.30) cannot fork matchers, so after every call the matcher is
/// rolled back to its start (unlimited rollback is xgrammar's default). If anything leaves the
/// matcher in doubt (an error other than cancellation, a failed rollback), the grammar is dropped
/// and recompiled on next use. Used only from `MLXEngine`'s serial isolation.
final class GrammarCache {
    let tokenizer: GrammarTokenizer
    private let hostTokenizer: any MLXLMCommon.Tokenizer
    /// Grammar for the tools-v1 envelope (`ToolEnvelopeGrammar`).
    let toolGrammar: ToolEnvelopeGrammar.Mode
    private var compiled: [String: GrammarConstraint] = [:]
    private(set) var compilations = 0

    init(tokenizer: GrammarTokenizer, hostTokenizer: any MLXLMCommon.Tokenizer, toolGrammar: ToolEnvelopeGrammar.Mode = .strict) {
        self.tokenizer = tokenizer
        self.hostTokenizer = hostTokenizer
        self.toolGrammar = toolGrammar
    }

    /// Runs `body` with this schema's matcher at its start state and resets it afterwards.
    func withConstraint<T>(for schema: GenerationSchemaSpec, _ body: (GrammarConstraint, CommitCounter) throws -> T) throws -> T {
        let constraint = try constraint(for: schema)
        let counter = CommitCounter()
        do {
            let value = try body(constraint, counter)
            reset(constraint, commits: counter.count, schema: schema)
            return value
        } catch is CancellationError {
            reset(constraint, commits: counter.count, schema: schema)
            throw CancellationError()
        } catch {
            compiled[schema.json] = nil
            throw error
        }
    }

    private func reset(_ constraint: GrammarConstraint, commits: Int, schema: GenerationSchemaSpec) {
        guard commits > 0 else { return }
        do {
            try constraint.rollback(Int32(commits))
        } catch {
            compiled[schema.json] = nil
            MLXLog.model.error("grammar rollback failed; recompiling next time: \(String(describing: error), privacy: .public)")
        }
    }

    private func constraint(for schema: GenerationSchemaSpec) throws -> GrammarConstraint {
        if let ready = compiled[schema.json] { return ready }
        let grammar = try GuidedGrammar.ebnf(for: schema, mode: toolGrammar)
        let constraint: GrammarConstraint
        do {
            constraint = try GrammarConstraint(tokenizer: tokenizer, grammar: grammar, fastForward: true, hostTokenizer: hostTokenizer)
        } catch {
            throw LanguageModelError.unsupportedSchema("\(schema.name): grammar did not compile (\(error))")
        }
        compilations += 1
        compiled[schema.json] = constraint
        return constraint
    }
}

extension MaskResult {
    /// The single token the grammar allows here, if exactly one is allowed.
    func onlyToken() -> Int? {
        guard needsApply else { return nil }
        var found: Int?
        for (word, bits) in mask.enumerated() where bits != 0 {
            let value = UInt32(bitPattern: bits)
            guard found == nil, value & (value - 1) == 0 else { return nil }
            found = word * 32 + value.trailingZeroBitCount
        }
        return found
    }

    /// Whether the grammar permits only `tokens` here (so no forward pass is needed).
    func allowsOnly(_ tokens: Set<Int>) -> Bool {
        guard needsApply else { return false }
        for (word, bits) in mask.enumerated() where bits != 0 {
            var remaining = UInt32(bitPattern: bits)
            while remaining != 0 {
                if !tokens.contains(word * 32 + remaining.trailingZeroBitCount) { return false }
                remaining &= remaining - 1
            }
        }
        return true
    }
}

