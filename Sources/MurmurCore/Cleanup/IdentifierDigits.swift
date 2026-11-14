import Foundation

/// A code-like name with digits in it ("rl-v9", "TRY-95", "gpt4o", "v2.3", "Q3") is one name, and its digits are part of
/// it. An answer may write a spoken identifier in another case or with other separators ("Rl-v9" as "RL-v9", "try 95" as
/// "TRY-95"); it may not add, drop or change a digit in it ("rl-v9" as "rl-v99"). The value checks cannot see that: they
/// ask whether each number is one the speaker said, so "99" said anywhere else, or a correction cue anywhere, lets
/// "rl-v99" through.
///
/// An identifier starts with a letter and holds a digit; "3pm", "1st" and "5GB" are numbers with a unit, which the value
/// checks read. An answer identifier is held to the speaker's only where the speaker gave an identifier the same letters:
/// then its digits must be ones the speaker gave a name with those letters, in the token itself or across the words next
/// to it ("rl v9", "v2 point 3", "gpt four o"). An identifier with letters the speaker never gave one is left to the other
/// checks.
enum IdentifierDigits {
    struct Identifier: Hashable {
        /// Letters and digits, lowercased, without separators: "rlv9".
        let key: String
        /// The letters alone: "rlv".
        let letters: String

        init?(_ key: String) {
            let letters = key.filter(\.isLetter)
            guard !letters.isEmpty, key.contains(where: \.isNumber) else { return nil }
            self.key = key
            self.letters = letters
        }
    }

    /// "changed digits" when an identifier in `answer` has the letters of one in `said` and digits `said` never gave them.
    static func violation(answer: String, said: String) -> String? {
        let spoken = Set(identifiers(in: said)).union(spokenAcrossWords(said))
        guard !spoken.isEmpty else { return nil }
        let names = Set(spoken.map(\.letters))
        let changed = identifiers(in: answer).contains { names.contains($0.letters) && !spoken.contains($0) }
        return changed ? "changed digits" : nil
    }

    /// The identifiers written as one token: a letter first, then letters and digits, pieces joined by "-", "_" or ".".
    static func identifiers(in text: String) -> [Identifier] {
        Regex.matchesCaseSensitive(text, "(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9]*(?:[-_.][A-Za-z0-9]+)*").compactMap { match in
            match.string(at: 0, in: text).flatMap { Identifier(alphanumerics($0)) }
        }
    }

    // MARK: Said across words

    private static let longestSpan = 4
    private static let separatorWords: Set<String> = ["point", "dot", "dash", "hyphen", "underscore"]
    private static let digitWords = [
        "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9",
    ]

    /// Identifiers made of up to four words said one after the other, with number words read as digits: "rl v9",
    /// "v2 point 3", "gpt four o", "try twenty five". Punctuation after a word ends the span.
    private static func spokenAcrossWords(_ text: String) -> [Identifier] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func endsClause(_ token: String) -> Bool { token.last.map { ",.;:!?".contains($0) } ?? false }
        var found: [Identifier] = []
        for start in tokens.indices {
            for end in (start + 1)...min(tokens.count, start + longestSpan) {
                let span = tokens[start..<end]
                guard !span.dropLast().contains(where: endsClause),
                      let key = written(span.map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }),
                      let identifier = Identifier(key) else { continue }
                found.append(identifier)
            }
        }
        return found
    }

    /// The words as one identifier key, or nil when a run of number words in them reads as no number.
    /// `KnownIdentifierForms` reads a spoken run against the names it knows with this.
    static func written(_ words: [String]) -> String? {
        var key = ""
        var numberRun: [String] = []
        func flushNumber() -> Bool {
            defer { numberRun = [] }
            guard !numberRun.isEmpty else { return true }
            if let value = InverseTextNormalizer.parseCardinal(numberRun.joined(separator: " ")) {
                key += String(value)
                return true
            }
            // Digits said one by one: "four one five".
            let digits = numberRun.compactMap { digitWords[$0] }
            guard digits.count == numberRun.count else { return false }
            key += digits.joined()
            return true
        }
        for word in words {
            if SpokenNumberRuns.isNumberWord(word) || word == "oh" && !numberRun.isEmpty {
                numberRun.append(word)
                continue
            }
            guard flushNumber() else { return nil }
            if !separatorWords.contains(word) { key += alphanumerics(word) }
        }
        return flushNumber() ? key : nil
    }

    private static func alphanumerics(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
