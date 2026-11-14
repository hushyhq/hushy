import Foundation

/// "new paragraph" in the middle of a code-context utterance: "fix the retry loop new paragraph the
/// cache was never cleared" -> two paragraphs. `VoiceCommands.applyLineBreaks` only fires when the
/// phrase is its own clause (punctuation or the end of the text follows it), which a speech
/// recogniser rarely produces mid-dictation, so a commit body or a comment dictated in one breath
/// never breaks. In a code context the phrase has no other reading, so it is accepted mid-sentence
/// under guards:
///
/// - at least three words before it and two after, so a short phrase is never split;
/// - not after an article or quantifier and not before a word it forms a compound with ("a new
///   paragraph style", "every new paragraph element"), the same nouns that make "new paragraph" an
///   HTML or document term.
///
/// The next word is not capitalised: whether it should be depends on the field (a commit body, a
/// comment, a shell line), which this rule does not detect. "new line" is left alone: it is far more
/// common as ordinary speech ("a new line of work").
enum CodeParagraphBreaks {
    private static let minWordsBefore = 3
    private static let minWordsAfter = 2

    private static let previousWordBlockers: Set<String> = [
        "a", "the", "each", "every", "any", "another", "per", "this", "that", "one", "no", "of", "in",
        "for", "add", "insert", "start", "create", "make", "use", "your", "my",
    ]

    private static let nextWordBlockers: Set<String> = [
        "element", "elements", "tag", "tags", "style", "styles", "break", "breaks", "mark", "marks",
        "indent", "indentation", "margin", "margins", "spacing", "node", "nodes", "block", "blocks",
        "class", "selector", "rule", "rules", "format", "formatting", "function", "handler", "component",
    ]

    static func apply(_ text: String) -> String {
        text.components(separatedBy: "\n").map(applyToLine).joined(separator: "\n")
    }

    private static func applyToLine(_ line: String) -> String {
        let words = line.split(separator: " ").map(String.init)
        var index = minWordsBefore
        while index + 1 < words.count {
            guard isBreak(words, at: index) else { index += 1; continue }
            let head = words[..<index].joined(separator: " ")
            let tail = words[(index + 2)...].joined(separator: " ")
            let rest = applyToLine(tail)
            return head + "\n\n" + rest
        }
        return line
    }

    private static func isBreak(_ words: [String], at index: Int) -> Bool {
        guard CodeTokens.bare(words[index]) == "new", CodeTokens.bare(words[index + 1]) == "paragraph" else { return false }
        guard words.count - (index + 2) >= minWordsAfter else { return false }
        let previous = CodeTokens.bare(words[index - 1])
        let next = CodeTokens.bare(words[index + 2])
        return !previousWordBlockers.contains(previous) && !nextWordBlockers.contains(next)
    }
}
