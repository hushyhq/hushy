import Foundation

/// Checks an edited selection against the original before it may replace it: the edit may change
/// what the instruction asked about and nothing else of substance. Numbers, names and negations
/// survive unless the instruction itself names them or asks for that kind of change.
///
/// Facts are compared as sets (a rewrite reorders freely); each check is one pass
/// over both texts, O(n + m).
public enum VoiceEditGuard {
    public enum Verdict: Equatable, Sendable {
        case accepted(String)
        case declined(VoiceEditDecline, reason: String)
    }

    public static func check(edited answer: String, original: String, instruction: String) -> Verdict {
        let edited = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty else { return .declined(.noAnswer, reason: "empty") }
        if normalized(edited) == normalized(original) { return .declined(.unchanged, reason: "unchanged") }
        if let reason = PromptInjectionGuard.violation(answer: edited, raw: original) {
            return .declined(.wouldChangeMeaning, reason: reason)
        }
        let asked = Instruction(instruction)
        if let reason = numberChange(edited: edited, original: original, asked: asked)
            ?? nameChange(edited: edited, original: original, asked: asked)
            ?? negationChange(edited: edited, original: original, asked: asked) {
            return .declined(.wouldChangeMeaning, reason: reason)
        }
        return .accepted(Self.keepingOuterWhitespace(of: original, around: edited))
    }

    /// What the instruction allows, read from its words.
    struct Instruction {
        let words: Set<String>
        let numbers: Set<String>
        /// "remove", "delete", "cut": the person asked for something to go.
        let removes: Bool
        /// "translate", "in Spanish": every word may change, names and numbers still may not.
        let translates: Bool
        /// "capitalize", "lowercase", "title case": only the case changes, so names are compared without it.
        let recases: Bool
        /// "digits", "numbers", "numbered list", "round": numbers may be rewritten.
        let renumbers: Bool
        /// "opposite", "negative", or a negation in the instruction itself.
        let flipsPolarity: Bool

        init(_ text: String) {
            let tokens = VoiceEditRouter.tokens(text)
            words = Set(tokens)
            numbers = VoiceEditGuard.numbers(in: text)
            removes = !words.isDisjoint(with: ["remove", "delete", "drop", "cut", "without", "take", "lose", "shorten", "shorter", "summarize", "summarise", "condense", "trim"])
            translates = words.contains("translate") || !words.isDisjoint(with: Self.languages)
            recases = !words.isDisjoint(with: ["capitalize", "capitalise", "lowercase", "uppercase", "caps", "case", "capital", "capitals"])
            renumbers = !words.isDisjoint(with: ["digit", "digits", "number", "numbers", "numbered", "numeral", "numerals", "round", "figures", "percent", "percentage", "currency"])
            flipsPolarity = !words.isDisjoint(with: ["opposite", "negative", "positive", "negate", "flip", "not", "never", "no", "don't", "dont"])
        }

        static let languages: Set<String> = ["spanish", "french", "german", "hindi", "italian", "portuguese", "japanese", "chinese", "english", "dutch", "korean", "arabic"]
    }

    // MARK: Numbers

    static func numbers(in text: String) -> Set<String> {
        let found = Regex.matches(text, "\\d+(?:[.,:]\\d+)*").compactMap { $0.string(at: 0, in: text) }
        return Set(found.map(canonicalNumber))
    }

    /// One spelling per value: "4,217", "4.217" (a Spanish thousands point) and "4217" are the same,
    /// and "9:00" is "9" ("9am" rewritten "9:00 AM"). A decimal like "6.2" is kept as it is.
    static func canonicalNumber(_ number: String) -> String {
        let grouped = Regex.replace(number, "(?<=\\d)[,.](?=\\d{3}(?:\\D|$))", with: "")
        return Regex.replace(grouped, ":00$", with: "")
    }

    static func twelveHour(_ number: String) -> String {
        guard let hour = Int(number), (13...23).contains(hour) else { return number }
        return String(hour - 12)
    }

    private static func numberChange(edited: String, original: String, asked: Instruction) -> String? {
        guard !asked.renumbers else { return nil }
        // A translation may write "14 Uhr" for "2pm": the hour is the same.
        let fold: (Set<String>) -> Set<String> = { asked.translates ? Set($0.map(twelveHour)) : $0 }
        let before = fold(numbers(in: original)), after = fold(numbers(in: edited))
        let dropped = before.subtracting(after).subtracting(asked.numbers)
        let added = after.subtracting(before).subtracting(asked.numbers)
        if !dropped.isEmpty, !added.isEmpty { return "changed number" }
        if !added.isEmpty { return "invented number" }
        // A removal may take a number with it; it may never put a different one in its place.
        if !dropped.isEmpty, !asked.removes { return "dropped number" }
        return nil
    }

    // MARK: Names

    private static func nameChange(edited: String, original: String, asked: Instruction) -> String? {
        guard !asked.removes else { return nil }
        let before = names(in: original), after = names(in: edited, sentenceInitialToo: true)
        let comparableAfter = asked.recases ? Set(after.map { $0.lowercased() }) : after
        let comparableBefore = asked.recases ? Set(before.map { $0.lowercased() }) : before
        let lowerAfterText = edited.lowercased()
        let dropped = comparableBefore.subtracting(comparableAfter).filter { name in
            !asked.words.contains(name.lowercased())
                // A translation writes "jueves" for "Thursday"; a name stays a name in any language.
                && !(asked.translates && calendarWords.contains(name.lowercased()))
                // A name kept in a different case or shape ("iPhone" → "iphone" under "lowercase") still stands.
                && !(asked.recases && lowerAfterText.contains(name.lowercased()))
        }
        return dropped.isEmpty ? nil : "dropped name"
    }

    /// Capitalized words not at a sentence start, plus every all-caps or mixed-case word ("API", "iOS").
    static func names(in text: String, sentenceInitialToo: Bool = false) -> Set<String> {
        var found: Set<String> = []
        for sentence in Sentences.split(text) {
            let tokens = sentence.split { $0 == " " || $0 == "\n" || $0 == "\t" }.map(String.init)
            for (index, raw) in tokens.enumerated() {
                var token = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                for suffix in ["'s", "\u{2019}s"] where token.hasSuffix(suffix) { token = String(token.dropLast(2)) }
                guard token.count > 1, token != "I", !token.hasPrefix("I'"), !token.hasPrefix("I\u{2019}"),
                      !honorifics.contains(token), let first = token.first, first.isLetter else { continue }
                let hasInnerCapital = token.dropFirst().contains { $0.isUppercase }
                guard first.isUppercase || hasInnerCapital else { continue }
                if index == 0, !sentenceInitialToo, !hasInnerCapital { continue }
                found.insert(token)
            }
        }
        return found
    }

    /// A register change may write "Hi Okafor" for "Dear Mr. Okafor": the title is not the name.
    static let honorifics: Set<String> = ["Mr", "Mrs", "Ms", "Dr", "Prof", "Sir", "Madam"]
    static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march",
        "april", "may", "june", "july", "august", "september", "october", "november", "december",
    ]

    // MARK: Negations

    private static func negationChange(edited: String, original: String, asked: Instruction) -> String? {
        // English negation words cannot be counted in another language.
        guard !asked.flipsPolarity, !asked.translates else { return nil }
        let before = NegationPolarity.count(in: original), after = NegationPolarity.count(in: edited)
        if after > before, NegationPolarity.addsNegation(answer: edited, draft: original) { return "added negation" }
        if after < before, !asked.removes, !keepsNegativeMeaning(edited, missing: before - after) { return "dropped negation" }
        return nil
    }

    /// A rewrite may say "unable to" for "can't" or "without" for "with no": a negation in other words.
    private static func keepsNegativeMeaning(_ text: String, missing: Int) -> Bool {
        let words = VoiceEditRouter.tokens(text)
        let negative = words.filter { negativeWords.contains($0) || $0.hasPrefix("un") && negativeStems.contains(String($0.dropFirst(2))) }
        return negative.count >= missing
    }

    static let negativeWords: Set<String> = [
        "unable", "without", "lack", "lacks", "lacking", "refuse", "refuses", "decline", "declines", "fail", "fails",
        "failed", "avoid", "neither", "nor", "none", "nothing", "nobody", "nowhere", "absent", "missing", "impossible",
        "hardly", "barely", "unavailable", "cannot", "instead",
    ]
    static let negativeStems: Set<String> = ["able", "available", "likely", "clear", "sure", "aware", "known", "willing", "happy", "certain"]

    // MARK: Text shape

    /// Whitespace only: a change of case ("make it all caps") is a change.
    private static func normalized(_ text: String) -> String {
        text.split { $0.isWhitespace }.joined(separator: " ")
    }

    /// The selection's leading and trailing whitespace around the edited text, so a selected line keeps
    /// its line break and a word selected with its space keeps the space.
    static func keepingOuterWhitespace(of original: String, around edited: String) -> String {
        let leading = original.prefix { $0.isWhitespace }
        let trailing = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        guard leading.count < original.count else { return edited }
        return String(leading) + edited + trailing
    }
}
