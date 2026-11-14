import Foundation

/// Token text for the drafter's fuzzy matching (the model's tokenizer; a toy one in tests).
protocol TokenTexts: AnyObject {
    func text(of token: Int) -> String
    /// The token that spells exactly `text`, if one does.
    func token(spelling text: String) -> Int?
}

/// Guesses the next token of an answer by lookup — no draft model, no memory beyond token arrays.
/// Sources, tried in order:
///
/// 1. **The prompt, exactly** ("prompt lookup" / n-gram copy). A cleanup answer is mostly the
///    user's draft with small edits, and a tool call copies spans of the utterance into its
///    arguments. After the answer's last `n` tokens (n = `maxNgram` down to 1) also appear in the
///    user's text, the token that followed them there is a good guess. Among several
///    occurrences, the one ending closest to (at or after) the `cursor` — where the last accepted
///    copy left off — wins, so a common token like " the" re-syncs to the right place.
/// 2. **The prompt, by word** (needs `texts`). Cleanup's usual edits break exact matching:
///    punctuation the speaker didn't say ("paid." after "paid"), and a capital after it or at the
///    start ("So" for " so", "Page" for " page"). So the answer's last words are compared by
///    lower-cased, trimmed text with punctuation-only tokens skipped, and after a sentence end
///    the guess is the capitalised spelling of the source token when one token spells it.
/// 3. **The model's own earlier choices in this answer**, for structure. A tool call's flat
///    envelope repeats the same move for each unused argument: close the empty value, the grammar
///    jump-forwards the next key (`","` → key → `":"` → `","` → …). Matching the tail of the
///    *chosen* tokens (grammar-forced ones left out, since every key differs) against their own
///    history predicts that rhythm; at least `minHistoryNgram` tokens must match, so prose
///    doesn't echo its own earlier sentences. The decoder splices the grammar's forced tokens
///    between guesses, so one draft can run through several empty arguments.
struct PromptLookupDrafter {
    struct Guess: Equatable {
        enum Kind: Int, CaseIterable {
            case prompt, promptWord, history
        }

        var token: Int
        /// Index in `source` the token was copied from (nil for a guess from the answer's history).
        var sourceIndex: Int?
        var kind = Kind.prompt
    }

    /// Tokens to copy from (the user's part of the prompt).
    let source: [Int]
    let maxNgram: Int
    let minHistoryNgram: Int
    private let words: WordMatcher?
    /// Source index just past the last accepted copied token (monotone alignment hint).
    private(set) var cursor = 0

    init(source: [Int], maxNgram: Int = 3, minHistoryNgram: Int = 2, texts: (any TokenTexts)? = nil) {
        self.source = source
        self.maxNgram = max(1, maxNgram)
        self.minHistoryNgram = max(1, minHistoryNgram)
        self.words = texts.map { WordMatcher(texts: $0, source: source) }
    }

    /// The next token after `output` (the answer so far, forced tokens included), whose
    /// model-chosen tokens are `chosen`. Nil when no source has a match.
    func guess(output: [Int], chosen: [Int]) -> Guess? {
        if let end = Self.bestMatchEnd(in: source, tail: output, maxNgram: maxNgram, minNgram: 1, cursor: cursor) {
            return Guess(token: source[end], sourceIndex: end)
        }
        if let words, let guess = words.guess(after: output, maxWords: maxNgram, cursor: cursor) {
            return guess
        }
        if let end = Self.bestMatchEnd(in: chosen, tail: chosen, maxNgram: maxNgram, minNgram: minHistoryNgram, cursor: nil) {
            return Guess(token: chosen[end], sourceIndex: nil, kind: .history)
        }
        return nil
    }

    /// Records that `guess` became part of the answer.
    mutating func didAccept(_ guess: Guess) {
        if let index = guess.sourceIndex { cursor = index + 1 }
    }

    /// Index of the token that follows the best earlier occurrence of `tail`'s last n tokens in
    /// `haystack` (n from `maxNgram` down to `minNgram`), or nil. With a `cursor`, the occurrence
    /// ending nearest at/after it wins; without one (`haystack` is the tail's own sequence, whose
    /// final occurrence is excluded), the most recent.
    static func bestMatchEnd<T: Equatable>(in haystack: [T], tail: [T], maxNgram: Int, minNgram: Int, cursor: Int?) -> Int? {
        let isSelf = cursor == nil
        guard minNgram <= maxNgram else { return nil }
        for n in stride(from: min(maxNgram, tail.count), through: max(1, minNgram), by: -1) {
            let pattern = tail.suffix(n)
            // Occurrences must leave a token after them; a self-match must end before the tail.
            let lastStart = (isSelf ? tail.count - n - 1 : haystack.count - n - 1)
            guard lastStart >= 0 else { continue }
            var best: (end: Int, score: Int)?
            for start in stride(from: lastStart, through: 0, by: -1) where haystack[start] == pattern.first {
                guard haystack[start..<(start + n)].elementsEqual(pattern) else { continue }
                let end = start + n
                guard let cursor else { return end }  // most recent occurrence
                // At/after the cursor: distance forward. Behind it: penalised so forward wins ties.
                let score = end >= cursor ? end - cursor : (cursor - end) * 4 + 1
                if let current = best, current.score <= score { continue }
                best = (end, score)
            }
            if let best { return best.end }
        }
        return nil
    }
}

/// Word-level matching for `PromptLookupDrafter` source 2. Caches token texts per call.
final class WordMatcher {
    private let texts: any TokenTexts
    private let source: [Int]
    /// Source positions of word tokens (not punctuation-only) and their keys.
    private let sourceWordIndex: [Int]
    private let sourceKeys: [String]
    private var keys: [Int: String] = [:]
    private var capitals: [Int: Int?] = [:]

    init(texts: any TokenTexts, source: [Int]) {
        self.texts = texts
        self.source = source
        var index: [Int] = []
        var keys: [String] = []
        for (position, token) in source.enumerated() {
            let key = Self.key(texts.text(of: token))
            guard !key.isEmpty, !Self.isPunctuation(key) else { continue }
            index.append(position)
            keys.append(key)
        }
        self.sourceWordIndex = index
        self.sourceKeys = keys
    }

    func guess(after output: [Int], maxWords: Int, cursor: Int) -> PromptLookupDrafter.Guess? {
        // The answer's last few word tokens (by key), and whether a sentence ended after them.
        var tail: [String] = []
        var sentenceEnded = false
        for token in output.reversed() {
            let key = key(token)
            if key.isEmpty || Self.isPunctuation(key) {
                if tail.isEmpty, key.last.map({ ".?!".contains($0) }) == true { sentenceEnded = true }
                if tail.isEmpty { continue }
                break
            }
            tail.insert(key, at: 0)
            if tail.count == maxWords { break }
        }
        guard !tail.isEmpty else { return nil }
        let wordCursor = sourceWordIndex.firstIndex { $0 >= cursor } ?? sourceWordIndex.count
        guard let end = PromptLookupDrafter.bestMatchEnd(in: sourceKeys, tail: tail, maxNgram: maxWords, minNgram: 1, cursor: wordCursor)
        else { return nil }
        let position = sourceWordIndex[end]
        let token = sentenceEnded ? (capitalized(source[position]) ?? source[position]) : source[position]
        return .init(token: token, sourceIndex: position, kind: .promptWord)
    }

    private func key(_ token: Int) -> String {
        if let cached = keys[token] { return cached }
        let value = Self.key(texts.text(of: token))
        keys[token] = value
        return value
    }

    private func capitalized(_ token: Int) -> Int? {
        if let cached = capitals[token] { return cached }
        let text = texts.text(of: token)
        let leading = text.prefix { $0 == " " }
        let rest = text.dropFirst(leading.count)
        let value = rest.first.flatMap { first in
            first.isUppercase ? token : texts.token(spelling: leading + first.uppercased() + rest.dropFirst())
        }
        capitals[token] = value
        return value
    }

    static func key(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    static func isPunctuation(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.union(.symbols).contains($0) }
    }
}
