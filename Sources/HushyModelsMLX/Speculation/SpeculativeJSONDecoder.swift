import Foundation
import MLXGuidedGeneration
import MurmurCore

/// A `TokenStepModel` that can check several draft tokens in one forward pass and take them back.
protocol SpeculativeTokenStepModel: TokenStepModel {
    /// Feeds `tokens` in one forward pass and returns the next-token distribution after each of
    /// the last `rows` of them, in order (`rows` ≤ `tokens.count`).
    func append(_ tokens: [Int], rows: Int) throws -> [any NextTokenDistribution]
    /// Remembers the current context so `rewind(keeping:)` can come back to it.
    func mark()
    /// Undoes what was fed since `mark()`, keeping the first `keep` of those tokens when the
    /// backend can cut there (attention KV caches trim). A backend with recurrent state that
    /// cannot be cut (Qwen3.5's gated-delta layers) returns to the mark and keeps nothing. Returns
    /// how many were kept; the caller feeds the rest again with its next pass.
    func rewind(keeping keep: Int) -> Int
    /// Drops the mark: everything fed since stays.
    func releaseMark()
    /// Whether a pass of `count` more tokens could still be taken back exactly by `rewind(keeping:)`.
    /// A sliding-window attention cache (Gemma 4's local layers) cannot once the pass would wrap it:
    /// the rows the pass overwrote are gone. The decoder drafts nothing for such a pass.
    func canRewind(afterFeeding count: Int) -> Bool
}

extension SpeculativeTokenStepModel {
    func canRewind(afterFeeding count: Int) -> Bool { true }
}

/// Tuning for prompt-lookup speculation (`SpeculativeJSONDecoder`).
public struct SpeculationSettings: Sendable, Equatable {
    /// Most draft tokens fed in one pass (guesses plus the grammar-forced tokens between them).
    /// Each pass picks its own length up to this from the pass-cost curve and the running
    /// acceptance (`PassCostModel.bestDraftLength`).
    public var maxDraftTokens = 5
    /// Longest output tail matched against the prompt / the answer's history.
    public var maxNgram = 3

    public init() {}

    public init(maxDraftTokens: Int, maxNgram: Int = 3) {
        self.maxDraftTokens = max(1, maxDraftTokens)
        self.maxNgram = max(1, maxNgram)
    }
}

/// Per-call speculation counters (logs, `model-diag --mlx-probe`).
public struct SpeculationStats: Sendable, Equatable {
    /// Forward passes, the prompt's included (the non-speculative loop does one per sampled token).
    public var forwardPasses = 0
    /// Passes that carried a draft.
    public var draftRounds = 0
    /// Guessed tokens fed as drafts (grammar-forced tokens spliced between them not counted).
    public var draftedTokens = 0
    public var acceptedDraftTokens = 0
    /// Tokens fed a second time because a rejected draft forced a return to the mark.
    public var refedTokens = 0
    /// Guesses dropped before feeding because the grammar would not accept them.
    public var grammarTrimmedDraftTokens = 0
    /// Forward-pass cost by tokens fed (prompt pass excluded): tokens → milliseconds per pass.
    public var passMilliseconds: [Int: [Double]] = [:]

    public var acceptanceRate: Double {
        draftedTokens == 0 ? 0 : Double(acceptedDraftTokens) / Double(draftedTokens)
    }
}

/// `GuidedJSONDecoder` with prompt-lookup speculation: before each forward pass, copy up to N
/// tokens from the prompt that plausibly come next (`PromptLookupDrafter`), feed them in the
/// *same* pass, and keep the longest prefix the model would have produced anyway.
///
/// The algorithm reproduces the non-speculative loop exactly (same greedy picks, same grammar,
/// same budget and end rules; tested with a deterministic model): every kept token is chosen from
/// the model's own grammar-masked distribution at that position, and a draft token only saves a
/// pass when it equals that choice. At a temperature, the same sample-then-compare rule keeps the
/// sampling distribution unchanged. On the GPU, a row computed in a k-token pass differs from the
/// same row computed alone by float rounding (different matmul kernels), so a near-tie can flip —
/// the same thing the plain loop does when its batch shapes change (see INFERENCE-OPTIMIZATION.md).
///
/// - Grammar: a draft is walked through the XGrammar matcher first and cut at the first token the
///   grammar rejects, then rolled back; a commit that jump-forwards adds the forced tokens to the
///   draft (they are certain once the token before them is). Verification commits for real.
/// - Rollback: a partly rejected draft is undone with `rewind(keeping:)` — attention caches trim;
///   a recurrent cache returns to the pre-pass mark and the kept tokens are fed again next pass.
/// - Cancellation is checked before every forward pass, as in the plain loop; the matcher is
///   always left with only real commits counted in `commits` (tentative ones are rolled back).
struct SpeculativeJSONDecoder {
    let model: any SpeculativeTokenStepModel
    let constraint: GrammarConstraint
    let endTokens: Set<Int>
    let grammarVocabSize: Int
    let temperature: Float?
    let maxSampledTokens: Int
    var settings = SpeculationSettings()
    /// Relative forward-pass cost by tokens fed (calibrated per model at prewarm when available).
    var costs = PassCostModel.m4ProDefault
    var commits = CommitCounter()
    var checkpoint: () throws -> Void = { try Task.checkCancellation() }
    var onFirstToken: (() -> Void)?
    /// Called once per forward pass (and per grammar-forced token run) with the tokens that joined
    /// the answer then: how many were sampled and how many forced. See `GuidedJSONDecoder.onEmit`.
    var onEmit: ((_ sampled: Int, _ forced: Int) -> Void)?
    /// Token text for word-level prompt matching (capitals, punctuation); exact matching only if nil.
    var texts: (any TokenTexts)?
    /// Called with each non-empty draft just before it is fed, while the matcher holds only real
    /// commits (tests check the draft is grammar-valid there).
    var onDraft: (([Int]) throws -> Void)?

    /// A draft: guessed tokens with the grammar's forced tokens spliced in after them.
    private struct Draft {
        var tokens: [Int] = []
        /// Each guess and its index in `tokens`.
        var guesses: [(index: Int, guess: PromptLookupDrafter.Guess)] = []
    }

    /// Decodes after `prompt`, drafting from `draftSource` (the user's part of the prompt).
    func decode(prompt: [Int], draftSource: [Int]) throws -> (result: GuidedJSONDecoder.Result, stats: SpeculationStats) {
        var drafter = PromptLookupDrafter(source: draftSource, maxNgram: settings.maxNgram, texts: texts)
        var stats = SpeculationStats()
        var pending = prompt
        var output: [Int] = []
        var chosen: [Int] = []
        var sampled = 0
        var forced = 0
        var acceptance = DraftAcceptance()
        var mask = try constraint.computeMask()
        var isFirstPass = true
        while !mask.isTerminated, !mask.allowsOnly(endTokens) {
            // Exactly one token allowed: take it without a pass (as the plain loop does).
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
            guard sampled < maxSampledTokens else { throw Self.overBudget(maxSampledTokens) }
            try checkpoint()
            // The prompt pass carries no draft: there is no answer yet to match, and a rejected
            // draft there would mean feeding the whole prompt twice. Nor does a pass the cache
            // could not take back exactly (`canRewind`): from there on the loop is the plain one.
            let canDraft = !isFirstPass && model.canRewind(afterFeeding: pending.count + settings.maxDraftTokens)
            let draft = !canDraft ? Draft() : try buildDraft(drafter, output: output, chosen: chosen, stats: &stats) { kind in
                costs.bestDraftLength(
                    first: acceptance.first(kind), next: acceptance.next.value, pending: pending.count, maxDraft: settings.maxDraftTokens)
            }
            if !draft.tokens.isEmpty {
                try onDraft?(draft.tokens)
                model.mark()
            }
            let rows = try model.append(pending + draft.tokens, rows: draft.tokens.count + 1)
            stats.forwardPasses += 1
            isFirstPass = false

            // Walk the rows while what we produce is exactly the draft.
            var produced: [Int] = []
            var passSampled = 0
            var passForced = 0
            var finished = false
            var row = 0
            while true {
                if row > 0 { guard sampled < maxSampledTokens else { throw Self.overBudget(maxSampledTokens) } }
                let token = rows[row].choose(
                    mask: mask.needsApply ? mask.mask : nil, grammarVocabSize: grammarVocabSize, temperature: temperature)
                if sampled == 0 { onFirstToken?() }
                sampled += 1
                if endTokens.contains(token) { finished = true; break }
                let commit = try constraint.commitToken(Int32(token))
                let jumped = commit.tokens.map(Int.init)
                commits.count += 1 + jumped.count
                forced += jumped.count
                chosen.append(token)
                output += [token] + jumped
                produced += [token] + jumped
                passSampled += 1
                passForced += jumped.count
                if commit.isTerminated { finished = true; break }
                mask = try constraint.computeMask()
                if mask.isTerminated || mask.allowsOnly(endTokens) { finished = true; break }
                guard produced.count <= draft.tokens.count, draft.tokens.starts(with: produced) else { break }
                row = produced.count
            }

            // One clock read per pass: every token this pass produced arrives together.
            if passSampled > 0 { onEmit?(passSampled, passForced) }
            let accepted = min(draft.tokens.count, PrefixReuse.commonPrefixLength(produced, draft.tokens))
            let acceptedGuesses = draft.guesses.prefix { $0.index < accepted }
            if !draft.guesses.isEmpty {
                stats.draftRounds += 1
                stats.draftedTokens += draft.guesses.count
                stats.acceptedDraftTokens += acceptedGuesses.count
                if let last = acceptedGuesses.last(where: { $0.guess.sourceIndex != nil }) { drafter.didAccept(last.guess) }
            }
            if finished {
                if !draft.tokens.isEmpty { model.releaseMark() }
                break
            }
            if let kind = draft.guesses.first?.guess.kind {
                acceptance.record(kind: kind, accepted: accepted, drafted: draft.tokens.count)
            }
            pending = nextPending(pending: pending, produced: produced, draft: draft.tokens, accepted: accepted, stats: &stats)
        }
        return (GuidedJSONDecoder.Result(tokens: output, sampled: sampled, forced: forced), stats)
    }

    /// What the next pass must feed: the produced tokens the cache doesn't hold yet.
    private func nextPending(
        pending: [Int], produced: [Int], draft: [Int], accepted: Int, stats: inout SpeculationStats
    ) -> [Int] {
        if draft.isEmpty { return produced }
        if accepted == draft.count {
            model.releaseMark()
            return Array(produced[accepted...])
        }
        // The cache holds pending + the whole draft; only pending + draft[..<accepted] is right.
        let kept = model.rewind(keeping: pending.count + accepted)
        let truth = pending + produced
        stats.refedTokens += max(0, pending.count + accepted - kept)
        return Array(truth[kept...])
    }

    /// Up to `limit(kind of the first guess)` draft tokens: guesses, each walked through the grammar matcher. A guess the
    /// grammar rejects (or an end token) ends the draft; a guess that makes the grammar jump
    /// forward gets the forced tokens appended (cut at `limit`), and guessing continues after
    /// them. The matcher is back where it started on return.
    private func buildDraft(
        _ drafter: PromptLookupDrafter, output: [Int], chosen: [Int], stats: inout SpeculationStats,
        limit limitForFirstGuess: (PromptLookupDrafter.Guess.Kind) -> Int
    ) throws -> Draft {
        var draft = Draft()
        var output = output
        var chosen = chosen
        var tentative = 0
        var limit = 1
        while draft.tokens.count < limit, let guess = drafter.guess(output: output, chosen: chosen) {
            if draft.guesses.isEmpty {
                // The first guess's source sets how far this draft is worth going.
                limit = limitForFirstGuess(guess.kind)
                if limit == 0 { break }
            }
            // A rejected token leaves the matcher unchanged (xgrammar's accept is all-or-nothing).
            guard !endTokens.contains(guess.token), let commit = try? constraint.commitToken(Int32(guess.token)) else {
                stats.grammarTrimmedDraftTokens += 1
                break
            }
            tentative += 1 + commit.tokens.count
            let jumped = commit.tokens.map(Int.init)
            draft.guesses.append((draft.tokens.count, guess))
            draft.tokens += ([guess.token] + jumped).prefix(limit - draft.tokens.count)
            output += [guess.token] + jumped
            chosen.append(guess.token)
            if commit.isTerminated { break }
        }
        // A failed rollback throws: the caller's GrammarCache then recompiles the grammar.
        if tentative > 0 { try constraint.rollback(Int32(tentative)) }
        return draft
    }

    private static func overBudget(_ limit: Int) -> LanguageModelError {
        .malformedOutput("MLX answer exceeded \(limit) tokens")
    }
}
