import Foundation
@testable import HushyModelsMLX

/// `ScriptedModel`'s preferences (write `target`, else `junk`), as a speculative step model: it
/// scores every requested row from the text fed up to that row, and supports `mark`/`rewind`
/// either like attention KV caches (`trimmable`: cut anywhere) or like Qwen3.5's recurrent
/// layers (return to the mark, keep nothing). Every token it is fed counts as context, so a
/// decoder that re-feeds the wrong tokens after a rewind produces a different answer.
final class ScriptedSpeculativeModel: SpeculativeTokenStepModel {
    let target: String
    let junk: String
    let trimmable: Bool
    /// Leading fed tokens that are the prompt (not part of the answer text).
    let promptLength: Int
    private(set) var fed: [Int] = []
    private(set) var forwardPasses = 0
    private(set) var feeds: [[Int]] = []
    private(set) var rewinds = 0
    private var markAt: Int?
    /// A sliding-window cache: once the context reaches this many tokens a rewind is no longer exact.
    var rewindableTokens: Int?
    /// Passes fed under a mark that took the context to `rewindableTokens` or beyond (must stay 0).
    private(set) var unrewindableDraftPasses = 0

    init(target: String, junk: String = "", trimmable: Bool, promptLength: Int) {
        self.target = target
        self.junk = junk
        self.trimmable = trimmable
        self.promptLength = promptLength
    }

    /// The answer text the model has seen so far.
    var answerText: String { TinyVocab.text(Array(fed.dropFirst(promptLength))) }

    func append(_ tokens: [Int]) throws -> any NextTokenDistribution {
        try append(tokens, rows: 1)[0]
    }

    func append(_ tokens: [Int], rows: Int) throws -> [any NextTokenDistribution] {
        precondition(rows >= 1 && rows <= max(1, tokens.count))
        forwardPasses += 1
        feeds.append(tokens)
        fed += tokens
        if markAt != nil, let rewindableTokens, fed.count >= rewindableTokens { unrewindableDraftPasses += 1 }
        // Row i is the distribution after the fed prefix of this length.
        let lengths = tokens.isEmpty ? [fed.count] : Array((fed.count - rows + 1)...fed.count)
        return lengths.map { length in
            let context = TinyVocab.text(Array(fed.prefix(length).dropFirst(promptLength)))
            return ScriptedModel.Distribution(preference: ScriptedModel.preference(context: context, target: target, junk: junk))
        }
    }

    func mark() { markAt = fed.count }

    func rewind(keeping keep: Int) -> Int {
        guard let mark = markAt else { return 0 }
        markAt = nil
        rewinds += 1
        let kept = trimmable ? min(keep, fed.count - mark) : 0
        fed = Array(fed.prefix(mark + kept))
        return kept
    }

    func releaseMark() { markAt = nil }

    func canRewind(afterFeeding count: Int) -> Bool {
        rewindableTokens.map { fed.count + count < $0 } ?? true
    }
}
