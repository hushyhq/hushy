import Foundation

/// "dot" -> "." and "arrow" -> "->" in a code line, but only where the words around them read as code.
///
/// Both words are ordinary English as well ("the dot on the map", "the arrow points left"), so a
/// symbol needs the neighbours to agree. It stays a word when:
/// - the word before it is a determiner or possessive ("the dot", "an arrow", "my arrow keys"): a noun
///   phrase, where `user dot id` has an identifier before it ("a dot b" is two one-letter names);
/// - the word after it is a function word or a verb of the closed classes in `CasingBoundaries`
///   ("a red dot on the screen", "the arrow is missing"): a member name is never one;
/// - the word after it is a noun that names the thing ("dot product", "arrow keys", "arrow function").
/// Anything else converts exactly as before, with the spaces on both sides collapsed.
///
/// A path that starts with dots keeps its space before it ("cd ../..", "ls ./src"): evidence is a word
/// that is only "dot dot" (the parent directory, never a name) or a lone "dot" that `CodeSymbolGrammar`
/// already joined to a "/" ("dot slash run" is `./run`). A run of three is an ellipsis and stays words.
enum CodeDotArrow {
    private static let parentDirectory = "(?<![^\\s/])(?<!\\bdot )\\bdot\\s+dot\\b(?!\\s+dot\\b)(?=[/\\s]|$)"
    private static let currentDirectory = "(?<![^\\s/])\\bdot(?=/)"

    private static let pattern = "\\b(dot|(?<!\\bfat )arrow)\\b"
    private static let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])

    private static let nounFollowers: [String: Set<String>] = [
        "dot": ["product", "products", "matrix", "notation", "operator", "operators"],
        "arrow": ["key", "keys", "function", "functions", "notation", "syntax", "operator", "operators"],
    ]

    static func apply(_ input: String) -> String {
        guard let regex else { return input }
        let text = Regex.replace(Regex.replace(input, parentDirectory, with: ".."), currentDirectory, with: ".")
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range).lowercased()
            guard keepsAsSymbol(word, in: ns, at: match.range) else { continue }
            var start = match.range.location
            while start > cursor, isBlank(ns.character(at: start - 1)) { start -= 1 }
            var end = NSMaxRange(match.range)
            while end < ns.length, isBlank(ns.character(at: end)) { end += 1 }
            out += ns.substring(with: NSRange(location: cursor, length: start - cursor))
            out += word == "dot" ? "." : "->"
            cursor = end
        }
        return out + ns.substring(from: cursor)
    }

    private static func keepsAsSymbol(_ word: String, in ns: NSString, at range: NSRange) -> Bool {
        let after = neighbour(in: ns, from: NSMaxRange(range), backwards: false)
        if let before = neighbour(in: ns, from: range.location, backwards: true),
           CodeSymbolWords.determiners.contains(before) {
            // "a dot b" is the variables a and b; "a dot on the map" is the noun. One letter on each side.
            return before == "a" && after?.count == 1
        }
        guard let after else { return true }
        // A single letter is a name ("self dot a"), never the article.
        if after.count > 1, CodeSymbolWords.functionWords.contains(after) || CasingBoundaries.isClauseWord(after) { return false }
        return nounFollowers[word]?.contains(after) != true
    }

    /// The lowercased letters of the whitespace-separated word next to `position`, or nil when there is
    /// none or it holds a symbol (an earlier conversion, a bracket, a quote): then it is code, not prose.
    private static func neighbour(in ns: NSString, from position: Int, backwards: Bool) -> String? {
        var index = position
        var word = ""
        if backwards {
            while index > 0, isBlank(ns.character(at: index - 1)) { index -= 1 }
            while index > 0, !isBlank(ns.character(at: index - 1)) { index -= 1; word = ns.substring(with: NSRange(location: index, length: 1)) + word }
        } else {
            while index < ns.length, isBlank(ns.character(at: index)) { index += 1 }
            while index < ns.length, !isBlank(ns.character(at: index)) { word += ns.substring(with: NSRange(location: index, length: 1)); index += 1 }
        }
        guard !word.isEmpty, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        return word.lowercased()
    }

    private static func isBlank(_ unit: unichar) -> Bool { unit == 32 || unit == 9 || unit == 10 }
}
