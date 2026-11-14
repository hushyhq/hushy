import Foundation

/// A number word that is a whole element of a bracket, a parenthesis or a brace is a digit:
/// "index open bracket i comma two close bracket" -> `index[i, 2]`, "open paren four comma five close
/// paren" -> `(4, 5)`. Runs after `CodeSymbols`, once the brackets are real characters.
///
/// Evidence for the number: the word stands alone between an opener, a comma or a slice colon on its
/// left and a closer, a comma or a colon on its right, inside a bracket that is still open. A number inside a phrase
/// ("one of two options", "three seconds") is not an element, so it stays a word and the sentence
/// around it reads as written.
enum CodeBracketNumbers {
    private static let values: [String: Int] = InverseTextNormalizer.ones
        .merging(InverseTextNormalizer.teens) { first, _ in first }
        .merging(InverseTextNormalizer.tens) { first, _ in first }

    private static let pattern: NSRegularExpression? = {
        let words = values.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "([(\\[{,:])(\\s*)(\(words))(?=\\s*[,:)\\]}])", options: [.caseInsensitive])
    }()

    static func apply(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            CodeComments.startsWithDelimiter(line) ? line : convert(line)
        }.joined(separator: "\n")
    }

    private static func convert(_ line: String) -> String {
        guard let pattern, line.contains(where: { "([{".contains($0) }) else { return line }
        let ns = line as NSString
        var out = ""
        var cursor = 0
        for match in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let lead = ns.substring(with: match.range(at: 1))
            let word = ns.substring(with: match.range(at: 3)).lowercased()
            let prefix = ns.substring(to: match.range.location)
            guard let value = values[word], !",:".contains(lead) || isInsideOpener(prefix) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // A colon between two numbers is a slice or a ratio ("[0:3]"), so it stays tight.
            let isTightColon = lead == ":" && out.last?.isNumber == true
            out += lead + (isTightColon ? "" : ns.substring(with: match.range(at: 2))) + String(value)
            cursor = NSMaxRange(match.range)
        }
        return out + ns.substring(from: cursor)
    }

    /// True when `prefix` has more opening brackets than closing ones.
    private static func isInsideOpener(_ prefix: String) -> Bool {
        var depth = 0
        for character in prefix {
            if "([{".contains(character) { depth += 1 } else if ")]}".contains(character) { depth -= 1 }
        }
        return depth > 0
    }
}
