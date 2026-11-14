import Foundation

/// A content word that ends one sentence and opens the next, in the draft the recogniser punctuated ("check the budget.
/// Budget numbers look off."), is two sentences that share a word, not a stutter or a restart.
///
/// The other word-loss checks excuse a word the draft says more than once: one copy of a stutter is enough, so losing
/// them all was never counted. Across a sentence end that excuse is wrong. A model that takes the repeat for a restart
/// deletes the end of the first sentence and the start of the second, the word included, and the two sentences fuse into one
/// that says something else ("check numbers look off") with no check objecting.
///
/// What it asks: the word must still be in the answer somewhere. It does not ask for the sentence end to survive (a
/// rewrite may join two sentences it keeps whole) and it reads no word lists beyond the closed set of fillers the
/// other checks already excuse. A draft the recogniser did not punctuate has no sentence end to read, so nothing is
/// asked of it. A reported loss goes through the same repair and asking-again path as any dropped content word.
enum BoundaryRepeatGuard {
    /// The content words of `draft` that end a sentence and open the next one (one article or filler may stand first).
    static func repeatedWords(in draft: String) -> Set<String> {
        let sentences = Sentences.split(draft).map { OutputGuard.words($0) }
        var found = Set<String>()
        for (left, right) in zip(sentences, sentences.dropFirst()) {
            guard let last = left.last, isContent(last),
                  let first = right.prefix(2).first(where: { !DisfluencyOnlyGuard.droppable.contains($0) }),
                  first == last else { continue }
            found.insert(last)
        }
        return found
    }

    static func violation(answer: String, draft: String) -> String? {
        let repeated = repeatedWords(in: draft)
        guard !repeated.isEmpty else { return nil }
        let answerWords = Set(OutputGuard.words(answer))
        // A word the model corrected to a near spelling of itself everywhere is kept, as in `DisfluencyOnlyGuard.reheardWords`.
        let lost = repeated.filter { word in !answerWords.contains { $0 == word || WordRelation.isNearSpelling(word, $0) } }.sorted()
        guard !lost.isEmpty else { return nil }
        return "dropped content words: \(lost.prefix(4))"
    }

    static func isContent(_ word: String) -> Bool {
        !DisfluencyOnlyGuard.droppable.contains(word) && word.count > 2 && !word.contains(where: \.isNumber)
    }

    /// Modals and light verbs that end a repeated *phrase* in a disfluency ("we should we should"), not a
    /// noun that ends one clause and opens the next ("the budget budget numbers").
    private static let phraseStutterTails: Set<String> = [
        "should", "would", "could", "can", "will", "shall", "may", "might", "must",
        "have", "has", "had", "does", "did", "do", "need", "want", "think", "know", "going", "trying",
        "not",
    ]

    /// A noun-like anchor whose exact repeat across a clausal boundary must survive the rules draft.
    static func isBoundaryAnchor(_ word: String) -> Bool {
        isContent(word) && !StutterCollapse.stutterWords.contains(word) && !phraseStutterTails.contains(word)
    }

    /// Do not collapse an adjacent phrase repeat when its last word is a boundary anchor (e.g. "the landlord the landlord").
    static func preservesPhraseRepeat(_ phrase: String, wordAfter: String? = nil) -> Bool {
        let keys = phrase.split(whereSeparator: \.isWhitespace).map { LegitDoubles.key(String($0)) }
        guard let anchor = keys.last, let first = keys.first else { return false }
        guard isBoundaryAnchor(anchor) else { return false }
        guard first == "the" || first == "a" || first == "an" else { return false }
        // Determiner-led repeats can be two clauses ("the landlord the landlord wants") or a phrase
        // stutter ("the report the report today"). Keep only when the word after the repeat opens a clause.
        guard let next = wordAfter.map({ LegitDoubles.key($0) }) else { return false }
        return clauseOpeningAfterBoundaryRepeat.contains(next)
    }

    /// First word after a determiner-led boundary phrase repeat that signals a new clause, not a stutter tail.
    private static let clauseOpeningAfterBoundaryRepeat: Set<String> = [
        "is", "are", "was", "were", "am", "be", "been", "being",
        "has", "have", "had", "does", "did", "do",
        "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "wants", "wanted", "needs", "needed", "looks", "looked", "seems", "seemed",
        "says", "said", "gets", "got", "goes", "went", "comes", "came",
        "makes", "made", "keeps", "kept", "includes", "included", "contains", "contained",
        "means", "meant", "works", "worked", "runs", "running", "ran",
        "asked", "called", "supports", "supported", "closed", "changed", "failed", "fails",
        "throws", "threw", "blocks", "blocked", "reset", "resets", "mentions", "mentioned",
        "moved", "signed", "broke", "uses", "used", "lives", "live", "starts", "started",
        "already", "still", "never", "always", "also", "just", "even", "only",
    ]

    /// The first word key immediately after an exact `match` substring in `text`.
    static func wordAfterMatch(_ match: String, in text: String) -> String? {
        let nsText = text as NSString
        let range = nsText.range(of: match, options: .caseInsensitive)
        guard range.location != NSNotFound else { return nil }
        let tailStart = range.location + range.length
        guard tailStart < nsText.length else { return nil }
        let tail = nsText.substring(from: tailStart).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = tail.split(whereSeparator: \.isWhitespace).first else { return nil }
        return String(first)
    }
}
