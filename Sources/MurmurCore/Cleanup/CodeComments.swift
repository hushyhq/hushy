import Foundation

/// Spoken comment delimiters at the START of a code utterance: "slash slash ..." -> `// ...`,
/// "hash ..." -> `# ...`, "dash dash ..." -> `-- ...` (SQL, Lua, Haskell). A delimiter word anywhere
/// else is part of a code line or a shell command, so only the first words of the utterance count.
/// "slash slash" is not ordinary speech and always converts. "hash" and "dash dash" are, so each
/// needs a sentence after it (three words, four words) and "hash" must not be followed by a noun
/// it forms a compound with ("hash map").
enum CodeComments {
    /// Splits `line` into the delimiter text and the comment words after it, or nil when the line
    /// does not open with a delimiter.
    static func split(_ line: String) -> (delimiter: String, body: String)? {
        let words = line.split(separator: " ").map(String.init)
        let lower = words.map { CodeTokens.bare($0) }
        if lower.count > 2, lower[0] == "slash", lower[1] == "slash" {
            return ("// ", words.dropFirst(2).joined(separator: " "))
        }
        if lower.count >= 4, lower[0] == "hash", !CodeSymbolWords.hashNounFollowers.contains(lower[1]),
           !CodeSymbolWords.hashVerbObjectLeaders.contains(lower[1]) {
            return ("# ", words.dropFirst().joined(separator: " "))
        }
        if lower.count >= 6, lower[0] == "dash", lower[1] == "dash",
           !CodeFlags.startsKnownFlag(Array(lower.dropFirst(2))) {
            return ("-- ", words.dropFirst(2).joined(separator: " "))
        }
        return nil
    }

    /// True when the text already starts with one of the delimiters this file produces.
    static func startsWithDelimiter(_ text: String) -> Bool {
        text.hasPrefix("// ") || text.hasPrefix("# ") || text.hasPrefix("-- ")
    }
}

/// Small helpers shared by the token-level code rules.
enum CodeTokens {
    /// Lowercased token without the sentence punctuation a recogniser may attach ("semicolon.").
    static func bare(_ token: String) -> String {
        var text = token.lowercased()
        while let last = text.last, ".,!?".contains(last) { text.removeLast() }
        return text
    }

    static func isWordLike(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func isPathLike(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isLetter || $0.isNumber || "._~-".contains($0) }
    }

    static func isDigits(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy(\.isNumber)
    }
}
