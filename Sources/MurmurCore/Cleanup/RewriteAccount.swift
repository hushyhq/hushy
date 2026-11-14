import Foundation

/// How much of one text is made of another, in numbers only: which of its words stand in the source in the
/// source's order, which are in the source but somewhere else, and which are nowhere in it.
///
/// A rewrite of what someone said is made of what they said. A reply to it is not: it drops their words and
/// brings its own. Nothing here reads meaning or knows a phrase, and there is no list of words: a word is
/// weighed by its letters, so the short words that glue a sentence together count for little and the words
/// that carry it count for most. Two spellings are the same word when `WordRelation` says so (an inflection,
/// a near misspelling), when one is neighbouring words written together ("some thing", "something"), or when
/// one is a contraction of two neighbours ("do not", "don't").
///
/// Used twice: `SmartCleaner` refuses a model answer that is not accountable to its input (`isRewrite`), and
/// the dictation log line says how far the delivered text is from the recogniser's (`RewriteDistance`).
public struct RewriteAccount: Sendable, Equatable {
    /// Words in the text, and their letters.
    public let words: Int
    public let letters: Int
    /// Words that stand in the source in the same order, and their letters.
    public let inOrder: Int
    public let inOrderLetters: Int
    /// Words the source has, but not in that order (a moved clause, a word written together or apart).
    public let elsewhere: Int
    public let elsewhereLetters: Int
    /// The words the text brings that the source does not have, and the words of the source the text leaves out (lower
    /// case, letters and digits only). Empty for an account built from counts.
    public let newWords: [String]
    public let droppedWords: [String]
    /// Content words the text says more often than the source did.
    public let repeatedWords: [String]
    /// Whether the text speaks as the speaker where the source does not (`RegisterWording.inventsSpeaker`).
    public let inventsSpeaker: Bool

    public init(
        words: Int, letters: Int, inOrder: Int, inOrderLetters: Int, elsewhere: Int, elsewhereLetters: Int,
        newWords: [String] = [], droppedWords: [String] = [], repeatedWords: [String] = [], inventsSpeaker: Bool = false
    ) {
        self.words = words
        self.letters = letters
        self.inOrder = inOrder
        self.inOrderLetters = inOrderLetters
        self.elsewhere = elsewhere
        self.elsewhereLetters = elsewhereLetters
        self.newWords = newWords
        self.droppedWords = droppedWords
        self.repeatedWords = repeatedWords
        self.inventsSpeaker = inventsSpeaker
    }

    /// Words the source does not have.
    public var added: Int { words - inOrder - elsewhere }
    public var addedLetters: Int { letters - inOrderLetters - elsewhereLetters }
    /// Words the source accounts for, in order or not.
    public var accounted: Int { inOrder + elsewhere }
    /// Percent of the text's letters the source accounts for. An empty text is all accounted for.
    public var share: Int { letters == 0 ? 100 : (inOrderLetters + elsewhereLetters) * 100 / letters }

    /// Whether the text is a rewrite of its source: what it brings that the source does not have weighs at most a
    /// third of what it keeps in the source's order. A word the source does not have counts in full, a word that only
    /// moved counts a sixth: a moved word is still the speaker's own, and putting a sentence in order is what a rewrite
    /// does. One rule for every length: a one-word text passes by being that word, and no allowance switches on for
    /// short input, which is where a reply used to fit under every count.
    ///
    /// Measured (`murmur-eval rewrite-check --pairs`): of 869 wanted rewrites in the dev and public sets none is
    /// refused, and the heaviest brings 0.24 of what it keeps. A reply brings more than it keeps. Moved words weighed
    /// half until 2026-10-14, when a real 15-word dictation that reordered four words and added one was refused by a
    /// hair (78 against 76) and pasted as heard.
    public var isRewrite: Bool { 6 * addedLetters + elsewhereLetters <= 2 * inOrderLetters }

    /// The same check for an answer the model was asked to write in a register (Professional, Casual, Prompt).
    ///
    /// Real rewording replaces words ("I don't have the bandwidth for this" for "I'm going to have to say no"), so the plain
    /// bound refused 8 of 42 faithful register rewrites of one or two sentences, at 1.5 to 7.5 times the bound
    /// (`docs/yc/tones-register-2026-10-28.md`). Under a register an answer passes when any of these holds, unless the model
    /// speaks as the speaker where the speaker did not (`inventsSpeaker`), which no bound lets through:
    /// - it passes the plain bound;
    /// - it keeps at least `registerMinimumKeptLetters` of what was said, in order, and 6 x new letters + moved letters is
    ///   at most `registerLooseness` x kept letters (what it brings may weigh two thirds of what it keeps, not a third);
    /// - it rewords faithfully (`rewordsFaithfully`, `RegisterWording`): glue and politeness added, each new content word
    ///   standing in for one of the speaker's that is gone, nothing said twice that was said once, a weighted sum of what it
    ///   brings within `registerWordingLooseness` x kept letters. This is the one that lets a short message through, where
    ///   the 60-letter floor (about 14 words) refuses a rewording of one or two sentences (TRY-97).
    ///
    /// A reply to a short question or request, and a model's invented first clause for a dictation that lost its start,
    /// keep a few letters and bring a sentence of their own: they bring content words nothing replaces, or a first-person
    /// clause the speaker never spoke. An answer that fails all three is asked again without the register
    /// (`SmartCleaner.refine`).
    ///
    /// Only this check changes. Values, digits, names and protected terms, retracted wording, the longer-than-transcript limit
    /// and every other guard judge a register answer exactly as they judge any other.
    public func isRewrite(under register: IntentRegister?) -> Bool {
        guard register != nil else { return isRewrite }
        // A clause in which the model speaks as the speaker where the speaker did not ("I will update the draft...") is a
        // reply or an invention, however few letters it adds: no bound lets it through.
        if inventsSpeaker { return false }
        if isRewrite { return true }
        if inOrderLetters >= Self.registerMinimumKeptLetters
            && 6 * addedLetters + elsewhereLetters <= Self.registerLooseness * inOrderLetters { return true }
        return rewordsFaithfully
    }

    /// Letters of what was said that a register answer must keep in order before the looser bound applies (about 14 words).
    public static let registerMinimumKeptLetters = 60
    /// What 6 x new letters + moved letters may reach, in kept letters, for a register answer (the plain bound is 2).
    public static let registerLooseness = 4

    /// `text` measured against `source`. Order is the order of `source`; `also` (the recogniser's text beside
    /// the rules draft, say) only adds words the text may use.
    public static func measure(_ text: String, against source: String, also extra: String? = nil) -> RewriteAccount {
        let answer = keys(text)
        let ordered = keys(source)
        let pool = Pool(ordered, extra.map(keys) ?? [])
        var letters = 0, present = 0, presentLetters = 0
        var new: [String] = []
        for index in answer.indices {
            let weight = answer[index].count
            letters += weight
            guard pool.accounts(for: answer, at: index) else { new.append(answer[index]); continue }
            present += 1
            presentLetters += weight
        }
        let kept = aligned(answer, ordered)
        let answerPool = Pool(answer)
        let dropped = ordered.indices.filter { !answerPool.accounts(for: ordered, at: $0) }.map { ordered[$0] }
        let spoken = RegisterWording.tokens(source)
        return RewriteAccount(
            words: answer.count, letters: letters, inOrder: min(kept.words, present), inOrderLetters: min(kept.letters, presentLetters),
            elsewhere: max(0, present - kept.words), elsewhereLetters: max(0, presentLetters - kept.letters),
            newWords: new, droppedWords: dropped, repeatedWords: RegisterWording.repeated(answer: RegisterWording.tokens(text), source: spoken),
            inventsSpeaker: RegisterWording.inventsSpeaker(answer: text, source: source))
    }

    /// Lower-case words as letters and digits only, so "Don't" and "dont" are one spelling.
    static func keys(_ text: String) -> [String] {
        EvalMetrics.normalizedWords(text).map(WordRelation.collapsed).filter { !$0.isEmpty }
    }

    static func sameWord(_ a: String, _ b: String) -> Bool {
        a == b || (a.first == b.first && WordRelation.isNearSpelling(a, b))
    }

    /// `whole` is `head` with the end of `tail` run into it: "dont" from "do" and "not", "youre" from "you" and "are".
    static func contracts(_ whole: String, _ head: String, _ tail: String) -> Bool {
        guard whole.count > head.count, whole.hasPrefix(head), whole.last == tail.last else { return false }
        var rest = Substring(tail)
        for letter in whole.dropFirst(head.count) {
            guard let found = rest.firstIndex(of: letter) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }

    /// The words of the source a text may use, with the ways two neighbours can be one word.
    private struct Pool {
        let words: Set<String>
        let byFirst: [Character: [String]]
        /// Two to four neighbours written as one word.
        let joined: Set<String>
        let pairs: [(String, String)]

        init(_ sources: [String]...) {
            var words = Set<String>(), joined = Set<String>(), pairs: [(String, String)] = []
            for source in sources {
                words.formUnion(source)
                for start in source.indices {
                    var run = source[start]
                    for next in source[(start + 1)...].prefix(3) {
                        run += next
                        joined.insert(run)
                    }
                    if start + 1 < source.count { pairs.append((source[start], source[start + 1])) }
                }
            }
            self.words = words
            self.joined = joined
            self.pairs = pairs
            byFirst = Dictionary(grouping: words) { $0.first ?? " " }
        }

        func has(_ word: String) -> Bool {
            words.contains(word) || (byFirst[word.first ?? " "] ?? []).contains { WordRelation.isNearSpelling(word, $0) }
        }

        /// The word at `index` is in the source: itself, as neighbours written together or contracted, or as
        /// one half of a source word the text writes apart.
        func accounts(for text: [String], at index: Int) -> Bool {
            let word = text[index]
            if has(word) || joined.contains(word) { return true }
            if pairs.contains(where: { RewriteAccount.contracts(word, $0.0, $0.1) }) { return true }
            let before = index > 0 ? text[index - 1] : nil
            let after = index + 1 < text.count ? text[index + 1] : nil
            return splits(before, word) || splits(word, after)
        }

        private func splits(_ head: String?, _ tail: String?) -> Bool {
            guard let head, let tail else { return false }
            return words.contains(head + tail) || words.contains { RewriteAccount.contracts($0, head, tail) }
        }
    }

    /// The heaviest run of `answer`'s words that stands in `source` in the same order (a longest common
    /// subsequence, each word weighed by its letters). One word may stand for two neighbours written together or
    /// contracted, on either side. Past `bandFrom` cells only a band around the diagonal is compared, which a
    /// rewrite never leaves: its words stay near where they were said.
    private static func aligned(_ answer: [String], _ source: [String]) -> (words: Int, letters: Int) {
        guard !answer.isEmpty, !source.isEmpty else { return (0, 0) }
        let places = Dictionary(grouping: source.indices) { source[$0] }
        var single: [String: Set<Int>] = [:]
        for word in Set(answer) {
            single[word] = Set(places.filter { sameWord(word, $0.key) }.flatMap(\.value))
        }
        let pairs = pairEnds(answer, source)
        let splits = splitEnds(answer, places)
        let rows = answer.count, columns = source.count
        let band = rows * columns > bandFrom ? max(bandWidth, abs(rows - columns) + bandWidth / 2) : columns
        var earlier = [Score](repeating: Score(), count: columns + 1)
        var previous = earlier
        var current = earlier
        for row in 1...rows {
            let word = answer[row - 1]
            let weight = word.count
            let centre = row * columns / rows
            let low = max(1, centre - band), high = min(columns, centre + band)
            let hits = single[word] ?? [], pairHits = pairs[word] ?? [], splitHits = splits[row - 1] ?? []
            for column in 1..<low { current[column] = previous[column] }
            if low <= high {
                for column in low...high {
                    var best = max(previous[column], current[column - 1])
                    if hits.contains(column - 1) { best = max(best, previous[column - 1].adding(weight)) }
                    if column > 1, pairHits.contains(column - 1) { best = max(best, previous[column - 2].adding(weight)) }
                    if row > 1, splitHits.contains(column - 1) {
                        best = max(best, earlier[column - 1].adding(answer[row - 2].count).adding(weight))
                    }
                    current[column] = best
                }
            }
            if high < columns { for column in (high + 1)...columns { current[column] = max(current[column - 1], previous[column]) } }
            (earlier, previous, current) = (previous, current, earlier)
        }
        return (previous[columns].words, previous[columns].letters)
    }

    /// For each word of `answer` that is two neighbours of `source` written as one ("dont" for "do not"): where the
    /// second of the two stands.
    private static func pairEnds(_ answer: [String], _ source: [String]) -> [String: Set<Int>] {
        var byHead: [String: [Int]] = [:]
        for end in source.indices.dropFirst() { byHead[source[end - 1], default: []].append(end) }
        var result: [String: Set<Int>] = [:]
        for word in Set(answer) where word.count > 1 {
            var ends = Set<Int>()
            for length in 1..<word.count {
                let head = String(word.prefix(length))
                for end in byHead[head] ?? [] where head + source[end] == word || contracts(word, head, source[end]) {
                    ends.insert(end)
                }
            }
            if !ends.isEmpty { result[word] = ends }
        }
        return result
    }

    /// For each word of `answer` that, with the word before it, is one word of `source` written apart ("do not" for
    /// "dont"): where that word stands.
    private static func splitEnds(_ answer: [String], _ places: [String: [Int]]) -> [Int: Set<Int>] {
        var result: [Int: Set<Int>] = [:]
        let byFirst = Dictionary(grouping: places.keys) { $0.first ?? " " }
        for index in answer.indices.dropFirst() {
            let head = answer[index - 1], tail = answer[index]
            var found = Set(places[head + tail] ?? [])
            for word in byFirst[head.first ?? " "] ?? [] where contracts(word, head, tail) {
                found.formUnion(places[word] ?? [])
            }
            if !found.isEmpty { result[index] = found }
        }
        return result
    }

    private static let bandFrom = 400_000
    private static let bandWidth = 160

    private struct Score: Comparable {
        var letters = 0
        var words = 0
        func adding(_ weight: Int) -> Score { Score(letters: letters + weight, words: words + 1) }
        static func < (a: Score, b: Score) -> Bool { (a.letters, a.words) < (b.letters, b.words) }
    }
}
