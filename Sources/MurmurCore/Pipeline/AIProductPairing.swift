import Foundation

/// Finds the word "cloud" that is really "Claude" because it stands directly next to another AI product, as in
/// "Codex or cloud", "ChatGPT and cloud", "cloud vs Gemini" and "cloud, Codex and Cursor". `AIProductNameFixer` never
/// swaps a bare "cloud": the word is far too common. A pairing is the one cue that is safe, since nobody sets the
/// cloud (the place) against Codex, and the recogniser writes "Claude" as "cloud" often enough to matter (TRY-101).
///
/// "cloud" must be joined to the product by a connector alone: "or", "and", "vs", "versus", "and/or", "&", "/" or a
/// comma (with or without one of those words after it). A chain counts, because each link is a pairing. The word
/// stays as heard when it follows "the", "a" and the like, when it is the second word of "Google Cloud" or another
/// cloud vendor's name, and in "iCloud" (one word, so never a match). The other side must be an AI product, so
/// "AWS and cloud" and "cloud or on-device" stay as heard.
enum AIProductPairing {
    /// AI products a "cloud" can be set against, in lowercase. "claude" is here for "Claude or cloud".
    private static let products: Set<String> = [
        "claude", "chatgpt", "gpt", "gemini", "codex", "cursor", "copilot", "perplexity", "grok", "llama",
        "mistral", "deepseek", "windsurf", "sonnet", "opus", "haiku", "codeium", "tabnine", "devin", "kimi", "qwen",
    ]
    private static let connectorWords: Set<String> = ["and", "or", "vs", "versus"]
    /// What may stand between the two words once the spacing is tidied (see `tidy`).
    private static let connectors: Set<String> = [
        ",", "and", "or", "vs", "vs.", "versus", "&", "/", "and/or", ", and", ", or", ", vs", ", vs.", ", versus",
        ", &", ", and/or",
    ]
    /// Words before "cloud" that make it the place or a vendor's product.
    static let blockers: Set<String> = [
        "the", "a", "an", "my", "your", "our", "their", "this", "that", "in", "on", "to", "into", "from", "of",
        "google", "aws", "amazon", "azure", "microsoft", "ibm", "oracle", "alibaba", "apple", "adobe", "creative",
        "salesforce", "cloudflare", "digitalocean", "private", "public", "hybrid", "multi", "sovereign", "any",
    ]

    private struct Token {
        let lower: String
        let range: Range<String.Index>
    }

    /// The ranges of the words "cloud" in `text` that should read "Claude". `claimed` holds ranges the caller already
    /// changed to a product name: they count as products for pairing and are never returned.
    static func cloudRanges(in text: String, claimed: [Range<String.Index>]) -> [Range<String.Index>] {
        let tokens = Regex.matchesCaseSensitive(text, "[A-Za-z][A-Za-z'’]*").compactMap { match -> Token? in
            guard let range = Range(match.range, in: text) else { return nil }
            return Token(lower: text[range].lowercased(), range: range)
        }
        func isProduct(_ index: Int) -> Bool {
            products.contains(tokens[index].lower) || claimed.contains { $0.overlaps(tokens[index].range) }
        }
        func isClaimed(_ index: Int) -> Bool { claimed.contains { $0.overlaps(tokens[index].range) } }
        func joined(_ left: Int, _ right: Int) -> Bool {
            connectors.contains(tidy(String(text[tokens[left].range.upperBound..<tokens[right].range.lowerBound])))
        }
        /// The word on the far side of the connector in `direction` (-1 left, +1 right), if one joins it to `index`.
        func partner(of index: Int, direction: Int) -> Int? {
            var other = index + direction
            var skipped = 0
            while tokens.indices.contains(other), connectorWords.contains(tokens[other].lower), skipped < 2 {
                other += direction
                skipped += 1
            }
            guard tokens.indices.contains(other), !connectorWords.contains(tokens[other].lower) else { return nil }
            let (left, right) = direction < 0 ? (other, index) : (index, other)
            return joined(left, right) ? other : nil
        }
        // A cloud that pairs with a neighbouring product, or with another cloud that does (a chain).
        var paired = Set<Int>()
        let clouds = tokens.indices.filter { tokens[$0].lower == "cloud" && !isClaimed($0) && !isBlocked($0, tokens) }
        var changed = true
        while changed {
            changed = false
            for index in clouds where !paired.contains(index) {
                let isPaired = [-1, 1].contains { direction in
                    guard let other = partner(of: index, direction: direction) else { return false }
                    return isProduct(other) || paired.contains(other)
                }
                if isPaired { paired.insert(index); changed = true }
            }
        }
        return paired.sorted().map { tokens[$0].range }
    }

    private static func isBlocked(_ index: Int, _ tokens: [Token]) -> Bool {
        index > 0 && blockers.contains(tokens[index - 1].lower)
    }

    /// Lowercase, one space where there was any run of whitespace, and no space before a comma or around a slash.
    private static func tidy(_ gap: String) -> String {
        var text = gap.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = text.replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " / ", with: "/")
        return text
    }
}
