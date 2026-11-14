import Foundation

/// Question detection and punctuation for dictation that has lost (or never had) its question
/// marks — "is it like more than two seconds", "what do you think", "should we remember the
/// position per tab or is that overkill".
///
/// Rules only look at word order, never intonation, so detection is deliberately narrow:
/// - an inverted auxiliary + subject opener ("is the build signed", "should we…", "can you…",
///   "do you think…", "could it be…"), with imperatives ("Do the dishes", "Have a good day")
///   and conditional inversion ("Should you need anything, call me") excluded;
/// - a wh-word followed directly by an auxiliary ("what do you think", "how long does it take",
///   "where is the file"), a fixed wh-question ("how about…", "what if…", "why not…"), but never
///   a wh-word followed by a subject ("what I mean is…", "when you have 20 projects…",
///   "how we do it matters"), which is a statement, and never a pseudo-cleft ("what is clear is
///   that…").
///
/// `apply` then (1) turns a question sentence's final "." into "?", (2) splits a trailing tag
/// question off a statement ("…configurable what do you think" -> "…configurable. What do you
/// think?"), and (3) splits a second question that was run into the first ("…on an M1, is it
/// more than 2 seconds?" -> "…on an M1? Is it more than 2 seconds?").
public enum QuestionPunctuation {
    static let auxiliaries: Set<String> = [
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could", "will", "would",
        "should", "shall", "may", "might", "have", "has", "had", "isn't", "aren't", "wasn't",
        "weren't", "don't", "doesn't", "didn't", "can't", "couldn't", "won't", "wouldn't",
        "shouldn't", "haven't", "hasn't",
    ]
    /// Auxiliaries that open an imperative as easily as a question ("Do the dishes", "Have a
    /// look", "Don't touch it"): they only count as a question opener before a pronoun subject.
    private static let imperativeCapable: Set<String> = ["do", "have", "had", "don't"]
    /// Auxiliaries that also open a conditional ("Should you need help, …", "Had we known, …",
    /// "Were it up to me, …"): with a comma in the sentence they are not treated as questions.
    private static let conditionalCapable: Set<String> = ["should", "had", "were"]

    static let pronounSubjects: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "there", "this", "that", "these", "those",
        "anyone", "anybody", "someone", "somebody", "everyone", "everybody", "y'all", "u",
    ]
    private static let determinerSubjects: Set<String> = [
        "the", "a", "an", "my", "your", "our", "their", "his", "her", "its", "any", "all", "every",
        "each", "some", "this", "that",
    ]
    static let whWords: Set<String> = ["what", "who", "when", "where", "why", "how", "which", "whose"]
    /// "how long does…", "how many are…".
    private static let howModifiers: Set<String> = ["long", "much", "many", "often", "far", "big", "soon", "old", "late", "early"]
    /// Leading discourse words skipped before looking for the opener ("so how long does…").
    private static let leadIns: Set<String> = [
        "so", "okay", "ok", "and", "but", "also", "um", "uh", "well", "yeah", "oh",
        "anyway", "alright", "now", "then", "actually", "like",
    ]

    /// Tag questions that can close a statement without a comma in dictation.
    static let tagQuestions: [[String]] = [
        ["what", "do", "you", "think"], ["what", "do", "you", "guys", "think"], ["what", "do", "you", "all", "think"],
        ["does", "that", "make", "sense"], ["does", "that", "sound", "good"], ["does", "that", "sound", "okay"],
        ["does", "that", "work"], ["is", "that", "okay"], ["is", "that", "ok"], ["is", "that", "fine"],
        ["is", "that", "alright"], ["how", "does", "that", "sound"], ["any", "thoughts"],
    ]

    /// What a speaker says when the word will not come ("the new invoice layout looks a bit too how would I say it"). The
    /// sentence before it is left open, so the cleaned text shows the pause and the phrase stands as its own question.
    static let stallPhrases: [[String]] = [
        ["how", "would", "i", "say", "it"], ["how", "would", "i", "say", "this"], ["how", "do", "i", "say", "it"],
        ["how", "do", "i", "say", "this"], ["how", "would", "i", "put", "it"], ["how", "do", "i", "put", "it"],
        ["how", "should", "i", "put", "it"], ["how", "would", "you", "say", "it"], ["how", "do", "you", "say", "it"],
        ["what's", "the", "word"], ["what", "is", "the", "word"], ["what", "do", "you", "call", "it"],
    ]

    // MARK: Detection

    /// Word keys of `sentence` (lowercased, punctuation stripped, curly apostrophes straightened).
    static func keys(_ sentence: String) -> [String] {
        sentence.split(whereSeparator: \.isWhitespace).map { LegitDoubles.key(String($0)) }.filter { !$0.isEmpty }
    }

    /// True when `sentence` opens as a direct question (see the type doc for what counts).
    public static func opensQuestion(_ sentence: String) -> Bool {
        var words = keys(sentence)
        while let first = words.first, leadIns.contains(first), words.count > 2 { words.removeFirst() }
        guard words.count >= 2 else { return false }
        let first = words[0], second = words[1]
        if auxiliaries.contains(first) {
            guard words.count >= 3 else { return false }
            if conditionalCapable.contains(first), sentence.contains(",") { return false }
            if pronounSubjects.contains(second) { return true }
            if imperativeCapable.contains(first) { return false }
            return determinerSubjects.contains(second)
        }
        guard whWords.contains(first) else { return false }
        if first == "how", second == "about" || second == "come" { return true }
        if first == "what", second == "if" || second == "about" { return true }
        if first == "why", second == "not" || second == "don't" { return true }
        var auxIndex = 1
        if first == "how", howModifiers.contains(second) { auxIndex = 2 }
        // "What time does…", "Which one is…": one noun between the wh-word and the auxiliary —
        // but never a pronoun ("What I mean is…" is a statement).
        if ["what", "which", "whose"].contains(first), !auxiliaries.contains(second),
           !pronounSubjects.contains(second), !determinerSubjects.contains(second) { auxIndex = 2 }
        guard auxIndex < words.count, auxiliaries.contains(words[auxIndex]) else { return false }
        // "What is clear is that…", "What was great was…": a pseudo-cleft is a statement.
        let rest = words.dropFirst(auxIndex + 1).prefix(4)
        if rest.contains(where: { $0 == "is" || $0 == "was" }) { return false }
        // "What didn't go well, the estimate was off": a short wh-clause set off by a comma and
        // followed by a long statement is a heading, not a question.
        if let comma = sentence.firstIndex(of: ","),
           TextStats.wordCount(String(sentence[..<comma])) <= 5,
           TextStats.wordCount(String(sentence[sentence.index(after: comma)...])) >= 6 { return false }
        return true
    }

    // MARK: Punctuation

    /// Applies the three question fixes to every sentence of `text` (see the type doc). Lines are
    /// handled independently so list items and line breaks are never merged.
    public static func apply(_ text: String) -> String {
        text.components(separatedBy: "\n").map(applyToLine).joined(separator: "\n")
    }

    private static func applyToLine(_ line: String) -> String {
        guard line.contains(where: \.isLetter) else { return line }
        // A list item or a line with code-ish content keeps its punctuation exactly.
        if line.hasPrefix("- ") || line.range(of: "^\\d+\\.\\s", options: .regularExpression) != nil { return line }
        // Sentence ends only where [.!?] is followed by whitespace, so "12.5%", "v2.3.1" and
        // "example.com" never split; and an untouched line is returned byte-for-byte.
        let original = sentenceSplit(line)
        var sentences: [String] = []
        for sentence in original {
            for piece in splitStallPhrase(sentence).flatMap(splitTagQuestion) {
                sentences.append(contentsOf: splitRunTogetherQuestions(piece))
            }
        }
        let marked = sentences.map(markIfQuestion)
        return marked == original ? line : marked.joined(separator: " ")
    }

    static func sentenceSplit(_ line: String) -> [String] {
        line.replacingOccurrences(of: "(?<=[.!?])\\s+", with: "\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "…looks a bit too how would I say it." -> ["…looks a bit too...", "How would I say it."]. Only when the phrase
    /// ends the sentence after at least three words, and never after a word that makes it reported speech
    /// ("I don't know how would I say it", "ask them how do I put it").
    static func splitStallPhrase(_ sentence: String) -> [String] {
        let tokens = sentence.split(separator: " ").map(String.init)
        let tokenKeys = tokens.map(LegitDoubles.key)
        let reported: Set<String> = [
            "know", "knew", "sure", "wonder", "wondering", "ask", "asked", "asking", "about", "of", "remember",
            "idea", "tell", "told", "figure", "decide", "explain", "show", "see", "learn",
        ]
        for phrase in stallPhrases.sorted(by: { $0.count > $1.count }) {
            let start = tokens.count - phrase.count
            guard start >= 3, Array(tokenKeys[start...]) == phrase, !reported.contains(tokenKeys[start - 1]) else { continue }
            var head = tokens[..<start].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            while let last = head.last, ",;:".contains(last) { head.removeLast() }
            guard let last = head.last, !".!?".contains(last) else { return [sentence] }
            var tail = tokens[start...].joined(separator: " ")
            while let last = tail.last, ".!?,;:".contains(last) { tail.removeLast() }
            return [head + "...", capitalizeFirst(tail) + "?"]
        }
        return [sentence]
    }

    /// "…configurable what do you think." -> ["…configurable.", "What do you think?"]. Only for a
    /// statement (a sentence that already opens as a question keeps its tag inside it), only for
    /// the closed `tagQuestions` list, and only after at least three words of statement.
    static func splitTagQuestion(_ sentence: String) -> [String] {
        guard !opensQuestion(sentence) else { return [sentence] }
        let tokens = sentence.split(separator: " ").map(String.init)
        let tokenKeys = tokens.map(LegitDoubles.key)
        for tag in tagQuestions.sorted(by: { $0.count > $1.count }) {
            guard tokens.count >= tag.count + 3 else { continue }
            // The tag either ends the sentence or starts the sentence's final clause ("…what do
            // you think we can do about that").
            for start in stride(from: tokens.count - tag.count, through: 3, by: -1) {
                guard Array(tokenKeys[start..<(start + tag.count)]) == tag else { continue }
                // Don't split inside "…about what do you think" or "…ask them what do you think"
                // style reported speech: the word before must end a clause.
                let before = tokenKeys[start - 1]
                if ["about", "of", "ask", "asked", "asking", "wondering", "and", "or", "but"].contains(before) { continue }
                let head = tokens[..<start].joined(separator: " ")
                let tail = tokens[start...].joined(separator: " ")
                return [terminate(head), capitalizeFirst(tail)]
            }
        }
        return [sentence]
    }

    /// Inside a question, a second inverted question run into it ("What do you think we can do
    /// about that should we remember it per tab or is that overkill" / "…on an M1, is it more
    /// than 2 seconds") becomes its own sentence. Only splits before an auxiliary + pronoun
    /// subject at least four words in, and never after a word that keeps the two together
    /// ("or is that overkill", "if we should", "we should we").
    static func splitRunTogetherQuestions(_ sentence: String) -> [String] {
        guard opensQuestion(sentence) else { return [sentence] }
        let tokens = sentence.split(separator: " ").map(String.init)
        let tokenKeys = tokens.map(LegitDoubles.key)
        let keepTogether: Set<String> = [
            "or", "and", "if", "whether", "not", "than", "what", "who", "where", "when", "why", "how",
            "which", "to", "i", "you", "we", "they", "he", "she", "it",
        ]
        let splitAuxiliaries: Set<String> = ["is", "are", "should", "can", "could", "would", "will", "do", "does", "did"]
        let splitSubjects: Set<String> = ["i", "you", "we", "they", "it", "that", "there", "this"]
        var index = 4
        while index + 1 < tokens.count {
            let aux = tokenKeys[index], subject = tokenKeys[index + 1]
            if splitAuxiliaries.contains(aux), splitSubjects.contains(subject),
               !keepTogether.contains(tokenKeys[index - 1]), index + 3 <= tokens.count {
                let head = tokens[..<index].joined(separator: " ")
                let tail = tokens[index...].joined(separator: " ")
                return [terminate(head, question: true)] + splitRunTogetherQuestions(capitalizeFirst(tail))
            }
            index += 1
        }
        return [sentence]
    }

    /// A sentence that opens as a question and ends in "." (or nothing) gets "?".
    static func markIfQuestion(_ sentence: String) -> String {
        guard opensQuestion(sentence) else { return sentence }
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("!") { return trimmed }
        if trimmed.hasSuffix(".") { return String(trimmed.dropLast()) + "?" }
        // Unterminated: only the caller's terminal-punctuation pass decides whether to add a
        // mark at all (it skips very short fragments), so leave it unterminated here.
        return trimmed
    }

    private static func terminate(_ text: String, question: Bool = false) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while let last = trimmed.last, ",;:".contains(last) { trimmed.removeLast() }
        if let last = trimmed.last, ".!?".contains(last) { return trimmed }
        return trimmed + (question ? "?" : ".")
    }

    private static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
