import Foundation

/// Writes spoken technical tokens the way a developer types them, in work messages and email
/// only (`CleanupOptions.technicalTokens` is nil everywhere else): paths, branch names and long
/// flags (`SpokenPathTokens`), percentiles and cloud regions (`SpokenMetricTokens`), PR numbers
/// and ticket ids (`SpokenTrackerTokens`).
///
/// Every rule needs evidence beyond the plain words, because "slash", "dash", "dot", "p", "us east
/// one" and "eng 1423" are all ordinary speech too: a file extension, two path separators, a git
/// verb, a latency word, an infrastructure word, a ticket word, or a key in the browser tab title.
/// When the evidence is missing the text is left exactly as it was. A wrong conversion is worse
/// than a missed one. Runs after `InverseTextNormalizer`, so numbers from ten up are already digits.
enum SpokenTechnicalTokens {
    static func apply(_ text: String, context: TechnicalTokenContext) -> String {
        var out = SpokenPathTokens.apply(text)
        out = SpokenMetricTokens.apply(out)
        out = SpokenTrackerTokens.apply(out, context: context)
        return out
    }
}

/// One regex match with the words around it, so a rule can look for evidence in the same sentence.
struct TokenMatch {
    let source: String
    let result: NSTextCheckingResult

    func group(_ index: Int) -> String? {
        let range = result.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else { return nil }
        return String(source[swiftRange])
    }

    var text: String { group(0) ?? "" }

    /// Up to `count` lowercased words before the match, within the same sentence, nearest last.
    func wordsBefore(_ count: Int) -> [String] {
        guard let range = Range(result.range, in: source) else { return [] }
        let sentence = source[..<range.lowerBound].split(whereSeparator: { ".!?\n".contains($0) }).last.map(String.init) ?? ""
        return Array(TokenLexicon.words(in: sentence).suffix(count))
    }

    /// Up to `count` lowercased words after the match, within the same sentence, nearest first.
    func wordsAfter(_ count: Int) -> [String] {
        guard let range = Range(result.range, in: source) else { return [] }
        let sentence = source[range.upperBound...].split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? ""
        return Array(TokenLexicon.words(in: sentence).prefix(count))
    }
}

enum TokenRewrite {
    /// Replaces each match with `transform`'s result; returning nil leaves that match untouched.
    static func replace(_ text: String, pattern: String, _ transform: (TokenMatch) -> String?) -> String {
        guard let regex = RegexCache.compiled(pattern, caseInsensitive: true) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var output = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text),
                  let replacement = transform(TokenMatch(source: text, result: match)) else { continue }
            output += text[cursor..<range.lowerBound]
            output += replacement
            cursor = range.upperBound
        }
        output += text[cursor...]
        return output
    }
}

/// The closed word classes the token rules lean on.
enum TokenLexicon {
    static func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// Words that cannot be part of a path, a flag or a project key: the glue of ordinary
    /// sentences. A joiner word between two of these ("slash the budget") is the verb or noun.
    static let functionWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "our", "their", "his", "her", "its",
        "i", "you", "he", "she", "it", "we", "they", "me", "us", "him", "them", "who", "what", "which", "whose",
        "is", "are", "was", "were", "am", "be", "been", "being", "do", "does", "did", "done", "have", "has", "had",
        "will", "would", "should", "could", "can", "may", "might", "must", "shall", "let", "lets", "get", "got",
        "of", "in", "on", "at", "by", "for", "to", "from", "with", "without", "over", "under", "up", "down", "off",
        "out", "into", "onto", "about", "after", "before", "as", "than", "through", "between", "around", "across",
        "and", "or", "but", "so", "if", "then", "else", "also", "not", "no", "yes", "just", "only", "very", "too",
        "now", "all", "any", "some", "each", "every", "both", "more", "most", "less", "like", "there", "here",
        "when", "where", "while", "because", "since", "until", "again", "back", "away", "once", "still", "even",
        "well", "ok", "okay", "please", "thanks", "sorry", "hey", "hi", "hello",
    ]

    /// Spoken-number words: a path or key made of these is a count or a version, not a name.
    static let numberWords: Set<String> = InverseTextNormalizer.allDigitWords
        .union(InverseTextNormalizer.scales.keys).union(["and"])

    /// What can follow a number to make it a quantity ("2 days", "100 miles") rather than an identifier.
    static let quantityWords: Set<String> = [
        "second", "seconds", "sec", "secs", "minute", "minutes", "min", "mins", "hour", "hours", "day", "days",
        "week", "weeks", "month", "months", "year", "years", "time", "times", "ago", "ms", "milliseconds",
        "mb", "gb", "kb", "tb", "bytes", "percent", "people", "users", "requests", "errors", "hits", "lines",
        "files", "commits", "comments", "reviews", "reviewers", "approvals", "dollars", "bucks", "per", "of",
        "mile", "miles", "block", "blocks", "step", "steps", "more", "other", "another", "at", "on", "by",
        "hundred", "thousand", "million", "point",
    ]

    /// Adverbs and time words that are not nouns, so a word after a token that is one of these does
    /// not make the token the start of a noun phrase ("hit slash api slash users today").
    private static let nonNounWords: Set<String> = [
        "today", "tomorrow", "tonight", "yesterday", "later", "soon", "next", "last", "first", "second",
        "already", "always", "never", "maybe", "anyway", "together", "twice", "tomorrow's", "afterwards",
        "thanks", "pls", "plz", "again", "instead", "though", "however", "right", "left",
    ]

    /// True when `word` looks like a plain noun or adjective that could head or continue a noun
    /// phrase: not a function word, a number, a time adverb, or anything ending like a verb form,
    /// an adverb or a plural/third-person "-s". The closed shape test the token rules use to read
    /// the word right after a candidate: "route slash detour slash bypass option" (noun follows, so
    /// the slashes join spoken alternatives) against "route slash api slash orders is slow".
    static func isNounLike(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard lower.count > 2, lower.allSatisfy({ $0.isLetter }) else { return false }
        if functionWords.contains(lower) || numberWords.contains(lower) || nonNounWords.contains(lower) { return false }
        return !["ed", "ing", "ly", "s"].contains(where: lower.hasSuffix)
    }
}
