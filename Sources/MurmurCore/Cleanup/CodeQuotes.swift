import Foundation

/// Spoken quotes in a code line: "quote missing token quote" -> `"missing token"`, "single quote
/// done single quote" -> `'done'`, "triple quote ... triple quote" -> `"""..."""`.
///
/// Only a complete pair converts. A lone "quote", or one that follows a determiner ("a quote for
/// the repair", "put a single quote around it"), is a word, so a half-spoken pair never leaves a
/// stray quote mark in the text. The words between a pair are literal: symbol words inside a quoted
/// string are not converted, so `"a comma b"` stays as spoken. The one exception is a pair that holds a
/// single symbol word and nothing else ("split on quote comma quote"): the speaker is spelling the
/// character, so it becomes `","`. The table is closed (`spelledSymbols`).
enum CodeQuotes {
    /// Symbol words that a quote pair around only that word spells out.
    private static let spelledSymbols: [String: String] = [
        "comma": ",", "dot": ".", "slash": "/", "colon": ":", "semicolon": ";", "underscore": "_",
        "dash": "-", "equals": "=",
    ]

    /// Holds the quoted strings of one dictation while later stages (`CodeSymbols`, `CasingCommands`)
    /// run, so words inside a quote are never rewritten. Each string is replaced by a private-use
    /// placeholder between its quote marks and put back by `restore`.
    final class Vault {
        private var held: [String] = []
        private static let open: Character = "\u{E000}"
        private static let close: Character = "\u{E001}"

        func hold(_ content: String) -> String {
            held.append(content)
            return "\(Self.open)\(held.count - 1)\(Self.close)"
        }

        func restore(_ text: String) -> String {
            guard !held.isEmpty, text.contains(Self.open) else { return text }
            var out = ""
            var digits = ""
            var inside = false
            for character in text {
                if character == Self.open { inside = true; digits = ""; continue }
                if inside, character == Self.close {
                    inside = false
                    out += Int(digits).flatMap { held.indices.contains($0) ? held[$0] : nil } ?? ""
                    continue
                }
                if inside { digits.append(character) } else { out.append(character) }
            }
            return out
        }
    }

    private struct Kind {
        let words: [String]
        let mark: String
        let maxContent: Int
    }

    /// Longest keyword first, so "single quote" is never read as the bare "quote".
    private static let kinds: [Kind] = [
        Kind(words: ["triple", "quote"], mark: "\"\"\"", maxContent: 60),
        Kind(words: ["single", "quote"], mark: "'", maxContent: 12),
        Kind(words: ["double", "quote"], mark: "\"", maxContent: 12),
        Kind(words: ["quote"], mark: "\"", maxContent: 12),
    ]

    /// Returns `tokens` with every complete quote pair collapsed into one token (the marks plus the
    /// words between them, single-spaced).
    static func pair(_ tokens: [String], vault: Vault? = nil) -> [String] {
        let lower = tokens.map { CodeTokens.bare($0) }
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            if let (kind, closer) = opening(at: index, in: lower) {
                let words = Array(tokens[(index + kind.words.count)..<closer])
                let spelled = words.count == 1 ? spelledSymbols[CodeTokens.bare(words[0])] : nil
                let content = spelled ?? words.joined(separator: " ")
                out.append(kind.mark + (vault?.hold(content) ?? content) + kind.mark)
                index = closer + kind.words.count
            } else {
                out.append(tokens[index])
                index += 1
            }
        }
        return out
    }

    /// The pair opened at `index` and the index where its closing keyword starts, or nil.
    private static func opening(at index: Int, in lower: [String]) -> (Kind, Int)? {
        if index > 0, CodeSymbolWords.nounLeaders.contains(lower[index - 1]) { return nil }
        for kind in kinds where matches(kind, at: index, in: lower) {
            let first = index + kind.words.count
            let last = min(lower.count - kind.words.count, first + kind.maxContent)
            var closer = first + 1
            while closer <= last {
                if matches(kind, at: closer, in: lower) { return (kind, closer) }
                closer += 1
            }
            return nil
        }
        return nil
    }

    private static func matches(_ kind: Kind, at index: Int, in lower: [String]) -> Bool {
        index + kind.words.count <= lower.count && Array(lower[index..<(index + kind.words.count)]) == kind.words
    }
}
