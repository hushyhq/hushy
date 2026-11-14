import Foundation

/// A code-like name the person has on screen or in their Dictionary has one written form ("TRY-95", "rl-v9"). The
/// recogniser writes what it heard: "TRY95", "try 95", "RLv9Eval", or "try ninety five" when the words come as spoken.
/// A run of words whose letters and digits, ignoring case and separators, are those of a known name is that name, so it
/// is written as the known form. Nothing is guessed for a name nobody has shown: "TRY95" with no TRY-95 anywhere stays
/// "TRY95", because "SHA256", "UTF8" and "H264" are written without a separator.
///
/// The run must be the whole name ("try 95" is TRY-95; "try 9" is not), and a number that is a quantity ("try 95 times",
/// "rl v9 percent") is left alone. A known name followed by a capitalised English word ("RLv9Eval") is the name and the
/// word: "rl-v9 eval".
enum KnownIdentifierForms {
    /// `isBlocked(heard, written)` is true when the person has told us not to write `written` for `heard`.
    static func apply(_ text: String, terms: [String], isBlocked: (String, String) -> Bool = { _, _ in false }) -> String {
        let forms = formsByKey(terms)
        guard !forms.isEmpty, text.contains(where: \.isNumber) || containsNumberWord(text),
              let words = RegexCache.compiled("\\S+", caseInsensitive: false) else { return text }
        let tokens = words.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
        let longestKey = forms.keys.map(\.count).max() ?? 0
        var output = ""
        var cursor = text.startIndex
        var index = 0
        while index < tokens.count {
            guard let hit = form(at: index, tokens: tokens, in: text, forms: forms, longestKey: longestKey, isBlocked: isBlocked) else {
                index += 1
                continue
            }
            output += text[cursor..<tokens[index].lowerBound] + hit.written
            cursor = tokens[hit.last].upperBound
            index = hit.last + 1
        }
        return output + text[cursor...]
    }

    private static let longestRun = 6

    private struct Hit {
        let written: String
        let last: Int
    }

    private static func form(at start: Int, tokens: [Range<String.Index>], in text: String, forms: [String: String],
                             longestKey: Int, isBlocked: (String, String) -> Bool) -> Hit? {
        let first = split(String(text[tokens[start]]))
        guard !first.core.isEmpty else { return nil }
        for end in stride(from: min(tokens.count, start + longestRun) - 1, through: start, by: -1) {
            if end > start, (start..<end).contains(where: { endsClause(text[tokens[$0]]) }) { continue }
            let last = end == start ? first : split(String(text[tokens[end]]))
            let pieces = (start...end).map { index -> String in
                index == start ? first.core : index == end ? last.core : String(text[tokens[index]])
            }
            guard !last.core.isEmpty,
                  let key = IdentifierDigits.written(pieces.map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }),
                  let term = forms[key] else { continue }
            let heard = pieces.joined(separator: " ")
            if end > start, isQuantity(after: end, tokens: tokens, in: text) { continue }
            if heard == term { return Hit(written: first.lead + heard + last.trail, last: end) }
            if isBlocked(heard, term) { return nil }
            return Hit(written: first.lead + term + last.trail, last: end)
        }
        return camelTail(first, start: start, forms: forms, longestKey: longestKey, isBlocked: isBlocked)
    }

    /// "RLv9Eval": a known name, then a capitalised English word glued on.
    private static func camelTail(_ token: (lead: String, core: String, trail: String), start: Int, forms: [String: String],
                                  longestKey: Int, isBlocked: (String, String) -> Bool) -> Hit? {
        let core = token.core
        for count in stride(from: min(longestKey, core.count), through: 3, by: -1) {
            guard let prefixEnd = prefixEnd(of: core, alphanumerics: count),
                  let term = forms[alphanumerics(String(core[..<prefixEnd]))] else { continue }
            let rest = String(core[prefixEnd...])
            guard rest.count >= 3, rest.first?.isUppercase == true, rest.allSatisfy(\.isLetter),
                  !isBlocked(String(core[..<prefixEnd]), term) else { continue }
            return Hit(written: token.lead + term + " " + rest.lowercased() + token.trail, last: start)
        }
        return nil
    }

    /// The index after the first `count` letters and digits of `text`, when the text has that many.
    private static func prefixEnd(of text: String, alphanumerics count: Int) -> String.Index? {
        var seen = 0
        for index in text.indices {
            if text[index].isLetter || text[index].isNumber { seen += 1 }
            if seen == count { return text.index(after: index) }
        }
        return nil
    }

    private static func formsByKey(_ terms: [String]) -> [String: String] {
        var forms: [String: String] = [:]
        var ambiguous = Set<String>()
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isIdentifier(term) else { continue }
            let key = alphanumerics(term)
            if let known = forms[key], known != term { ambiguous.insert(key) }
            forms[key] = term
        }
        return forms.filter { !ambiguous.contains($0.key) }
    }

    /// A letter first, letters and digits with "-", "_" or "." between pieces, at least one digit.
    private static func isIdentifier(_ term: String) -> Bool {
        guard term.count >= 2, term.count <= 40, term.first?.isLetter == true, term.contains(where: \.isNumber),
              term.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || "-_.".contains($0) }),
              term.last?.isLetter == true || term.last?.isNumber == true else { return false }
        return true
    }

    private static func isQuantity(after end: Int, tokens: [Range<String.Index>], in text: String) -> Bool {
        guard end + 1 < tokens.count else { return false }
        let next = text[tokens[end + 1]].lowercased().trimmingCharacters(in: .punctuationCharacters)
        return TokenLexicon.quantityWords.contains(next)
    }

    private static func endsClause(_ token: Substring) -> Bool {
        token.last.map { ",.;:!?".contains($0) } ?? false
    }

    private static func containsNumberWord(_ text: String) -> Bool {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).contains { SpokenNumberRuns.isNumberWord(String($0)) }
    }

    private static func alphanumerics(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Punctuation around a token that belongs to the sentence, not the name: ("\"", "TRY95", ".").
    private static func split(_ token: String) -> (lead: String, core: String, trail: String) {
        let lead = String(token.prefix { !$0.isLetter && !$0.isNumber })
        let rest = token.dropFirst(lead.count)
        let trail = String(rest.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
        return (lead, String(rest.dropLast(trail.count)), trail)
    }
}
