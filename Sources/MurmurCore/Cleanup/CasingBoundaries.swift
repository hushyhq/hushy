import Foundation

/// Where an identifier ends when a casing command sits inside a sentence ("call camel case get
/// user by id after saving"). At the start of an utterance a casing command still takes every word
/// up to the next punctuation (see `CasingCommands`); inside a sentence nothing marks the end, so the
/// identifier stops at the first word from a closed class of boundary words:
///
/// - determiners, prepositions, conjunctions, clause starters, predicate verbs, third-person verbs,
///   object pronouns and a few sentence adverbs ("the", "to", "with", "then", "is", "returns", "it",
///   "again");
/// - a "soft" preposition (at, of, by, for, in, on) ends it only when a determiner follows, because
///   the same word is common inside an identifier ("created at", "number of items", "order by id")
///   and a determiner after it shows it is the sentence resuming ("by the user").
///
/// The first word is always part of the identifier, except a strong boundary that cannot start one;
/// predicate starters ("is valid", "has children", "can retry") can, so they are kept as the first word.
///
/// The line is a heuristic, and these identifiers come out wrong because a small word is the cut:
/// `sync to disk` -> `sync`, `load from disk` -> `load`, `convert to utc` -> `convert`, `fetch with
/// retry` -> `fetch`, `is empty or null` -> `isEmpty`. Speaking the command at the start of the
/// utterance (or after a comma) takes the whole phrase and avoids the cut.
enum CasingBoundaries {
    static let determiners: Set<String> = [
        "the", "this", "that", "these", "those", "my", "your", "our", "their", "its", "an",
    ]

    private static let prepositions: Set<String> = [
        "to", "from", "with", "through", "before", "after", "under", "over", "into", "onto", "than",
        "as", "between", "during", "until", "without", "within", "about", "inside", "via",
    ]

    private static let clauseWords: Set<String> = [
        "and", "or", "but", "then", "so", "if", "when", "while", "unless", "because", "since",
        "which", "where", "whenever", "otherwise",
    ]

    /// Predicate verbs: they follow the identifier ("... is broken"), so they end it. They can also
    /// open one, see `predicateStarters`.
    private static let predicateVerbs: Set<String> = [
        "is", "are", "was", "were", "be", "should", "must", "will", "would", "can", "could", "does",
        "do", "has", "have", "did", "might", "may",
    ]

    private static let thirdPersonVerbs: Set<String> = [
        "returns", "takes", "calls", "throws", "needs", "means", "gets", "uses", "contains", "handles",
        "sets", "fails", "works",
    ]

    private static let pronouns: Set<String> = ["it", "we", "you", "they", "them", "us"]
    private static let adverbs: Set<String> = ["again", "now", "later", "too", "also", "please", "instead", "anyway", "there", "here"]

    /// Predicate verbs that can also be the first word of an identifier (`isValid`, `hasChildren`).
    private static let predicateStarters: Set<String> = [
        "is", "are", "was", "were", "has", "have", "can", "should", "does", "will", "did", "do",
    ]

    /// Prepositions that are common inside identifiers; they end it only before a determiner.
    private static let softPrepositions: Set<String> = ["at", "of", "by", "for", "in", "on"]
    private static let softFollowers: Set<String> = determiners.union(["a", "each", "every"])

    private static let strong: Set<String> = determiners
        .union(prepositions).union(clauseWords).union(predicateVerbs)
        .union(thirdPersonVerbs).union(pronouns).union(adverbs)

    /// True for a word that can only be ordinary grammar around a name, never part of one: a determiner,
    /// preposition, conjunction, predicate or third-person verb, pronoun or sentence adverb.
    static func isClauseWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        return strong.contains(lower) || softPrepositions.contains(lower)
    }

    /// How many of `words` (the words after an embedded casing keyword) belong to the identifier.
    static func length(of words: [String]) -> Int {
        let lower = words.map { $0.lowercased() }
        guard let first = lower.first else { return 0 }
        if strong.contains(first), !predicateStarters.contains(first) { return 0 }
        if endsBefore(lower, at: 0) { return 0 }
        var count = 1
        while count < lower.count {
            if strong.contains(lower[count]) || endsBefore(lower, at: count) { break }
            count += 1
        }
        return count
    }

    /// True when `lower[index]` is a soft preposition that is followed by a determiner.
    private static func endsBefore(_ lower: [String], at index: Int) -> Bool {
        guard softPrepositions.contains(lower[index]), index + 1 < lower.count else { return false }
        return softFollowers.contains(lower[index + 1])
    }

    // MARK: Start mode

    /// Words that start a new clause and can never be part of a name: "snake case user id then
    /// retry". "and" and "or" are left out, because they join the halves of a name ("read and write").
    private static let clauseStarters: Set<String> = clauseWords.subtracting(["and", "or"])
    private static let conjunctions: Set<String> = ["and", "or"]

    /// How many of `words` (the words after a casing keyword that opens a clause) belong to the
    /// identifier. With no punctuation to stop it, the name runs to the end of the words, cut where the
    /// next clause evidently starts:
    /// - a clause word ("then", "but", "because", "which") always starts one;
    /// - a determiner starts a noun phrase, and a name never holds one. The phrase's own introducer goes
    ///   with it: a preposition right before it ("in the cache") or a conjunction within two words before
    ///   it ("and print the output", "or the group name"), because the clause began there.
    /// Evidence is only ever one of these closed classes. "read and write count" and "sync to disk after
    /// saving" have none, so they stay whole.
    static func startLength(of words: [String]) -> Int {
        let lower = words.map { $0.lowercased() }
        for index in 1..<max(lower.count, 1) {
            if clauseStarters.contains(lower[index]) {
                // "and then", "or else": the conjunction belongs to the clause that starts here.
                return index - 1 >= 1 && conjunctions.contains(lower[index - 1]) ? index - 1 : index
            }
            guard determiners.contains(lower[index]) else { continue }
            return introducerIndex(before: index, in: lower)
        }
        return words.count
    }

    /// Where the clause that holds the determiner at `index` begins.
    private static func introducerIndex(before index: Int, in lower: [String]) -> Int {
        if index - 1 >= 1, prepositions.union(softPrepositions).contains(lower[index - 1]) { return index - 1 }
        for back in 1...2 where index - back >= 1 && conjunctions.contains(lower[index - back]) {
            return index - back
        }
        return index
    }
}
