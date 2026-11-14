import Foundation

/// Adds a terminal period (or question mark) when a dictation ends without one.
///
/// Conservative by design: skips very short fragments (a lone word or two carries too little
/// structure to be confident it's a full sentence rather than a label/name being typed), and
/// skips text that already ends in something that isn't ordinary prose — a URL, a path/code
/// token, or an emoji — where a trailing period would corrupt the literal value rather than
/// punctuate a sentence.
enum TerminalPunctuation {
    /// Below this word count, a fragment is more likely a short label ("Yes", "Thanks", "Sure
    /// thing") entered verbatim than a sentence missing its stop — adding punctuation there
    /// reads as oddly formal and this codebase's dictation goldens never expect it. Three words
    /// is the threshold: two-word imperatives ("Call Sarah") are common enough dictation output
    /// that we still leave them alone, matching existing golden expectations.
    private static let minimumWords = 3

    /// Interrogative openers that make a "?" a safe, confident choice rather than a guess.
    private static let interrogativeOpeners: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which", "whose",
        "is", "are", "was", "were", "do", "does", "did",
        "can", "could", "will", "would", "should", "shall", "may", "might",
        "have", "has", "had",
    ]

    static func apply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // A dictation with an explicit line break ("new line"/"new paragraph") is laid out like
        // a short message (greeting on its own line, a list, and so on); guessing a terminal
        // mark for it risks fighting a casual/veryCasual style's own "less punctuation" choice,
        // or double-punctuating a list — so this only ever fills in a missing stop for a
        // dictation that is a single line of ordinary prose.
        guard !trimmed.contains("\n") else { return text }

        // Already ends in sentence punctuation, a closing quote/paren after one — nothing to add.
        if trimmed.range(of: "[.!?][\"'’”)\\]]*$", options: .regularExpression) != nil { return text }

        guard TextStats.wordCount(trimmed) >= minimumWords else { return text }
        guard !endsInLiteralToken(trimmed) else { return text }

        let mark = endsWithQuestion(trimmed) ? "?" : "."
        return trimmed + mark
    }

    /// A trailing URL, file path, code identifier, version string, or emoji: appending "." would
    /// change the literal value (or just look wrong) rather than punctuate a spoken sentence.
    private static func endsInLiteralToken(_ line: String) -> Bool {
        guard let lastToken = line.split(whereSeparator: \.isWhitespace).last else { return false }
        let token = String(lastToken)
        if token.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if token.range(of: "^(?:www\\.)?[a-z0-9-]+\\.[a-z]{2,}(?:/\\S*)?$", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if token.contains("/") || token.contains("\\") { return true }
        // A bare version/identifier/number-dot-number token ("2.3.1", "v2.0") — never punctuate
        // through the middle of a value the speaker dictated literally.
        if token.range(of: "^v?\\d+(\\.\\d+)+$", options: .regularExpression) != nil { return true }
        if token.unicodeScalars.last.map({ $0.properties.isEmoji && $0.properties.isEmojiPresentation }) == true { return true }
        // A backtick-wrapped code token ("`getUserById`") is a literal identifier; punctuating
        // right after its closing backtick reads like it's part of the code.
        if token.hasSuffix("`") { return true }
        return false
    }

    /// True only when the line clearly opens as a question — an interrogative first word (or,
    /// for a multi-sentence line, the last sentence's first word) — so a "?" is never guessed
    /// for a statement that merely mentions a question-shaped word mid-sentence.
    private static func endsWithQuestion(_ line: String) -> Bool {
        let sentences = Sentences.split(line)
        let lastSentence = sentences.last ?? line
        guard let firstWord = lastSentence
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .first?
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        else { return false }
        return interrogativeOpeners.contains(firstWord)
    }
}
